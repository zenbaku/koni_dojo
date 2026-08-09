import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'http_charset.dart';
import 'http_retry.dart';
import 'extended_selectors.dart';
import 'extension_models.dart';
import 'js_runner.dart';
import 'pipeline.dart';
import 'rate_limiter.dart';
import 'source.dart';
import 'web_view_fetcher.dart';

/// [config]'s `localStorageSeed`, patched with the resolved value of each of
/// its `localStoragePreferences`: [store]'s override when present, that
/// preference's own `defaultValue` otherwise. Pure and side-effect-free:
/// never mutates [config]'s own maps (they're shared across every fetch for
/// this source), always returns fresh copies along the path each toggle
/// writes to.
Map<String, dynamic> effectiveLocalStorageSeed(
  SourceConfig config,
  LocalStoragePreferenceStore? store,
) {
  if (config.localStoragePreferences.isEmpty) return config.localStorageSeed;
  final overrides = store?.valuesFor(config.id) ?? const {};
  var seed = config.localStorageSeed;
  for (final pref in config.localStoragePreferences) {
    final value = overrides[pref.id] ?? pref.defaultValue;
    seed = _setPath(seed, [pref.seedKey, ...pref.path], value);
  }
  return seed;
}

/// Clones along [path], writing [value] at the end; [map] and every nested
/// map along the way are left untouched, only the copies are patched, so a
/// config's shared `localStorageSeed` default is safe to reuse across every
/// source/toggle without one patch leaking into another.
Map<String, dynamic> _setPath(
  Map<String, dynamic> map,
  List<String> path,
  Object? value,
) {
  if (path.isEmpty) return map;
  final result = Map<String, dynamic>.of(map);
  if (path.length == 1) {
    result[path.first] = value;
    return result;
  }
  final nested = result[path.first];
  result[path.first] = _setPath(
    nested is Map<String, dynamic> ? nested : <String, dynamic>{},
    path.sublist(1),
    value,
  );
  return result;
}

/// One query-parameter contribution for [_HtmlEngine._appendParams]: send
/// [values] under [param], joined by [join] (empty repeats the parameter).
class _Param {
  const _Param(this.param, this.join, this.values);
  final String param;
  final String join;
  final Set<String> values;
}

/// Generic HTML-scraping source driven by a declarative [SourceConfig],
/// the engine behind installable declarative extensions.
class _HtmlEngine {
  _HtmlEngine(
    this.config, {
    http.Client? client,
    this.webViewFetcher,
    this.jsRunner,
  }) : client = client ?? http.Client(),
       _limiter = config.rateLimit == null
           ? null
           : RateLimiter(
               config.rateLimit!.requests,
               Duration(milliseconds: config.rateLimit!.perMs),
             );

  final SourceConfig config;
  final http.Client client;
  final RateLimiter? _limiter;

  /// When the config is `webview: true`, page GETs go through this instead of
  /// [client] (real browser fingerprint + Cloudflare clearance). Null → fall
  /// back to the HTTP client.
  final WebViewFetcher? webViewFetcher;

  /// Runs a `js` pipeline step (the injected QuickJS/JavaScriptCore seam). Null
  /// where no runtime is available; a config with a `js` step then surfaces a
  /// clear [JsUnavailable] instead of half-working.
  final JsRunner? jsRunner;

  /// Cloudflare clearance to replay (cookie + matching UA), wired in after
  /// construction by the [Source] facade; null in standalone use. Looked up
  /// per-request by that request's own target host, never [baseUrl], so a
  /// config can't get a clearance cookie replayed onto an unrelated host.
  ClearanceStore? clearanceStore;

  /// User overrides for `config.localStoragePreferences`, wired in after
  /// construction the same way [clearanceStore] is; null in standalone use
  /// (every preference then just falls back to its own declared default).
  LocalStoragePreferenceStore? localStoragePreferenceStore;

  String get id => config.id;

  String get name => config.name;

  String get lang => config.lang;

  String get baseUrl => config.baseUrl;

  Map<String, String> imageHeadersFor(String url) => {
    'Referer': '$baseUrl/',
    ...config.headers,
    ...?clearanceStore?.headersFor(url),
  };

  Future<void> throttle() => _limiter?.acquire() ?? Future.value();

