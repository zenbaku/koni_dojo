import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'http_charset.dart';
import 'http_retry.dart';
import 'extension_models.dart';
import 'json_path.dart';
import 'pipeline.dart';
import 'rate_limiter.dart';
import 'source.dart';

/// Absolute upper bound on chapters paged from a total-reporting feed, so a
/// bogus/huge reported total can't drive an unbounded number of requests. Well
/// above any real series' chapter count.
const _chapterFeedCeiling = 10000;

/// Parses a JSON count that may arrive as a number *or* a numeric string (some
/// APIs quote their `total`); null when it isn't a recognisable integer.
int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final s = value.trim();
    return int.tryParse(s) ?? double.tryParse(s)?.toInt();
  }
  return null;
}

/// JS-like truthiness for a raw JSON value, used by [ApiChapterSpec.locked]
/// to cover a site's lock flag whichever shape it comes in: a boolean
/// (`"premium": true`), a price (`"price": 99` locked / `"price": 0` free),
/// or a string. Null, `false`, `0`, and `""` are the only falsy values;
/// everything else (including a non-empty Map/List) is truthy.
bool _isTruthy(Object? value) => switch (value) {
  null => false,
  bool b => b,
  num n => n != 0,
  String s => s.isNotEmpty,
  _ => true,
};

/// Normalizes a JSON-API description to plain text. Some APIs (notably heancms)
/// return the synopsis as HTML (`<p>…</p>`), unlike the HTML engine which yields
/// plain text via `.text`; left as-is it shows raw tags in the UI. Block/`<br>`
/// tags become line breaks, remaining tags are stripped and entities decoded.
/// Strings with no tag-like content are returned untouched, so markdown/plain
/// descriptions are unaffected.
String _plainText(String value) {
  if (!RegExp(r'<[a-zA-Z/!]').hasMatch(value)) return value;
  final withBreaks = value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|li|h[1-6])>', caseSensitive: false), '\n');
  final text = html_parser.parseFragment(withBreaks).text ?? '';
  return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// Resolves [url] (possibly relative or protocol-relative) against [baseUrl]
/// (a no-op when [url] is already absolute). Same convention as the HTML
/// dialect's `_resolveUrl` in config_source.dart/pipeline.dart.
String _resolveUrl(String baseUrl, String url) {
  if (url.isEmpty) return url;
  return Uri.parse(baseUrl).resolve(url).toString();
}

/// Generic JSON-API source driven by a declarative [ApiSourceConfig], the
/// API-dialect counterpart of `ConfigSource`. Every JSON:API-style curated
/// source runs on this engine; nothing in here is specific to any one site.
class _ApiEngine {
  _ApiEngine(this.config, {http.Client? client})
    : client = client ?? http.Client(),
      _limiter = config.rateLimit == null
          ? null
          : RateLimiter(
              config.rateLimit!.requests,
              Duration(milliseconds: config.rateLimit!.perMs),
            ),
      _imageLimiter = config.imageRateLimit == null
          ? null
          : RateLimiter(
              config.imageRateLimit!.requests,
              Duration(milliseconds: config.imageRateLimit!.perMs),
            );

  final ApiSourceConfig config;
  final http.Client client;
  final RateLimiter? _limiter;

  /// Separate from [_limiter], and normally null — see
  /// `SourceConfig.imageRateLimit`.
  final RateLimiter? _imageLimiter;

  /// Cloudflare clearance to replay (cookie + matching UA), wired in after
  /// construction by the [Source] facade; null in standalone use. Looked up
  /// per-request by that request's own target host, never [baseUrl], so a
  /// config can't get a clearance cookie replayed onto an unrelated host.
  ClearanceStore? clearanceStore;

  String get id => config.id;

  String get name => config.name;

  String get lang => config.lang;

  String get baseUrl => config.baseUrl;

  Map<String, String> imageHeadersFor(String url) => {
    ...config.imageHeaders,
    ...?clearanceStore?.headersFor(url),
  };

  Future<void> throttle() => _limiter?.acquire() ?? Future.value();

