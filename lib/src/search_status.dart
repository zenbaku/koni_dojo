import 'dart:async';

/// A human-readable search phase sink ("Searching…", "Retrying…", …).
typedef SearchStatusSink = void Function(String phase);

/// Zone key the transport reports phases under. Internal: callers install a
/// sink via [withSearchStatus] rather than touching this directly.
const Object _statusKey = #konimangaSearchStatus;

/// Runs [body] with [sink] installed as the ambient search-status sink, so any
/// [reportSearchStatus] call made while [body] runs (including deep inside a
/// source op / the transport, across async gaps) is routed to [sink]. Lets the
/// UI show per-source progress without threading a callback through the whole
/// `Source` API. No sink installed → [reportSearchStatus] is a no-op.
Future<T> withSearchStatus<T>(
  SearchStatusSink sink,
  Future<T> Function() body,
) => runZoned(body, zoneValues: {_statusKey: sink});

/// Reports a search [phase] to the ambient sink installed by [withSearchStatus],
/// if any. Safe to call from anywhere; a no-op when no sink is active (e.g.
/// chapter-list resolution or the online reader, which don't install one).
void reportSearchStatus(String phase) {
  final sink = Zone.current[_statusKey];
  if (sink is SearchStatusSink) sink(phase);
}