  /// Fetches [url]'s raw HTML. Parsing is kept separate so the background
  /// methods ([fetchPages], [fetchChapters]) can hand the body to a background
  /// isolate, while interactive browsing parses inline through [_fetchDocument].
  ///
  /// [method] `POST` sends [body] with [extraHeaders] merged over the source's
  /// own, the path declarative sources take for AJAX-only endpoints.
  Future<String> _fetchBody(
    String url, {
    String method = 'GET',
    String body = '',
    Map<String, String> extraHeaders = const {},
  }) async {
    final uri = Uri.parse(url);
    final headers = {
      'User-Agent': 'Mozilla/5.0 (Konimanga)',
      ...config.headers,
      ...extraHeaders,
      // Last so a stored clearance's cookie + matching UA win over the
      // defaults, looked up by this request's own host, since a pipeline/
      // steps request can target a host other than [baseUrl].
      ...?clearanceStore?.headersFor(url),
    };
    // CF-hard hosts: fetch GETs through the WebView (browser fingerprint +
    // cleared session): cookie-replay over plain HTTP gets re-challenged.
    if (config.webview && webViewFetcher != null && method == 'GET') {
      await throttle();
      final seed = effectiveLocalStorageSeed(
        config,
        localStoragePreferenceStore,
      );
      return webViewFetcher!.fetchHtml(
        url,
        headers: headers,
        localStorageSeed: seed.isEmpty ? null : seed,
      );
    }
    final response = method == 'POST'
        ? await postWithRetry(
            client,
            uri,
            body: body,
            headers: headers,
            throttle: throttle,
          )
        : await getWithRetry(client, uri, headers: headers, throttle: throttle);
    return decodeHttpBody(response);
  }

  Future<Document> _fetchDocument(
    String url, {
    String method = 'GET',
    String body = '',
    Map<String, String> extraHeaders = const {},
  }) async => html_parser.parse(
    await _fetchBody(
      url,
      method: method,
      body: body,
      extraHeaders: extraHeaders,
    ),
  );

  /// Substitutes the listing placeholders (`{page}`, `{offset}`, `{query}`)
  /// into [template], shared by the request path and a POST body.
  ///
  /// [pathSafe] switches `{query}`'s escaping from query-string form
  /// (`Uri.encodeQueryComponent`, spaces as `+`) to path-segment form
  /// (`Uri.encodeComponent`, spaces as `%20`). For `tag`, whose `path`
  /// puts the tag value in the URL path itself (`/tags/{query}`), not a
  /// query parameter, the same way [search]'s `?kw={query}` does.
  static String _fillListing(
    String template,
    int page,
    int pageSize,
    String query, {
    bool pathSafe = false,
  }) => template
      .replaceAll('{page}', '$page')
      .replaceAll('{offset}', '${(page - 1) * pageSize}')
      .replaceAll(
        '{query}',
        pathSafe ? Uri.encodeComponent(query) : Uri.encodeQueryComponent(query),
      );

  /// Resolves [url] (possibly relative or protocol-relative) against the
  /// site's base URL.
  String absoluteUrl(String url) => _resolveUrl(baseUrl, url);

  String _text(Element root, String selector) => _textOf(root, selector);

  String _attr(Element root, String selector, String attr) =>
      _attrOf(root, selector, attr);

  /// First step of [chain] yielding a non-empty value (after its rewrite)
  /// wins.
  String _cover(Element root, List<CoverSource> chain) {
    for (final step in chain) {
      final value = _attr(root, step.selector, step.attr);
      if (value.isEmpty) continue;
      final rewritten = step.rewrite?.apply(value) ?? value;
      if (rewritten.isNotEmpty) return rewritten;
    }
    return '';
  }