  /// Null unless the config asked for image spacing, so `Source` can tell
  /// "no extra rate" from "a rate of zero delay" and skip the await entirely.
  Future<void> Function()? get imageThrottle => _imageLimiter?.acquire;

  Map<String, String> get _vars => {'lang': config.lang};

  /// Builds the request URL: the config path with its placeholders
  /// substituted, resolved against the API root.
  String _url(String path, Map<String, String> vars) =>
      config.apiUrl + JsonValueSpec.substituteVars(path, vars);

  /// Parameters left empty by substitution are dropped, so a listing path
  /// carrying `title={query}` doesn't send `title=` when browsing by
  /// filters alone.
  String _dropEmptyParams(String url) {
    final uri = Uri.parse(url);
    if (uri.query.isEmpty) return url;
    return uri
        .replace(
          queryParameters: <String, List<String>>{
            for (final entry in uri.queryParametersAll.entries)
              if (entry.value.any((v) => v.isNotEmpty))
                entry.key: [
                  for (final value in entry.value)
                    if (value.isNotEmpty) value,
                ],
          },
        )
        .toString();
  }

  /// Fetches and decodes [url] through the pipeline runner: a single-step JSON
  /// pipeline today, but the same path a config carrying explicit `steps`
  /// (capture an id, then request again) would take. The decode runs off the UI
  /// isolate (a chapter/page response can be large and resolution runs while
  /// the reader scrolls) and the engine's evaluators read the returned root.
  Future<Object?> _getJson(String url) => runJsonPipeline(
    Pipeline([const Step(request: StepRequest(base: 'url'))]),
    {'url': url},
    baseUrl: config.apiUrl,
    fetch: _fetchBody,
  );

