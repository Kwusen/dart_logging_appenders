import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:logging_appenders/src/internal/dummy_logger.dart';
import 'package:logging_appenders/src/remote/base_remote_appender.dart';
import 'package:meta/meta.dart';

final _logger = DummyLogger('logging_appenders.loki_appender');

// Set the dummy logger to print everything when debuggin:
// _logger.level = Level.FINEST;

/// Appender used to push logs to [Loki](https://github.com/grafana/loki).
///
/// Server url must conform for new `api/v1/push` format.
class LokiApiAppender extends BaseHttpLogSender {
  LokiApiAppender({
    required this.server,
    required this.username,
    required this.password,
    required this.labels,
  })  : assert(username.isNotEmpty),
        assert(password.isNotEmpty),
        assert(server.isNotEmpty),
        _labelString = _labelsToString(labels),
        authHeader = 'Basic ' +
            base64
                .encode(utf8.encode([username, password].join(':')))
                .toString();

  final String server;
  final String username;
  final String password;
  final String authHeader;
  final Map<String, String> labels;

  String _labelString;
  String get labelString => _labelString;

  static String _labelsToString(Map labels) {
    return '{' +
        labels.entries
            .map((entry) => '${entry.key}="${entry.value}"')
            .join(',') +
        '}';
  }

  /// Updates the labels map with additional/updated labels.
  ///
  /// It is an additive operation. Labels existing in the map will not be removed.
  void updateLabels(Map<String, String> newLabels) {
    labels.addEntries(newLabels.entries);
    _labelString = _labelsToString(labels);
  }

  static String _encodeLineLabelValue(String value) {
    if (value.contains(' ')) {
      return json.encode(value);
    }
    return value;
  }

  @override
  Future<void> sendLogEventsWithHttpClient(
      List<LogEntry> entries, Map<String, String> userProperties) {
    final jsonObject = LokiPushBody([LokiStream(labels, entries)]).toJson();
    final jsonBody = json.encode(jsonObject, toEncodable: (dynamic obj) {
      if (obj is LogEntry) {
        final entry = [
          (obj.ts.microsecondsSinceEpoch * 1000)
              .toString(), // conv to nanoseconds
          obj.lineLabels.entries
                  .map((entry) =>
                      '${entry.key}=${_encodeLineLabelValue(entry.value)}')
                  .join(' ') +
              ' - ' +
              obj.line
        ];
        return entry;
      }
      return obj.toJson();
    });
    final jsonBodyBytes = utf8.encode(jsonBody);
    _logger.finest('About to push logs: ${jsonBodyBytes.length} bytes');
    return http.post(
      Uri.parse(server),
      body: jsonBodyBytes, //jsonBody,
      headers: <String, String>{
        HttpHeaders.authorizationHeader: authHeader,
        HttpHeaders.contentLengthHeader: jsonBodyBytes.length.toString(),
        HttpHeaders.contentTypeHeader:
            ContentType(ContentType.json.primaryType, ContentType.json.subType)
                .value
      },
    ).then((response) {
      if (!response.statusCode.toString().startsWith('2')) {
        final msg =
            'log sender response status was not a 200. ${response.statusCode}: ${response.reasonPhrase}';
        _logger.warning(msg);
        return Future<void>.error(Exception(msg));
      } else {
        _logger.finest('sucessfully sent logs.');
      }
      return null;
    }).catchError((Object err, StackTrace stackTrace) {
      _logger.warning(
          'Error while sending logs to loki. ${err?.toString()}, ${stackTrace?.toString()}');
      return Future<void>.error(err, stackTrace);
    });
  }
}

class LokiPushBody {
  LokiPushBody(this.streams);

  final List<LokiStream> streams;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'streams':
            streams.map((stream) => stream.toJson()).toList(growable: false),
      };
}

/// Loki stream definition
///
/// For api v1 must take the below form when serializing to json:
/// ```json
///   {
///      "stream": {
///        "label": "value"
///      },
///      "values": [
///        [
///          "<unix epoch in nanoseconds>",
///          "<log line>"
///        ],
///        [
///          "<unix epoch in nanoseconds>",
///          "<log line>"
///        ]
///      ]
///    }
class LokiStream {
  LokiStream(this.labels, this.entries);

  final Map<String, String> labels;
  final List<LogEntry> entries;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'stream': labels, 'values': entries};
}
