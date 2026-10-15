import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging_appenders/src/internal/dummy_logger.dart';
import 'package:logging_appenders/src/remote/base_remote_appender.dart';
// LEGACY(prom-push): remove together with useLegacyPromPushApi
import 'package:logging_appenders/src/remote/loki_appender.legacy.dart';

final _logger = DummyLogger('logging_appenders.loki_appender');

/// Appender used to push logs to [Loki](https://github.com/grafana/loki).
///
/// Pushes to `/loki/api/v1/push` on [server], a host name like
/// `logs.example.com`.
class LokiApiAppender extends BaseHttpLogSender {
  LokiApiAppender({
    required this.server,
    required this.username,
    required this.password,
    required Map<String, String> labels,
    // LEGACY(prom-push): remove together with useLegacyPromPushApi
    @Deprecated(
      'The legacy /api/prom/push endpoint will be removed. '
      'Use the default /loki/api/v1/push endpoint. '
      'userProperties are ignored with the legacy endpoint.',
    )
    bool useLegacyPromPushApi = false,
    LokiUserProperties userPropertiesAs = LokiUserProperties.structuredMetadata,
  }) : assert(server.isNotEmpty),
       labels = Map.unmodifiable(labels),
       _userPropertiesAs = userPropertiesAs,
       // LEGACY(prom-push): remove together with useLegacyPromPushApi
       _useLegacyPromPushApi = useLegacyPromPushApi,
       labelsString =
           '{${labels.entries.map((entry) => '${entry.key}="${entry.value}"').join(',')}}',
       authHeader =
           'Basic ${base64.encode(utf8.encode([username, password].join(':')))}';

  final String server;
  final String username;
  final String password;
  final String authHeader;
  final Map<String, String> labels;
  final LokiUserProperties _userPropertiesAs;

  // LEGACY(prom-push): remove together with useLegacyPromPushApi
  @Deprecated(
    'Only used by the legacy prom-push format; '
    'will be removed with useLegacyPromPushApi.',
  )
  final String labelsString;

  // LEGACY(prom-push): remove together with useLegacyPromPushApi
  final bool _useLegacyPromPushApi;

  static String _encodeLineLabelValue(String value) {
    if (value.contains(' ')) {
      return json.encode(value);
    }
    return value;
  }

  @override
  Future<void> sendLogEventsWithHttp(
    List<LogEntry> entries,
    Map<String, String> userProperties,
    Future<void> cancelToken,
  ) {
    final String path;
    final String jsonBody;
    // LEGACY(prom-push): remove together with useLegacyPromPushApi
    if (_useLegacyPromPushApi) {
      path = legacyPromPushPath;
      jsonBody = encodeLegacyPromPushBody(labelsString, entries);
    } else {
      path = '/loki/api/v1/push';
      var streamLabels = labels;
      Map<String, String>? metadata;
      if (userProperties.isNotEmpty) {
        switch (_userPropertiesAs) {
          case LokiUserProperties.structuredMetadata:
            metadata = userProperties;
          case LokiUserProperties.labels:
            final clashing = userProperties.keys.where(labels.containsKey);
            if (clashing.isNotEmpty) {
              _logger.finest(
                'userProperties ${clashing.join(', ')} clash with labels; '
                'labels win.',
              );
            }
            streamLabels = {...userProperties, ...labels};
        }
      }
      final jsonObject = LokiPushBody([
        LokiStream(streamLabels, entries),
      ]).toJson();
      jsonBody = json.encode(
        jsonObject,
        toEncodable: (dynamic obj) {
          if (obj is LogEntry) {
            return [
              // Loki expects the timestamp in nanoseconds.
              (obj.ts.microsecondsSinceEpoch * 1000).toString(),
              // The legacy format (loki_appender.legacy.dart) has its own copy
              // of this line format; keep both in sync while legacy remains.
              [
                obj.lineLabels.entries
                    .map(
                      (entry) =>
                          '${entry.key}=${_encodeLineLabelValue(entry.value)}',
                    )
                    .join(' '),
                obj.line,
              ].join(' - '),
              ?metadata,
            ];
          }
          return obj.toJson();
        },
      );
    }
    final request =
        http.AbortableRequest(
            'POST',
            Uri.parse('https://$server$path'),
            abortTrigger: cancelToken,
          )
          ..body = jsonBody
          ..headers[HttpHeaders.authorizationHeader] = authHeader
          ..headers[HttpHeaders.contentTypeHeader] = ContentType.json.value;
    _logger.finest('About to push logs: ${request.contentLength} bytes');
    return sendRequest(request);
  }
}

/// Where [LokiApiAppender] puts `userProperties` in a v1 push. The legacy
/// endpoint ignores them.
enum LokiUserProperties {
  /// As each entry's structured metadata. Needs Loki 2.9+ with structured
  /// metadata enabled.
  structuredMetadata,

  /// Merged into the stream labels; fixed `labels` win on a clash. Keep keys
  /// stable, use placeholders like `'none'` and keep values low-cardinality.
  labels,
}

class LokiPushBody {
  LokiPushBody(this.streams);

  final List<LokiStream> streams;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'streams': streams.map((stream) => stream.toJson()).toList(growable: false),
  };
}

/// Loki stream definition.
///
/// Format: https://grafana.com/docs/loki/latest/reference/loki-http-api/#ingest-logs
///
/// For the v1 push API it serializes to:
/// ```json
/// {
///   "stream": {"label": "value"},
///   "values": [["<unix epoch in nanoseconds>", "<log line>"], ...]
/// }
/// ```
class LokiStream {
  LokiStream(this.labels, this.entries);

  final Map<String, String> labels;
  final List<LogEntry> entries;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'stream': labels,
    'values': entries,
  };
}
