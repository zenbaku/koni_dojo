/// Token-bucket style throttle allowing at most [requests] calls per
/// [period], queueing excess callers in FIFO order. Used to be polite to
/// sources that declare a `rateLimit` in their config.
class RateLimiter {
  RateLimiter(this.requests, this.period)
    : assert(requests > 0),
      assert(period > Duration.zero);

  final int requests;
  final Duration period;

  final List<DateTime> _recent = [];
  Future<void> _queue = Future.value();

  /// Completes once the caller may proceed; callers are released in the
  /// order they called acquire.
  Future<void> acquire() {
    final turn = _queue.then((_) async {
      while (true) {
        final now = DateTime.now();
        _recent.removeWhere((t) => now.difference(t) >= period);
        if (_recent.length < requests) {
          _recent.add(now);
          return;
        }
        await Future<void>.delayed(period - now.difference(_recent.first));
      }
    });
    _queue = turn;
    return turn;
  }
}
