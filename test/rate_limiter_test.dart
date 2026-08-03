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
}
