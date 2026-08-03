/// Runs a source response's synchronous parsing off the UI isolate: native
/// platforms parse in a background isolate (`Isolate.run`), the web build
/// parses inline after a yield (no isolates on web).
///
/// The scraping/API engines route their `html` DOM builds and `jsonDecode`
/// calls through here so a chapter's page-list resolution, which the download
/// queue performs concurrently while you read, never blocks the reader's
/// webtoon scroll with a multi-millisecond synchronous parse.
library;

export 'parse_isolate_io.dart'
    if (dart.library.js_interop) 'parse_isolate_web.dart';
