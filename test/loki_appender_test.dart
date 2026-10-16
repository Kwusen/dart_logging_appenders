import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/base_remote_appender.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:test/test.dart';

final _ts = DateTime.utc(2026, 10, 14, 12, 30, 45, 123, 456);

/// Runs [body] in fake time with a [MockClient] that answers every request
/// with [statusCode], and returns the requests it received.
List<http.Request> _withMockClient(
  void Function(FakeAsync async) body, {
  int statusCode = 204,
}) {
  final requests = <http.Request>[];
  http.runWithClient(
    () => fakeAsync(body),
    () => MockClient((request) async {
      requests.add(request);
      return http.Response('', statusCode);
    }),
  );
  return requests;
}

LokiApiAppender _appender() => LokiApiAppender(
  server: 'logs.example.com',
  username: 'user',
  password: 'pass',
  labels: {'app': 'test'},
);

LokiApiAppender _labelsAppender() => LokiApiAppender(
  server: 'logs.example.com',
  username: 'user',
  password: 'pass',
  labels: {'app': 'test'},
  userPropertiesAs: LokiUserProperties.labels,
);

LokiApiAppender _levelAppender() => LokiApiAppender(
  server: 'logs.example.com',
  username: 'user',
  password: 'pass',
  labels: {'app': 'test'},
  sendLevelMetadata: true,
);

LokiApiAppender _labelsLevelAppender() => LokiApiAppender(
  server: 'logs.example.com',
  username: 'user',
  password: 'pass',
  labels: {'app': 'test'},
  userPropertiesAs: LokiUserProperties.labels,
  sendLevelMetadata: true,
);

void _log(
  LokiApiAppender appender, {
  Level level = Level.INFO,
  Map<String, String> lineLabels = const {'lvl': 'INFO', 'logger': 'app'},
}) => appender.log(level, _ts, 'message', lineLabels);

