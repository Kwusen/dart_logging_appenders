import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:logging_appenders/base_remote_appender.dart';
import 'package:test/test.dart';

/// Sender which records sent lines instead of making requests, and can be
/// told to fail.
class _TestSender extends BaseHttpLogSender {
  /// When set, sends fail with this error.
  Object? failWith;

  final sent = <List<String>>[];

  @override
  Future<void> sendLogEventsWithHttp(
    List<LogEntry> entries,
    Map<String, String> userProperties,
    Future<void> cancelToken,
  ) {
    final error = failWith;
    if (error != null) {
      return Future.error(error);
    }
    sent.add(entries.map((e) => e.line).toList());
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
                onError: (Object e) => events.add('error'),
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
        final sender = _TestSender()..failWith = StateError('boom');
        sender.logLine('first');
        sender.flush().ignore();
        async.elapse(Duration.zero);
        expect(sender.sent, isEmpty);

        sender.failWith = null;
        sender.logLine('second');
        var flushed = false;
        sender.flush().then((_) => flushed = true);
        async.elapse(Duration.zero);
        expect(flushed, isTrue);
        // The failed batch is retried along with the new one.
        expect(
          sender.sent,
          unorderedEquals([
            ['first'],
            ['second'],
          ]),
        );
      });
    });
  });
}
