import 'dart:async';

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

/// Caps how many operations run **at once**, without spacing them out in
/// time — the shape image fetches want, as opposed to [RateLimiter]'s.
///
/// The distinction is the whole reason this exists. A site's declared
/// `rateLimit` is a *minimum spacing*: with the near-universal `1 per 1000ms`
/// it puts a full second between consecutive requests, and it cannot burst,
/// because a sliding window that is already full has nothing to hand out. That
/// is the right shape for a site's HTML/API endpoints, where the point is to
/// keep sustained load off someone's server. It is the wrong shape for the
/// image CDN a source's pages actually live on, for two reasons:
///
/// * **The CDN never declared it.** A config's `rateLimit` is about the site;
///   pages routinely come from an unrelated host that has its own capacity and
///   was never part of that promise.
/// * **Spacing is what costs a phone its battery.** Radio energy is paid per
///   transition out of idle, and a modem stays in its high-power state for
///   seconds after each transfer. Requests one second apart never let that
///   tail expire, so the radio is pinned for an entire reading session —
///   whereas the same bytes fetched as one short burst leave it idle in
///   between. Measured on a real source: a reader's four preloaded pages took
///   6415ms spaced, 433ms concurrent, for identical bytes.
///
/// So images get a concurrency cap and no spacing, which is what the host
/// app's native download runner had already settled on independently for the
/// very same fetches.
///
/// Callers wait their turn in FIFO order. [run] always releases, including
/// when [action] throws — an image fetch abandoned mid-queue (the reader left
/// the chapter) must not take a permit with it, or the cap bleeds away a few
/// chapters into a session and images stop loading with no error to show.
class ConcurrencyGate {
  ConcurrencyGate(this.limit) : assert(limit > 0);

  /// How many operations may be in flight at once.
  final int limit;

  int _active = 0;
  final List<Completer<void>> _waiting = [];

  /// Runs [action] once a slot is free, releasing the slot when it settles.
  Future<T> run<T>(Future<T> Function() action) async {
    if (_active >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _active++;
    }
    try {
      return await action();
    } finally {
      // Hand the slot straight to the next waiter rather than dropping
      // [_active] and making it re-check: the count stays exactly the number
      // of permits outstanding, which is what makes the cap hold under a
      // burst of aborts.
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }
}