  // Listings (popular/search) run through the pipeline engine like chapters and
  // pages: the adapter resolves the request target (the `{page}`/`{offset}`/
  // `{query}` substitution, query sanitization and any filter params) and
  // threads it in as `{listingUrl}`/`{listingBody}`, then [listingPipeline]
  // fetches and extracts the result records (and the has-next meta flag). Cover
  // chains travel as a [Locator] fallback chain, so per-item extraction is the
  // pipeline's; only request-building and the `CatalogPage` framing stay here.
  Future<CatalogPage> _fetchListing(
    ListingConfig listing,
    int page,
    String query, {
    FilterSelection? filters,
    bool pathSafeQuery = false,
    String Function(String url)? applyExtraParams,
  }) async {
    final mapped = _mapQuery(query, listing.queryMap) ?? query;
    final sanitized = (listing.queryReplace?.apply(mapped) ?? mapped).trim();
    final path = _fillListing(
      listing.path,
      page,
      listing.pageSize,
      sanitized,
      pathSafe: pathSafeQuery,
    );
    // An empty path is a deliberately valid listing config (the listing
    // lives at the site root), unlike `absoluteUrl`'s general empty-in
    // empty-out contract for extracted selector values (an unmatched
    // selector shouldn't turn into a phantom baseUrl link).
    var url = path.isEmpty ? baseUrl : absoluteUrl(path);
    if (listing.steps == null && filters != null && !filters.isEmpty) {
      url = _applyFilterParams(url, filters);
    }
    if (listing.steps == null && applyExtraParams != null) {
      url = applyExtraParams(url);
    }
    final body = listing.method == 'POST'
        ? _fillListing(
            listing.body,
            page,
            listing.pageSize,
            sanitized,
            pathSafe: pathSafeQuery,
          )
        : '';
    final base = baseUrl;
    final result = await runRecordListPipeline(
      listing.steps ?? listingPipeline(listing),
      {
        'baseUrl': base,
        // For the desugared pipeline: the fully-built request.
        'listingUrl': url,
        'listingBody': body,
        // For an explicit-steps pipeline that builds its own request.
        'page': '$page',
        'offset': '${(page - 1) * listing.pageSize}',
        // 1-based item index, for feeds that count from 1 (Blogger start-index).
        'start': '${(page - 1) * listing.pageSize + 1}',
        'query': pathSafeQuery
            ? Uri.encodeComponent(sanitized)
            : Uri.encodeQueryComponent(sanitized),
      },
      baseUrl: base,
      fetch: (u, {method = 'GET', body = '', headers = const {}}) =>
          _fetchBody(u, method: method, body: body, extraHeaders: headers),
    );
    final items = <SourceManga>[];
    for (final record in result.records) {
      final itemUrl = record['url'] ?? '';
      final title = record['title'] ?? '';
      if (itemUrl.isEmpty || title.isEmpty) continue;
      items.add(
        SourceManga(
          url: absoluteUrl(itemUrl),
          title: title,
          thumbnailUrl: absoluteUrl(record['cover'] ?? ''),
        ),
      );
    }
    // has-next: a count-based feed (meta `total`, e.g. a Blogger
    // openSearch$totalResults) compares against the page window; otherwise a
    // presence flag (meta `hasNext`, e.g. a next-page button).
    final total = result.meta['total'];
    final hasNext = total != null && total.isNotEmpty && listing.pageSize > 0
        ? page * listing.pageSize < (int.tryParse(total) ?? 0)
        : result.meta['hasNext'] == '1';
    return CatalogPage(items: items, hasNextPage: hasNext);
  }

  /// Appends `param=value(s)` query parameters onto [url]. An [_Param]
  /// whose `param` or `values` is empty contributes nothing. Shared by
  /// [_applyFilterParams] (each configured [FilterConfig] group) and
  /// [_applyTagParams] ([ListingConfig.tagParam]/[tagExcludeParam]).
  String _appendParams(String url, Iterable<_Param> entries) {
    final contributing = entries.where(
      (e) => e.param.isNotEmpty && e.values.isNotEmpty,
    );
    // Uri.replace(queryParameters: {}) appends a bare trailing "?" even when
    // the URL had no query string at all: a no-op contribution must stay a
    // true no-op, not silently mangle every already-correct URL that has
    // nothing to add (the common case: a single-tag source with neither
    // tagParam nor tagExcludeParam configured).
    if (contributing.isEmpty) return url;
    final uri = Uri.parse(url);
    final params = <String, List<String>>{
      for (final entry in uri.queryParametersAll.entries)
        entry.key: List.of(entry.value),
    };
    for (final entry in contributing) {
      (params[entry.param] ??= []).addAll(
        entry.join.isEmpty ? entry.values : [entry.values.join(entry.join)],
      );
    }
    return uri.replace(queryParameters: params).toString();
  }

