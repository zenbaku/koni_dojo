/// Dojo: a declarative manga/comic **source engine** for Dart.
///
/// Describe a manga site (HTML or JSON API) with a JSON **config** and this
/// library turns it into a running [Source] with the five reader operations:
/// popular, search, details, chapters, pages. No per-site code. Every
/// operation compiles to one linear pipeline runner; harder sites declare an
/// explicit `steps:` pipeline (POST requests, two-phase lookups, script-blob
/// readers, even a sandboxed `js` step).
///
/// Quick start:
/// ```dart
/// import 'package:koni_dojo/koni_dojo.dart';
///
/// final config = SourceConfig.fromJson({
///   'id': 'example', 'name': 'Example', 'lang': 'en',
///   'baseUrl': 'https://example.com',
///   'popular': {'path': '/popular?page={page}', 'itemSelector': 'div.card',
///               'titleSelector': 'a', 'urlSelector': 'a', 'urlAttr': 'href'},
///   'chapters': {'itemSelector': 'li.chapter', 'nameSelector': 'a', 'urlSelector': 'a'},
///   'pages': {'imageSelector': 'div.reader img', 'imageAttr': 'src'},
/// });
/// final source = htmlSource(config);
/// final page = await source.popular(1);
/// ```
///
/// The config format is documented at https://zenbaku.github.io/koni_dojo/.
library;

// Core: a Source and the values its operations return.
export 'src/source.dart';
export 'src/publication_status.dart';
export 'src/search_status.dart';

// Declarative configs + the engines that build a Source from them.
export 'src/extension_models.dart';
export 'src/config_source.dart';
export 'src/api_source.dart';

// The pipeline runner + its trace sink (for debugging a config's steps).
export 'src/pipeline.dart';

// Repository management: install/uninstall extensions, build the live sources.
export 'src/extension_manager.dart';

// The full reader-path smoke test (popular → details → chapters → pages).
export 'src/source_probe.dart';

// Injected capability seams: supply these from the host app; null-safe absent.
export 'src/js_runner.dart'; // run site JS for `js`-step configs
export 'src/web_view_fetcher.dart'; // WebView transport for CF-hard sources
export 'src/cloudflare_challenge.dart';
export 'src/page_body.dart'; // is this response an image, or a wall wearing 200? // the challenge exception + guard

// HTTP utilities a host commonly composes around the engine.
export 'src/http_retry.dart';
export 'src/request_timeout.dart';
export 'src/declared_hosts.dart';