void main() {
  group('LokiApiAppender', () {
    test('pushes the v1 request', () {
      var flushed = false;
      final requests = _withMockClient((async) {
        final appender = _appender();
        _log(appender);
        // Line label values containing spaces are quoted.
        _log(appender, lineLabels: {'lvl': 'INFO', 'logger': 'my app'});
        appender.flush().then((_) => flushed = true);
        async.elapse(Duration.zero);
      });
      expect(flushed, isTrue);
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url,
        Uri.parse('https://logs.example.com/loki/api/v1/push'),
      );
      expect(
        request.headers['authorization'],
        'Basic ${base64.encode(utf8.encode('user:pass'))}',
      );
      expect(request.headers['content-type'], startsWith('application/json'));
      // Expected body follows Loki's documented format, linked on `LokiStream`.
      final nanoseconds = '${_ts.microsecondsSinceEpoch * 1000}';
      expect(json.decode(request.body), {
        'streams': [
          {
            'stream': {'app': 'test'},
            'values': [
              [nanoseconds, 'lvl=INFO logger=app - message'],
              [nanoseconds, 'lvl=INFO logger="my app" - message'],
            ],
          },
        ],
      });
    });

    final nanoseconds = '${_ts.microsecondsSinceEpoch * 1000}';
    const line = 'lvl=INFO logger=app - message';
    final userPropertiesScenarios = [
      (
        name: 'structured metadata (default)',
        create: _appender,
        props: {'user': 'alice'},
        stream: {'app': 'test'},
        value: [
          nanoseconds,
          line,
          {'user': 'alice'},
        ],
      ),
      (
        name: 'labels',
        create: _labelsAppender,
        props: {'user': 'alice'},
        stream: {'app': 'test', 'user': 'alice'},
        value: [nanoseconds, line],
      ),
      (
        name: 'labels, key clashing with a fixed label',
        create: _labelsAppender,
        props: {'app': 'other', 'user': 'alice'},
        stream: {'app': 'other', 'user': 'alice'},
        value: [nanoseconds, line],
      ),
      (
        name: 'structured metadata (default), empty',
        create: _appender,
        props: <String, String>{},
        stream: {'app': 'test'},
        value: [nanoseconds, line],
      ),
      (
        name: 'labels, empty',
        create: _labelsAppender,
        props: <String, String>{},
        stream: {'app': 'test'},
        value: [nanoseconds, line],
      ),
      (
        name: 'structured metadata with level metadata',
        create: _levelAppender,
        props: {'user': 'alice'},
        stream: {'app': 'test'},
        value: [
          nanoseconds,
          line,
          {'user': 'alice', 'level': 'info'},
        ],
      ),
      (
        name:
            'structured metadata with level metadata, key clashing with level',
        create: _levelAppender,
        props: {'level': 'other', 'user': 'alice'},
        stream: {'app': 'test'},
        value: [
          nanoseconds,
          line,
          {'user': 'alice', 'level': 'other'},
        ],
      ),
      (
        name: 'structured metadata with level metadata, empty',
        create: _levelAppender,
        props: <String, String>{},
        stream: {'app': 'test'},
        value: [
          nanoseconds,
          line,
          {'level': 'info'},
        ],
      ),
      (
        name: 'labels with level metadata',
        create: _labelsLevelAppender,
        props: {'user': 'alice'},
        stream: {'app': 'test', 'user': 'alice'},
        value: [
          nanoseconds,
          line,
          {'level': 'info'},
        ],
      ),
    ];

    for (final s in userPropertiesScenarios) {
      test('sends userProperties as ${s.name}', () {
        var flushed = false;
        final requests = _withMockClient((async) {
          final appender = s.create()..userProperties = s.props;
          _log(appender);
          appender.flush().then((_) => flushed = true);
          async.elapse(Duration.zero);
        });
        expect(flushed, isTrue);
        expect(requests, hasLength(1));
        expect(json.decode(requests.single.body), {
          'streams': [
            {
              'stream': s.stream,
              'values': [s.value],
            },
          ],
        });
      });
    }

    // Custom levels sit on each side of every boundary.
    final levelScenarios = [
      (level: const Level('BELOW_ALL', -1), expected: 'trace'),
      (level: Level.ALL, expected: 'trace'),
      (level: Level.FINEST, expected: 'trace'),
      (level: Level.FINER, expected: 'trace'),
      (level: const Level('CUSTOM_499', 499), expected: 'trace'),
      (level: Level.FINE, expected: 'debug'),
      (level: Level.CONFIG, expected: 'debug'),
      (level: const Level('CUSTOM_799', 799), expected: 'debug'),
      (level: Level.INFO, expected: 'info'),
      (level: const Level('CUSTOM_899', 899), expected: 'info'),
      (level: Level.WARNING, expected: 'warn'),
      (level: const Level('CUSTOM_999', 999), expected: 'warn'),
      (level: Level.SEVERE, expected: 'error'),
      (level: const Level('CUSTOM_1199', 1199), expected: 'error'),
      (level: Level.SHOUT, expected: 'critical'),
      (level: Level.OFF, expected: 'critical'),
    ];

    for (final s in levelScenarios) {
      test(
        'sends level metadata ${s.expected} for ${s.level.name} '
        '(${s.level.value})',
        () {
          var flushed = false;
          final requests = _withMockClient((async) {
            final appender = _levelAppender();
            _log(
              appender,
              level: s.level,
              lineLabels: {'lvl': s.level.name, 'logger': 'app'},
            );
            appender.flush().then((_) => flushed = true);
            async.elapse(Duration.zero);
          });
          expect(flushed, isTrue);
          expect(requests, hasLength(1));
          // The line keeps the Dart level name.
          expect(json.decode(requests.single.body), {
            'streams': [
              {
                'stream': {'app': 'test'},
                'values': [
                  [
                    nanoseconds,
                    'lvl=${s.level.name} logger=app - message',
                    {'level': s.expected},
                  ],
                ],
              },
            ],
          });
        },
      );
    }

    test('copies labels at construction and exposes them read-only', () {
      final labels = {'app': 'test'};
      var flushed = false;
      late LokiApiAppender appender;
      final requests = _withMockClient((async) {
        appender = LokiApiAppender(
          server: 'logs.example.com',
          username: 'user',
          password: 'pass',
          labels: labels,
        );
        labels['app'] = 'changed';
        _log(appender);
        appender.flush().then((_) => flushed = true);
        async.elapse(Duration.zero);
      });
      expect(flushed, isTrue);
      expect(requests, hasLength(1));
      expect(json.decode(requests.single.body), {
        'streams': [
          {
            'stream': {'app': 'test'},
            'values': [
              [nanoseconds, line],
            ],
          },
        ],
      });
      expect(() => appender.labels['app'] = 'x', throwsUnsupportedError);
    });

    test('requires a non-empty server', () {
      expect(
        () => LokiApiAppender(
          server: '',
          username: 'user',
          password: 'pass',
          labels: {'app': 'test'},
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('flush completes with an HttpLogException for a non-2xx status', () {
      Object? flushError;
      _withMockClient((async) {
        final appender = _appender();
        _log(appender);
        appender.flush().catchError((Object e) => flushError = e);
        async.elapse(Duration.zero);
      }, statusCode: 500);
      expect(
        flushError,
        isA<HttpLogException>().having((e) => e.statusCode, 'statusCode', 500),
      );
    });
  });
}