  /// One request for the runner: GET (or POST for a step that needs it),
  /// returning the raw body. Clearance headers go last so a stored clearance's
  /// cookie + matching UA win over the defaults, looked up by [url]'s own
  /// host, since a pipeline/steps request can target a host other than
  /// [baseUrl].
  Future<String> _fetchBody(
    String url, {
    String method = 'GET',
    String body = '',
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse(url);
    final merged = {
      'User-Agent': 'Konimanga/0.1',
      ...config.headers,
      ...headers,
      ...?clearanceStore?.headersFor(url),
    };
    final response = method == 'POST'
        ? await postWithRetry(
            client,
            uri,
            body: body,
            headers: merged,
            throttle: throttle,
          )
        : await getWithRetry(client, uri, headers: merged, throttle: throttle);
    return decodeHttpBody(response);
  }

  /// The decoded response root for one operation request: its explicit [steps]
  /// pipeline (seeded with the source URLs + the op's [vars]) when present, else
  /// a single GET of the [fallback] URL the op built from its sugar fields. The
  /// adapter then reads items/fields off the root with the engine's evaluators
  /// either way: `steps` only changes how the response is fetched.
  Future<Object?> _root(
    Pipeline? steps,
    String fallback,
    Map<String, String> vars,
  ) {
    if (steps == null) return _getJson(fallback);
    return runJsonPipeline(
      steps,
      {'baseUrl': config.baseUrl, 'apiUrl': config.apiUrl, ...vars},
      baseUrl: config.apiUrl,
      fetch: _fetchBody,
    );
  }

  SourceManga? _mangaFrom(Object? item, {Object? root}) {
    final spec = config.manga;
    final url = spec.url.evaluate(item, vars: _vars, root: root);
    if (url == null || url.isEmpty) return null;
    return SourceManga(
      url: url,
      title: spec.title.evaluate(item, vars: _vars, root: root) ?? '',
      description: _plainText(
        spec.description.evaluate(item, vars: _vars, root: root) ?? '',
      ),
      author: spec.author.evaluate(item, vars: _vars, root: root) ?? '',
      thumbnailUrl: spec.cover.evaluate(item, vars: _vars, root: root) ?? '',
      genres: spec.genres.evaluate(item, vars: _vars),
    );
  }

  Future<CatalogPage> _fetchListing(
    ApiListingConfig listing,
    int page, {
    String query = '',
    FilterSelection? filters,
    bool pathSafeQuery = false,
    String Function(String url)? applyExtraParams,
  }) async {
    final vars = {
      ..._vars,
      'page': '$page',
      'offset': '${(page - 1) * listing.pageSize}',
      'query': pathSafeQuery
          ? Uri.encodeComponent(query)
          : Uri.encodeQueryComponent(query),
    };
    var url = _dropEmptyParams(_url(listing.path, vars));
    if (listing.steps == null && filters != null && !filters.isEmpty) {
      url = await _applyFilterParams(url, filters);
    }
    if (listing.steps == null && applyExtraParams != null) {
      url = applyExtraParams(url);
    }
    final json = await _root(listing.steps, url, vars);
    final list = readJsonPath(json, listing.items);
    final items = <SourceManga>[];
    if (list is List) {
      for (final item in list) {
        final manga = _mangaFrom(item, root: json);
        if (manga != null) items.add(manga);
      }
    }
    final total = readJsonPath(json, listing.totalPath);
    final hasNext = listing.totalPath.isNotEmpty && total is num
        ? page * listing.pageSize < total
        : listing.pageSize > 0 && items.length >= listing.pageSize;
    return CatalogPage(items: items, hasNextPage: hasNext);
  }

  Future<CatalogPage> fetchPopular(int page) =>
      _fetchListing(config.popular, page);

  Future<CatalogPage> fetchSearch(
    String query,
    int page, {
    FilterSelection? filters,
  }) {
    final search = config.search;
    if (search == null) {
      return Future.value(CatalogPage(items: [], hasNextPage: false));
    }
    return _fetchListing(search, page, query: query, filters: filters);
  }

  /// Exact-match browse for one or more already-known tag values; see
  /// [SourceConfig.tag]. `pathSafeQuery: true` for the same reason as the
  /// HTML dialect's `_HtmlEngine.fetchTag`: a REST-shaped `tag.path` like
  /// `/manga?tags[]={query}` still wants a *path*-segment-correct value if
  /// the tag ever lands in a path component rather than a query value.
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
      query: included.first,
      pathSafeQuery: true,
      applyExtraParams: (url) => _applyTagParams(tag, url, included, excluded),
    );
  }

  /// What [fetchTag] can actually express for this source, derived from
  /// whether [ApiListingConfig.tagParam]/[tagExcludeParam] are configured.
  TagCapabilities get tagCapabilities => TagCapabilities(
    multiple: (config.tag?.tagParam ?? '').isNotEmpty,
    exclusion: (config.tag?.tagExcludeParam ?? '').isNotEmpty,
  );

  Future<SourceManga> fetchDetails(SourceManga manga) async {
    final details = config.details;
    if (details == null) return manga;
    final vars = {..._vars, 'url': manga.url};
    final json = await _root(details.steps, _url(details.path, vars), vars);
    final fresh = _mangaFrom(readJsonPath(json, details.item), root: json);
    if (fresh == null) return manga;
    manga
      ..title = fresh.title.isEmpty ? manga.title : fresh.title
      ..author = fresh.author
      ..description = fresh.description
      ..thumbnailUrl = fresh.thumbnailUrl.isEmpty
          ? manga.thumbnailUrl
          : fresh.thumbnailUrl;
    if (fresh.genres.isNotEmpty) manga.genres = fresh.genres;
    return manga;
  }

  Future<List<SourceChapter>> fetchChapters(SourceManga manga) async {
    final cfg = config.chapters;
    final spec = cfg.chapter;
    final chapters = <SourceChapter>[];
    var page = 1;
    var offset = 0;
    while (true) {
      final vars = {
        ..._vars,
        'url': manga.url,
        'page': '$page',
        'offset': '$offset',
      };
      final json = await _root(cfg.steps, _url(cfg.path, vars), vars);
      final list = readJsonPath(json, cfg.items);
      final data = list is List ? list : const [];
      for (final item in data) {
        if (spec.skipIf.isNotEmpty && readJsonPath(item, spec.skipIf) != null) {
          continue;
        }
        final url = spec.url.evaluate(item, vars: _vars, root: json);
        if (url == null || url.isEmpty) continue;
        chapters.add(
          SourceChapter(
            url: url,
            name: spec.name.evaluate(item, vars: _vars, root: json),
            number:
                double.tryParse(
                  spec.number.evaluate(item, vars: _vars) ?? '',
                ) ??
                -1,
            dateUpload: parseSourceDate(
              spec.date.evaluate(item, vars: _vars, root: json),
            ),
            locked:
                spec.locked.isNotEmpty &&
                _isTruthy(readJsonPath(item, spec.locked)),
            official:
                spec.official.isNotEmpty &&
                _isTruthy(readJsonPath(item, spec.official)),
          ),
        );
      }
      offset += cfg.pageSize;
      page++;
      // Stop condition. When the feed reports a total, that total bounds the
      // loop, so page through ALL of it: an ascending long series otherwise
      // silently loses its NEWEST chapters (they sit on the last pages), capped
      // at maxItems. maxItems only guards a runaway feed that reports no total;
      // a hard ceiling protects against a bogus huge total. The total is parsed
      // leniently, so a string like "1234" no longer collapses to 0 and cuts the
      // feed off after page one.
      final total = _asInt(readJsonPath(json, cfg.totalPath));
      final limit = total == null
          ? cfg.maxItems
          : (total < _chapterFeedCeiling ? total : _chapterFeedCeiling);
      final lastPartialPage = total == null && data.length < cfg.pageSize;
      if (data.isEmpty || offset >= limit || lastPartialPage) break;
    }
    return chapters;
  }

  Future<List<String>> fetchPages(SourceChapter chapter) async {
    final cfg = config.pages;
    final vars = {..._vars, 'url': chapter.url};
    final json = await _root(cfg.steps, _url(cfg.path, vars), vars);
    final list = readJsonPath(json, cfg.items);
    if (list is! List) {
      throw const FormatException(
        'Unexpected response from the source page server',
      );
    }
    return [
      // Pass the element as `item` too, so a template like `{url}` or
      // `{image}` can lift a field off per-page objects, not just the whole
      // `{value}`. Item lookups fall back to `root`, so string-element
      // sources are unaffected.
      for (final item in list)
        // Resolved against apiUrl: most API pages values already arrive
        // absolute (a no-op here), but confirmed live against a real source
        // whose "local"-storage chapters return a bare `uploads/…` path with
        // no host at all.
        _resolveUrl(
          config.apiUrl,
          renderJsonTemplate(
            cfg.template,
            value: '$item',
            item: item,
            root: json,
          ),
        ),
    ];
  }

  // ---------------------------------------------------------------------
  // Filters.

  bool get hasFilters => config.search != null && config.filters.isNotEmpty;

  /// Cached filter groups (discovered option lists are fetched once per
  /// session) and which filter config each shown group came from: a
  /// `groupBy` discovery splits one config into several groups.
  Future<List<FilterGroup>>? _filterGroups;
  final Map<String, FilterConfig> _groupOwner = {};

  Future<List<FilterGroup>> fetchFilters() {
    if (!hasFilters) return Future.value(const []);
    return _filterGroups ??= _buildFilterGroups().catchError((Object e) {
      // Don't cache a failure: the next open of the sheet retries.
      _filterGroups = null;
      throw e;
    });
  }

  Future<List<FilterGroup>> _buildFilterGroups() async {
    final groups = <FilterGroup>[];
    for (final filter in config.filters) {
      final from = filter.optionsFrom;
      List<FilterGroup> resolved;
      if (from == null) {
        resolved = [_staticGroup(filter)];
      } else {
        try {
          resolved = await _discoverGroups(filter, from);
        } catch (_) {
          // Static options back a failed discovery; without them the
          // failure surfaces.
          if (filter.options.isEmpty) rethrow;
          resolved = [_staticGroup(filter)];
        }
      }
      for (final group in resolved) {
        _groupOwner[group.id] = filter;
      }
      groups.addAll(resolved);
    }
    return groups;
  }

  FilterGroup _staticGroup(FilterConfig filter) => FilterGroup(
    id: filter.id,
    name: filter.name,
    options: [
      for (final option in filter.options)
        FilterOption(id: option.value, label: option.label),
    ],
    supportsExclusion: filter.excludeParam.isNotEmpty,
  );

  Future<List<FilterGroup>> _discoverGroups(
    FilterConfig filter,
    OptionsFromConfig from,
  ) async {
    final json = await _getJson(_url(from.path, _vars));
    final list = readJsonPath(json, from.items);
    if (list is! List) {
      throw const FormatException('Unexpected filter options response');
    }
    final groupBy = from.groupBy;
    final byKey = <String, List<FilterOption>>{};
    for (final item in list) {
      final value = from.value.evaluate(item, vars: _vars);
      if (value == null || value.isEmpty) continue;
      final label = from.label.evaluate(item, vars: _vars) ?? value;
      final key = groupBy == null
          ? ''
          : '${readJsonPath(item, groupBy.path) ?? ''}';
      (byKey[key] ??= []).add(FilterOption(id: value, label: label));
    }
    if (groupBy == null) {
      return [
        FilterGroup(
          id: filter.id,
          name: filter.name,
          options: (byKey[''] ?? [])
            ..sort((a, b) => a.label.compareTo(b.label)),
          supportsExclusion: filter.excludeParam.isNotEmpty,
        ),
      ];
    }
    final order = [
      ...groupBy.order,
      ...byKey.keys.where((k) => !groupBy.order.contains(k)),
    ];
    return [
      for (final key in order)
        if (byKey[key] case final options?)
          FilterGroup(
            id: '${filter.id}:$key',
            name: groupBy.names[key] ?? key,
            options: options..sort((a, b) => a.label.compareTo(b.label)),
            supportsExclusion: filter.excludeParam.isNotEmpty,
          ),
    ];
  }

  /// Appends `param=value(s)` query parameters onto [url]. An entry whose
  /// `param` or `values` is empty contributes nothing. Shared by
  /// [_applyFilterParams] (each group's owning [FilterConfig]) and
  /// [_applyTagParams] ([ApiListingConfig.tagParam]/[tagExcludeParam]).
  String _appendParams(
    String url,
    Iterable<({String param, String join, Set<String> values})> entries,
  ) {
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

  /// Appends the selected filters as query parameters, each group routed
  /// to its owning config's param/excludeParam.
  Future<String> _applyFilterParams(String url, FilterSelection filters) async {
    if (_groupOwner.isEmpty) {
      // A selection always originates from fetchFilters having run, but a
      // fresh source instance may not have it cached yet.
      try {
        await fetchFilters();
      } catch (_) {
        return url;
      }
    }
    return _appendParams(url, [
      for (final entry in _groupOwner.entries) ...[
        (
          param: entry.value.param,
          join: entry.value.join,
          values: filters.included(entry.key),
        ),
        (
          param: entry.value.excludeParam,
          join: entry.value.join,
          values: filters.excluded(entry.key),
        ),
      ],
    ]);
  }

  /// Appends included/excluded tags to a built `tag` listing URL, per
  /// [ApiListingConfig.tagParam]/[tagExcludeParam], a no-op (both empty)
  /// for a source that only browses one tag at a time via `{query}`.
  String _applyTagParams(
    ApiListingConfig tag,
    String url,
    Set<String> included,
    Set<String> excluded,
  ) => _appendParams(url, [
    (param: tag.tagParam, join: tag.tagJoin, values: included),
    (param: tag.tagExcludeParam, join: tag.tagJoin, values: excluded),
  ]);
}

/// Builds a JSON-API [Source] from a declarative [ApiSourceConfig], the
/// composition entry point that replaces `class ApiSource extends Source`.
/// Behaviour lives in the [_ApiEngine] closures; the returned value is the one
/// concrete `Source`. Refs in / fresh models out; page refs carry the API's
/// image headers.
Source apiSource(ApiSourceConfig config, {http.Client? client}) {
  final engine = _ApiEngine(config, client: client);
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
    imageHeaders: engine.imageHeadersFor,
    throttle: engine.throttle,
    imageThrottle: engine.imageThrottle,
    clearanceSink: (store) => engine.clearanceStore = store,
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