  /// Appends the selected filters to a built listing URL, each group per
  /// its configured query parameter and join style.
  String _applyFilterParams(String url, FilterSelection filters) =>
      _appendParams(url, [
        for (final filter in config.filters) ...[
          _Param(filter.param, filter.join, filters.included(filter.id)),
          _Param(filter.excludeParam, filter.join, filters.excluded(filter.id)),
        ],
      ]);

  /// Appends included/excluded tags to a built `tag` listing URL, per
  /// [ListingConfig.tagParam]/[ListingConfig.tagExcludeParam], a no-op
  /// (both empty) for a source that only browses one tag at a time via
  /// `{query}` in [ListingConfig.path].
  String _applyTagParams(
    ListingConfig tag,
    String url,
    Set<String> included,
    Set<String> excluded,
  ) => _appendParams(url, [
    _Param(tag.tagParam, tag.tagJoin, included),
    _Param(tag.tagExcludeParam, tag.tagJoin, excluded),
  ]);

  Future<CatalogPage> fetchPopular(int page) =>
      _fetchListing(config.popular, page, '');

  bool get hasFilters => config.search != null && config.filters.isNotEmpty;

  /// Cached filter groups: discovered option lists are scraped once per
  /// session.
  Future<List<FilterGroup>>? _filterGroups;

  Future<List<FilterGroup>> fetchFilters() {
    if (!hasFilters) return Future.value(const []);
    return _filterGroups ??= _buildFilterGroups().catchError((Object e) {
      // Don't cache a failure: the next open of the sheet retries.
      _filterGroups = null;
      throw e;
    });
  }

  Future<List<FilterGroup>> _buildFilterGroups() async => [
    for (final filter in config.filters) await _filterGroup(filter),
  ];

  Future<FilterGroup> _filterGroup(FilterConfig filter) async {
    var options = [
      for (final option in filter.options)
        FilterOption(id: option.value, label: option.label),
    ];
    final from = filter.optionsFrom;
    if (from != null && from.itemSelector.isNotEmpty) {
      try {
        final doc = await _fetchDocument(absoluteUrl(from.path));
        final discovered = <FilterOption>[];
        for (final element in doc.querySelectorAllExt(from.itemSelector)) {
          final value = _attr(element, '', from.valueAttr);
          if (value.isEmpty) continue;
          final label = _attr(element, from.labelSelector, from.labelAttr);
          discovered.add(
            FilterOption(id: value, label: label.isEmpty ? value : label),
          );
        }
        if (discovered.isNotEmpty) {
          options = discovered..sort((a, b) => a.label.compareTo(b.label));
        }
      } catch (_) {
        // Static options back a failed discovery; without them the
        // failure surfaces.
        if (options.isEmpty) rethrow;
      }
    }
    return FilterGroup(
      id: filter.id,
      name: filter.name,
      options: options,
      supportsExclusion: filter.excludeParam.isNotEmpty,
    );
  }

  Future<CatalogPage> fetchSearch(
    String query,
    int page, {
    FilterSelection? filters,
  }) {
    final search = config.search;
    if (search == null) {
      return Future.value(CatalogPage(items: [], hasNextPage: false));
    }
    return _fetchListing(search, page, query, filters: filters);
  }

  /// Exact-match browse for one or more already-known tag values; see
  /// [SourceConfig.tag]. `pathSafeQuery: true` because [ListingConfig.path]
  /// typically puts the primary tag in the URL path (`/tags/{query}`), not
  /// a query string, unlike [fetchSearch]'s `?kw={query}`. Additional
  /// [included] beyond the first, and all of [excluded], only have an
  /// effect when [ListingConfig.tagParam]/[tagExcludeParam] are configured
  /// (see [TagCapabilities]).
  Future<CatalogPage> fetchTag(
    Set<String> included,
    int page, {
    Set<String> excluded = const {},
  }) {
    final tag = config.tag;
    if (tag == null || included.isEmpty) {
      return Future.value(CatalogPage(items: [], hasNextPage: false));
    }
    return _fetchListing(
      tag,
      page,
      included.first,
      pathSafeQuery: true,
      applyExtraParams: (url) => _applyTagParams(tag, url, included, excluded),
    );
  }

