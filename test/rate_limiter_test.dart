import 'dart:async';

import 'package:test/test.dart';
import 'package:koni_dojo/src/rate_limiter.dart';

void main() {
  test('spaces out callers beyond the budget', () async {
    final limiter = RateLimiter(1, const Duration(milliseconds: 100));
    final watch = Stopwatch()..start();
    await limiter.acquire();
    await limiter.acquire();
    await limiter.acquire();
    // Third acquire can only run once two full periods have elapsed.
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(200));
  });

  test('allows a full budget through without waiting', () async {
    final limiter = RateLimiter(3, const Duration(seconds: 10));
    final watch = Stopwatch()..start();
    await limiter.acquire();
    await limiter.acquire();
    await limiter.acquire();
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });

  test('releases queued callers in FIFO order', () async {
    final limiter = RateLimiter(1, const Duration(milliseconds: 20));
    final order = <int>[];
    await Future.wait([
      for (var i = 0; i < 4; i++) limiter.acquire().then((_) => order.add(i)),
    ]);
    expect(order, [0, 1, 2, 3]);
  });

  group('ConcurrencyGate', () {
    test('runs up to the limit at once and no more', () async {
      final gate = ConcurrencyGate(3);
      var active = 0;
      var peak = 0;
      final release = <Completer<void>>[];
      final runs = [
        for (var i = 0; i < 8; i++)
          gate.run(() async {
            active++;
            if (active > peak) peak = active;
            final done = Completer<void>();
            release.add(done);
            await done.future;
            active--;
          }),
      ];
      // Let the first wave start, then drain one at a time.
      await Future<void>.delayed(Duration.zero);
      expect(peak, 3);
      while (release.isNotEmpty) {
        release.removeAt(0).complete();
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(runs);
      expect(peak, 3, reason: 'never exceeded the cap');
    });

    test('does not space callers out in time', () async {
      final gate = ConcurrencyGate(4);
      final watch = Stopwatch()..start();
      await Future.wait([for (var i = 0; i < 4; i++) gate.run(() async {})]);
      // The whole point: a burst is a burst, unlike RateLimiter above.
      expect(watch.elapsedMilliseconds, lessThan(50));
    });

    test('releases the slot when the action throws', () async {
      // The abort path: a reader leaving a chapter abandons its preloads, and
      // each one throws SourceImageAborted from inside the gate. A permit lost
      // per abandoned page would shrink the cap to nothing a few chapters into
      // a session, and images would stop loading with no error to show.
      final gate = ConcurrencyGate(2);
      for (var i = 0; i < 10; i++) {
        await expectLater(
          gate.run(() async => throw StateError('abandoned')),
          throwsStateError,
        );
      }
      final watch = Stopwatch()..start();
      await Future.wait([for (var i = 0; i < 2; i++) gate.run(() async {})]);
      expect(
        watch.elapsedMilliseconds,
        lessThan(50),
        reason: 'the cap survived ten failures',
      );
    });

    test('hands a freed slot to the next waiter in FIFO order', () async {
      final gate = ConcurrencyGate(1);
      final order = <int>[];
      await Future.wait([
        for (var i = 0; i < 4; i++) gate.run(() async => order.add(i)),
      ]);
      expect(order, [0, 1, 2, 3]);
    });
  });
}
