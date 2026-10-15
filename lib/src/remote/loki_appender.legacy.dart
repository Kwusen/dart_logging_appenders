/// Legacy `/api/prom/push` support for `LokiApiAppender`. Delete together with
/// `useLegacyPromPushApi` and the `LEGACY(prom-push)` lines.
library;

import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:logging_appenders/src/remote/base_remote_appender.dart';

const legacyPromPushPath = '/api/prom/push';

final DateFormat _dateFormat = DateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");

String _encodeLineLabelValue(String value) {
  if (value.contains(' ')) {
    return json.encode(value);
  }
  return value;
}

/// Encodes [entries] as a legacy push request body, with the stream labels
/// given as a Prometheus-style label string ([labelsString]).
/// Format: https://grafana.com/docs/loki/v2.9.x/reference/api/#post-apiprompush
String encodeLegacyPromPushBody(String labelsString, List<LogEntry> entries) {
  final jsonObject = <String, dynamic>{
    'streams': [_LegacyLokiStream(labelsString, entries).toJson()],
  };
  return json.encode(
    jsonObject,
    toEncodable: (dynamic obj) {
      if (obj is LogEntry) {
        return {
          'ts': _dateFormat.format(obj.ts.toUtc()),
          // The v1 format in loki_appender.dart has a copy of this line format;
          // keep both in sync while legacy support remains.
          'line': [
            obj.lineLabels.entries
                .map(
                  (entry) =>
                      '${entry.key}=${_encodeLineLabelValue(entry.value)}',
                )
                .join(' '),
            obj.line,
          ].join(' - '),
        };
      }
      return obj.toJson();
    },
  );
}

class _LegacyLokiStream {
  _LegacyLokiStream(this.labels, this.entries);

  final String labels;
  final List<LogEntry> entries;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'labels': labels,
    'entries': entries,
  };
}