  /// What [fetchTag] can actually express for this source, derived from
  /// whether [ListingConfig.tagParam]/[tagExcludeParam] are configured,
  /// not a separately hand-declared flag, so it can't drift out of sync
  /// with what the URL-building code actually does.
  TagCapabilities get tagCapabilities => TagCapabilities(
    multiple: (config.tag?.tagParam ?? '').isNotEmpty,
    exclusion: (config.tag?.tagExcludeParam ?? '').isNotEmpty,
  );

  Future<SourceManga> fetchDetails(SourceManga manga) async {
    final details = config.details;
    final base = baseUrl;
    // Details fetches through the pipeline (so a multi-step details config works
    // too) but parses inline: the label-row metadata needs the whole document,
    // and browsing doesn't overlap the reader, so it stays on this isolate.
    final body = await runBodyPipeline(
      details.steps ??
          Pipeline([const Step(request: StepRequest(base: 'mangaUrl'))]),
      {'baseUrl': base, 'mangaUrl': absoluteUrl(manga.url)},
      baseUrl: base,
      fetch: (url, {method = 'GET', body = '', headers = const {}}) =>
          _fetchBody(url, method: method, body: body, extraHeaders: headers),
    );
    // documentElement (not .body): a selector can target <head> content (e.g.
    // meta[property="og:image"]). Jsoup-ported selectors expect that reach.
    final root = html_parser.parse(body).documentElement;
    if (root == null) return manga;
    final title = _text(root, details.titleSelector);
    if (title.isNotEmpty) manga.title = title;
    manga.author = _text(root, details.authorSelector);
    manga.description = _text(root, details.descriptionSelector);
    final cover = _cover(root, details.coverChain);
    if (cover.isNotEmpty) manga.thumbnailUrl = absoluteUrl(cover);
    final banner = _cover(root, details.bannerChain);
    if (banner.isNotEmpty) manga.bannerUrl = absoluteUrl(banner);
    final background = _cover(root, details.backgroundChain);
    if (background.isNotEmpty) manga.backgroundUrl = absoluteUrl(background);
    if (details.genreSelector.isNotEmpty) {
      manga.genres = _texts(root, details.genreSelector, details.genreAttr);
    }
    if (details.unlistedChaptersSelector.isNotEmpty) {
      final text = _attr(
        root,
        details.unlistedChaptersSelector,
        details.unlistedChaptersAttr,
      );
      manga.unlistedChapterCount =
          int.tryParse(RegExp(r'\d+').firstMatch(text)?.group(0) ?? '') ?? 0;
    }
    _applyRows(root, details, manga);
    return manga;
  }

  /// Fills [manga] from label rows (`<li><strong>Label:</strong> value</li>`
  /// and similar); values found here win over the flat `*Selector` fields.
  void _applyRows(Element root, DetailsConfig details, SourceManga manga) {
    final rows = details.rows;
    if (rows == null) return;
    final values = <String, List<String>>{};
    for (final row in root.querySelectorAllExt(rows.itemSelector)) {
      final label = _text(row, rows.labelSelector).toLowerCase();
      if (label.isEmpty) continue;
      rows.fields.forEach((field, spec) {
        if (!spec.labels.any((l) => label.contains(l.toLowerCase()))) return;
        final elements = spec.valueSelector.isEmpty
            ? [row]
            : row.querySelectorAllExt(spec.valueSelector);
        for (final element in elements) {
          // Unlike a flat field's single, tightly-scoped text node, a
          // rows value is often a whole row/wrapper element spanning
          // several children of pretty-printed HTML — plain .trim() only
          // strips the ends, leaving the source's internal newlines/
          // indentation embedded in the value. Collapse to single spaces,
          // and strip one trailing list-separator char (a common markup
          // shape wraps a tag *and* its own separator comma in one
          // element, e.g. `<span><a>Action</a>,</span>` — a value
          // selector landing on the wrapper, not the inner link, carries
          // that separator as if it were real data). Both mirror
          // simulateRowsFieldValue (webview/lib/dom_tree_algo.dart), which
          // this must keep predicting accurately.
          final text = element.text
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ')
              .replaceFirst(RegExp(r'[,;]$'), '');
          if (text.isNotEmpty) (values[field] ??= []).add(text);
        }
      });
    }
    values.forEach((field, found) {
      final joined = found.join(rows.fields[field]!.join);
      switch (field) {
        case 'author':
          manga.author = joined;
        case 'description':
          manga.description = joined;
        case 'genres':
          manga.genres = found;
        case 'status':
          manga.status = _mapStatus(found.first, details.statusMap);
      }
    });
  }

