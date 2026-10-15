import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:logging_appenders/base_remote_appender.dart';
import 'package:test/test.dart';

/// Sender which records sent batches instead of making requests, and can be
/// told to fail.
class _TestSender extends BaseHttpLogSender {
  /// When set, sends fail with this error.
  Object? failWith;

  /// Each successfully sent batch with the userProperties it was sent with.
  final batches = <Map<String, Object>>[];

  /// Number of send attempts, successful or not.
  var attempts = 0;

  @override
  Future<void> sendLogEventsWithHttp(
    List<LogEntry> entries,
    Map<String, String> userProperties,
    Future<void> cancelToken,
  ) {
    attempts++;
    final error = failWith;
    if (error != null) {
      return Future.error(error);
    }
    batches.add({
      'lines': entries.map((e) => e.line).toList(),
      'props': Map.of(userProperties),
    });
    return Future.value();
  }

  void logLine(String line) => log(Level.INFO, DateTime.now(), line, {});

  /// Exposes the protected [sendLogEvents] to the tests.
  Stream<void> send(List<LogEntry> entries) => sendLogEvents(entries, {});
}

void main() {
  group('BaseHttpLogSender error handling', () {
    final errors = <String, Object>{
      'ClientException': http.ClientException('connection refused'),
      'non-ClientException': StateError('boom'),
    };

    for (final MapEntry(key: name, value: error) in errors.entries) {
      test('flush completes with a $name', () {
        fakeAsync((async) {
          final sender = _TestSender()..failWith = error;
          sender.logLine('a');
          Object? flushError;
          sender.flush().catchError((Object e) => flushError = e);
          async.elapse(Duration.zero);
          expect(flushError, same(error));
        });
      });
    }

    for (final MapEntry(key: name, value: error) in errors.entries) {
      test('send stream reports a $name and closes', () {
        fakeAsync((async) {
          final sender = _TestSender()..failWith = error;
          final events = <String>[];
          sender
              .send([])
              .listen(
                (_) => events.add('data'),
                onError: (Object e) =>
                    events.add(identical(e, error) ? 'error' : 'unexpected $e'),
                onDone: () => events.add('done'),
              );
          async.flushMicrotasks();
          expect(events, ['error', 'done']);
        });
      });
    }

    test('send stream emits and closes on success', () {
      fakeAsync((async) {
        final sender = _TestSender();
        final events = <String>[];
        sender
            .send([])
            .listen(
              (_) => events.add('data'),
              onError: (Object e) => events.add('error'),
              onDone: () => events.add('done'),
            );
        async.flushMicrotasks();
        expect(events, ['data', 'done']);
      });
    });

    test('sending recovers after a non-ClientException', () {
      fakeAsync((async) {
        final error = StateError('boom');
        final sender = _TestSender()..failWith = error;
        sender.logLine('first');
        Object? flushError;
        sender.flush().catchError((Object e) => flushError = e);
        async.elapse(Duration.zero);
        expect(flushError, same(error));
        expect(sender.batches, isEmpty);

        sender.failWith = null;
        sender.logLine('second');
        var flushed = false;
        sender.flush().then((_) => flushed = true);
        async.elapse(Duration.zero);
        expect(flushed, isTrue);
        // The failed batch is retried along with the new one.
        expect(
          sender.batches,
          unorderedEquals([
            {
              'lines': ['first'],
              'props': <String, String>{},
            },
            {
              'lines': ['second'],
              'props': <String, String>{},
            },
          ]),
        );
      });
    });
  });

  group('userProperties', () {
    test('lines logged before a change are sent with the old values', () {
      fakeAsync((async) {
        final sender = _TestSender()..userProperties = {'user': 'none'};
        sender.logLine('before');
        sender.userProperties = {'user': 'alice'};
        sender.logLine('after');
        var flushed = false;
        sender.flush().then((_) => flushed = true);
        async.elapse(Duration.zero);
        expect(flushed, isTrue);
        expect(
          sender.batches,
          unorderedEquals([
            {
              'lines': ['before'],
              'props': {'user': 'none'},
            },
            {
              'lines': ['after'],
              'props': {'user': 'alice'},
            },
          ]),
        );
      });
    });

    test('a retried batch keeps the values it was queued with', () {
      fakeAsync((async) {
        final error = StateError('offline');
        final sender = _TestSender()
          ..failWith = error
          ..userProperties = {'user': 'alice'};
        sender.logLine('alice line');
        Object? flushError;
        sender.flush().catchError((Object e) => flushError = e);
        async.elapse(Duration.zero);
        expect(flushError, same(error));
        expect(sender.batches, isEmpty);

        sender.failWith = null;
        sender.userProperties = {'user': 'none'};
        sender.logLine('none line');
        var flushed = false;
        sender.flush().then((_) => flushed = true);
        async.elapse(Duration.zero);
        expect(flushed, isTrue);
        expect(
          sender.batches,
          unorderedEquals([
            {
              'lines': ['alice line'],
              'props': {'user': 'alice'},
            },
            {
              'lines': ['none line'],
              'props': {'user': 'none'},
            },
          ]),
        );
      });
    });

    test('changing the map after setting it has no effect', () {
      fakeAsync((async) {
        final props = {'user': 'alice'};
        final sender = _TestSender()..userProperties = props;
        sender.logLine('line');
        props['user'] = 'bob';
        var flushed = false;
        sender.flush().then((_) => flushed = true);
        async.elapse(Duration.zero);
        expect(flushed, isTrue);
        expect(sender.batches, [
          {
            'lines': ['line'],
            'props': {'user': 'alice'},
          },
        ]);
      });
    });

    test('setting values with nothing buffered sends nothing', () {
      fakeAsync((async) {
        final sender = _TestSender()..userProperties = {'user': 'alice'};
        sender.userProperties = {'user': 'none'};
        async.elapse(Duration.zero);
        expect(sender.attempts, 0);
      });
    });

    test('a failed send triggered by the setter is not uncaught', () {
      final uncaught = <Object>[];
      late _TestSender sender;
      runZonedGuarded(() {
        fakeAsync((async) {
          sender = _TestSender()..failWith = StateError('offline');
          sender.logLine('line');
          sender.userProperties = {'user': 'alice'};
          async.elapse(Duration.zero);
        });
      }, (e, _) => uncaught.add(e));
      // The setter sent the buffered line (and it failed) ...
      expect(sender.attempts, 1);
      // ... without the failure surfacing as an uncaught error.
      expect(uncaught, isEmpty);
    });
  });
}
