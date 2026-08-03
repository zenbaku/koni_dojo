import 'dart:isolate';

/// Parses in a fresh background isolate so the synchronous HTML/JSON work
/// (`html` DOM build, `jsonDecode`, selector/JSON-path extraction) lands off
/// the UI isolate and can't stutter a webtoon scroll.
///
/// [compute] must capture only isolate-sendable values: the fetched response
/// string, declarative config objects, and base URLs are all fine; it must
/// never close over `this`, the HTTP client, or any port. Assign the values
/// the closure needs to locals before passing it in.
Future<R> runParse<R>(R Function() compute) => Isolate.run(compute);
