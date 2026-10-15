// LEGACY(prom-push): delete together with loki_appender.legacy.dart
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/base_remote_appender.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:logging_appenders/src/remote/loki_appender.legacy.dart';
import 'package:test/test.dart';

final _ts = DateTime.utc(2026, 10, 14, 12, 30, 45, 123, 456);

// Follows the format linked on `encodeLegacyPromPushBody`.
final _expectedBody = {
  'streams': [
    {
      'labels': '{app="test"}',
      'entries': [
        {
          'ts': '2026-10-14T12:30:45.123Z',
          'line': 'lvl=INFO logger=app - message',
        },
        {
          'ts': '2026-10-14T12:30:45.123Z',
          'line': 'lvl=INFO logger="my app" - message',
        },
      ],
    },
  ],
};

void main() {
  test('encodeLegacyPromPushBody encodes labels and entries', () {
    final body = encodeLegacyPromPushBody('{app="test"}', [
      LogEntry(
        logLevel: Level.INFO,
        ts: _ts,
        line: 'message',
        lineLabels: {'lvl': 'INFO', 'logger': 'app'},
      ),
      LogEntry(
        logLevel: Level.INFO,
        ts: _ts,
        line: 'message',
        // Line label values containing spaces are quoted.
        lineLabels: {'lvl': 'INFO', 'logger': 'my app'},
      ),
    ]);
    expect(json.decode(body), _expectedBody);
  });

  test(
    'LokiApiAppender pushes the legacy request, ignoring userProperties',
    () {
      var flushed = false;
      final requests = <http.Request>[];
      http.runWithClient(
        () => fakeAsync((async) {
          final appender = LokiApiAppender(
            server: 'logs.example.com',
            username: 'user',
            password: 'pass',
            labels: {'app': 'test'},
            useLegacyPromPushApi: true,
            userPropertiesAs: LokiUserProperties.labels,
          )..userProperties = {'user': 'alice'};
          appender.log(Level.INFO, _ts, 'message', {
            'lvl': 'INFO',
            'logger': 'app',
          });
          appender.log(Level.INFO, _ts, 'message', {
            'lvl': 'INFO',
            'logger': 'my app',
          });
          appender.flush().then((_) => flushed = true);
          async.elapse(Duration.zero);
        }),
        () => MockClient((request) async {
          requests.add(request);
          return http.Response('', 204);
        }),
      );
      expect(flushed, isTrue);
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url, Uri.parse('https://logs.example.com/api/prom/push'));
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(json.decode(request.body), _expectedBody);
    },
  );
}