  PublicationStatus _mapStatus(String text, Map<String, String> statusMap) {
    final lower = text.trim().toLowerCase();
    for (final entry in statusMap.entries) {
      if (entry.key.toLowerCase() == lower) {
        return PublicationStatus.fromName(entry.value);
      }
    }
    // Without a (matching) map, site text that already is a canonical
    // status name still works.
    return PublicationStatus.fromName(lower);
  }

  /// Case-insensitive exact-match lookup for [ListingConfig.queryMap]; null
  /// when [query] isn't a key, so the caller falls through to its own
  /// [ListingConfig.queryReplace]/raw-query default.
  String? _mapQuery(String query, Map<String, String> queryMap) {
    final lower = query.trim().toLowerCase();
    for (final entry in queryMap.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  // [fetchChapters] and [fetchPages] run during the background download drain
  // (the resolution gate scrapes queued chapters' page lists while you read),
  // so they parse off the UI isolate. Both route through the pipeline engine
  // ([chaptersPipeline]/[pagesPipeline] desugar the config into a [Pipeline];
  // the runner fetches on this isolate and runs each step's parse+extract
  // through [runParse], so the heavy DOM/JSON work stays off the UI isolate as
  // before, and a config carrying explicit `steps` (e.g. Madara's two-phase id
  // lookup, or HTML page → capture id → JSON ajax) runs through the same path).
  // The interactive browsing methods above parse inline since they don't
  // overlap reading.

  Future<List<SourceChapter>> fetchChapters(SourceManga manga) async {
    final cfg = config.chapters;
    final base = baseUrl;
    final result = await runRecordListPipeline(
      cfg.steps ?? chaptersPipeline(cfg),
      {'baseUrl': base, 'mangaUrl': absoluteUrl(manga.url)},
      baseUrl: base,
      js: jsRunner,
      fetch: (url, {method = 'GET', body = '', headers = const {}}) =>
          _fetchBody(url, method: method, body: body, extraHeaders: headers),
    );
    final chapters = <SourceChapter>[];
    for (final record in result.records) {
      final url = record['url'] ?? '';
      if (url.isEmpty) continue;
      final name = record['name'] ?? '';
      chapters.add(
        SourceChapter(
          url: absoluteUrl(url),
          name: name.isEmpty ? 'Chapter ${chapters.length + 1}' : name,
          dateUpload: parseSourceDate(record['date']),
          locked: record['locked'] == '1',
          official:
              cfg.officialValue.isNotEmpty &&
              (record['official'] ?? '').contains(cfg.officialValue),
        ),
      );
    }
    return cfg.reversed ? chapters.reversed.toList() : chapters;
  }

  Future<List<String>> fetchPages(SourceChapter chapter) async {
    final source = absoluteUrl(chapter.url);
    final vars = {
      'baseUrl': baseUrl,
      'chapterUrl': source,
      'chapterId': chapter.url,
    };
    Future<List<String>> run(Pipeline pipeline) => runFlatListPipeline(
      pipeline,
      vars,
      baseUrl: baseUrl,
      js: jsRunner,
      fetch: (url, {method = 'GET', body = '', headers = const {}}) =>
          _fetchBody(url, method: method, body: body, extraHeaders: headers),
    );

    final pages = config.pages;
    final result = await run(pages.steps ?? pagesPipeline(pages));

    // MangaThemesia configs ship a `script` blob (`ts_reader.run`) as the primary
    // page source and an `imageSelector` as a fallback. When a site drops the
    // script (so the regex matches nothing) but still renders the `<img>`s, run
    // the selector instead of returning empty; otherwise the fallback the config
    // declares never fires. Desugared configs only; an explicit `steps:` pipeline
    // owns its own behaviour.
    if (result.isEmpty &&
        pages.steps == null &&
        pages.script != null &&
        pages.imageSelector.isNotEmpty) {
      return run(
        pagesPipeline(
          PagesConfig(
            request: pages.request,
            imageSelector: pages.imageSelector,
            imageAttr: pages.imageAttr,
          ),
        ),
      );
    }
    return result;
  }
}

/// Builds an HTML-scraping [Source] from a declarative [SourceConfig], the
/// composition entry point that replaces `class ConfigSource extends Source`.
/// Behaviour lives in the [_HtmlEngine] closures; the returned value is the one
/// concrete `Source`. Refs in / fresh models out; page refs carry the cover/
/// referer headers the engine would have applied.
Source htmlSource(
  SourceConfig config, {
  http.Client? client,
  WebViewFetcher? webViewFetcher,
  JsRunner? jsRunner,
}) {
  final engine = _HtmlEngine(
    config,
    client: client,
    webViewFetcher: webViewFetcher,
    jsRunner: jsRunner,
  );
  return Source(
    info: SourceInfo(
      id: config.id,
      name: config.name,
      lang: config.lang,
      baseUrl: config.baseUrl,
      icon: config.icon,
    ),
    // Transport for Source.imageBytes: the engine owns the fetch policy,
    // this just hands it the wire.
    client: engine.client,
    webViewFetcher: engine.webViewFetcher,
    imageHeaders: engine.imageHeadersFor,
    throttle: engine.throttle,
    clearanceSink: (store) => engine.clearanceStore = store,
    localStoragePreferenceSink: (store) =>
        engine.localStoragePreferenceStore = store,
    warmImageByUrl: config.warmImageByUrl,
    warmImageViaImgTag: config.warmImageViaImgTag,
    requiresWebView: config.webview,
    loginUrl: config.loginUrl,
    localStoragePreferences: [
      for (final p in config.localStoragePreferences)
        (id: p.id, label: p.label, defaultValue: p.defaultValue),
    ],
    ops: SourceOps(
      popular: (q) => engine.fetchPopular(q.page),
      search: (q) => engine.fetchSearch(q.query, q.page, filters: q.filters),
      details: (ref) => engine.fetchDetails(
        SourceManga(
          url: ref.url,
          title: '',
          thumbnailUrl: ref.knownThumbnailUrl,
        ),
      ),
      chapters: (ref) =>
          engine.fetchChapters(SourceManga(url: ref.url, title: '')),
      pages: (ref) async {
        final urls = await engine.fetchPages(
          SourceChapter(url: ref.url, name: ''),
        );
        return [
          for (final u in urls)
            PageRef(Uri.parse(u), headers: engine.imageHeadersFor(u)),
        ];
      },
      filters: engine.hasFilters ? engine.fetchFilters : null,
      tag: config.tag != null
          ? (q) => engine.fetchTag(q.included, q.page, excluded: q.excluded)
          : null,
      tagCapabilities: engine.tagCapabilities,
    ),
  );
}

// Top-level, isolate-runnable parsing helpers. They stay pure (no `this`) so
// [fetchChapters]/[fetchPages] can run them in a background isolate; the
// instance helpers above delegate to them so there's one source of truth.

/// Resolves [url] (possibly relative or protocol-relative) against [baseUrl].
String _resolveUrl(String baseUrl, String url) {
  if (url.isEmpty) return url;
  return Uri.parse(baseUrl).resolve(url).toString();
}

String _textOf(Element root, String selector) {
  if (selector.isEmpty) return '';
  return root.querySelectorExt(selector)?.text.trim() ?? '';
}

String _attrOf(Element root, String selector, String attr) {
  final element = selector.isEmpty ? root : root.querySelectorExt(selector);
  if (element == null) return '';
  if (attr.isEmpty) return element.text.trim();
  return element.attributes[attr]?.trim() ?? '';
}

/// Every element matching [selector], each read as text (or [attr] when
/// set), the unlabeled-list counterpart to [_attrOf]'s single match, for
/// [DetailsConfig.genreSelector].
List<String> _texts(Element root, String selector, String attr) {
  final values = <String>[];
  for (final element in root.querySelectorAllExt(selector)) {
    final value = attr.isEmpty
        ? element.text.trim()
        : (element.attributes[attr] ?? '').trim();
    if (value.isNotEmpty) values.add(value);
  }
  return values;
}
