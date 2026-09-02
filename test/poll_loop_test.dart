import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/utils/poll_loop.dart';

/// [PollLoop] exists to make four failure modes structurally impossible, so
/// each is asserted here directly rather than through a caller.
void main() {
  group('start / stop', () {
    test('ticks once per interval', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 16));
        loop.dispose();

        expect(ticks, 3);
      });
    });

    test('does not tick before the first interval elapses', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 4));
        expect(ticks, 0);
        loop.dispose();
      });
    });

    test('fireImmediately runs one tick without waiting', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5), fireImmediately: true);

        async.flushMicrotasks();
        expect(ticks, 1);
        loop.dispose();
      });
    });

    test('starting twice leaves exactly one timer, not two', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5))
          ..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 10));
        loop.dispose();

        expect(ticks, 2, reason: 'the first timer must have been cancelled');
      });
    });

    test('stop halts further ticks', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 11));
        final atStop = ticks;
        loop.stop();
        async.elapse(const Duration(minutes: 5));

        expect(ticks, atStop);
      });
    });

    test('a stopped loop can be started again', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 5));
        loop.stop();

        loop.start(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 5));
        loop.dispose();

        expect(ticks, 2);
      });
    });

    test('isRunning and interval reflect the current state', () {
      fakeAsync((async) {
        final loop = PollLoop(name: 'test', onTick: () async {});
        expect(loop.isRunning, isFalse);
        expect(loop.interval, isNull);

        loop.start(const Duration(seconds: 5));
        expect(loop.isRunning, isTrue);
        expect(loop.interval, const Duration(seconds: 5));

        loop.stop();
        expect(loop.isRunning, isFalse);
        expect(loop.interval, isNull);
        async.flushTimers();
      });
    });
  });

  group('no overlap', () {
    test('a tick slower than the interval does not run concurrently', () {
      fakeAsync((async) {
        var started = 0;
        var concurrent = 0;
        var inFlight = 0;

        final loop = PollLoop(
          name: 'slow',
          onTick: () async {
            started++;
            inFlight++;
            if (inFlight > 1) concurrent++;
            await Future<void>.delayed(const Duration(seconds: 25));
            inFlight--;
          },
        )..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 60));
        loop.dispose();

        expect(concurrent, 0, reason: 'overlapping ticks must be dropped');
        expect(
          started,
          lessThan(12),
          reason: 'skipped ticks are dropped, not queued up for later',
        );
      });
    });

    test('the loop resumes normally once a slow tick finishes', () {
      fakeAsync((async) {
        var ticks = 0;
        var slow = true;

        final loop = PollLoop(
          name: 'slow-then-fast',
          onTick: () async {
            ticks++;
            if (slow) {
              slow = false;
              await Future<void>.delayed(const Duration(seconds: 12));
            }
          },
        )..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 30));
        loop.dispose();

        expect(ticks, greaterThan(2), reason: 'not wedged by the slow tick');
      });
    });
  });

  group('errors', () {
    test('a throwing tick does not kill the loop', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(
          name: 'throws',
          onTick: () async {
            ticks++;
            throw StateError('boom');
          },
        )..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 16));
        loop.dispose();

        expect(ticks, 3);
      });
    });

    test('a synchronously-throwing tick is also contained', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(
          name: 'sync-throws',
          // Not `async` in body terms — throws before its first await.
          onTick: () {
            ticks++;
            return Future<void>.error(StateError('boom'));
          },
        )..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 11));
        loop.dispose();

        expect(ticks, 2);
      });
    });
  });

  group('setInterval', () {
    test('an unchanged interval does not reset the schedule', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5));

        // Nudge it just before each due tick, the way an adaptive caller
        // that re-evaluates on every tick would.
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(seconds: 4));
          loop.setInterval(const Duration(seconds: 5));
          async.elapse(const Duration(seconds: 1));
        }
        loop.dispose();

        expect(ticks, 5, reason: 'resetting each time would starve the tick');
      });
    });

    test('a changed interval takes effect', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 10));

        async.elapse(const Duration(seconds: 10));
        expect(ticks, 1);

        loop.setInterval(const Duration(seconds: 2));
        async.elapse(const Duration(seconds: 10));
        loop.dispose();

        expect(ticks, 6, reason: '1 slow tick + 5 fast ones');
        expect(loop.interval, isNull, reason: 'disposed');
      });
    });

    test('is a no-op on a loop that was never started', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..setInterval(const Duration(seconds: 1));

        async.elapse(const Duration(seconds: 10));
        loop.dispose();

        expect(loop.isRunning, isFalse);
        expect(ticks, 0);
      });
    });
  });

  group('dispose', () {
    test('stops the loop', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..start(const Duration(seconds: 5));

        async.elapse(const Duration(seconds: 5));
        loop.dispose();
        async.elapse(const Duration(minutes: 10));

        expect(ticks, 1);
      });
    });

    test('a disposed loop refuses to start again', () {
      fakeAsync((async) {
        var ticks = 0;
        final loop = PollLoop(name: 'test', onTick: () async => ticks++)
          ..dispose()
          ..start(const Duration(seconds: 1));

        async.elapse(const Duration(seconds: 10));

        expect(loop.isRunning, isFalse);
        expect(loop.isDisposed, isTrue);
        expect(ticks, 0);
      });
    });

    test('is idempotent', () {
      final loop = PollLoop(name: 'test', onTick: () async {})
        ..start(const Duration(seconds: 5))
        ..dispose();
      expect(loop.dispose, returnsNormally);
    });
  });
}
