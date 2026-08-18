import 'json_path.dart';
import 'pipeline.dart';

/// Extension metadata, modeled on the index format used by Mihon extension
/// repositories such as keiyoushi/extensions (`index.min.json`).
///
/// Unlike Mihon, whose extensions are Android APKs with compiled Kotlin
/// sources, these extensions are *declarative*: each source entry embeds
/// either a [SourceConfig] (HTML scraping via CSS selectors, the default)
/// or an [ApiSourceConfig] (`"type": "api"`, JSON endpoints via JSON
/// paths), interpreted at runtime by `ConfigSource`/`ApiSource`.
class ExtensionInfo {
  ExtensionInfo({
    required this.name,
    required this.pkg,
    required this.version,
    this.lang = 'all',
    this.nsfw = false,
    required this.sources,
    this.updatedAt = '',
  });

  factory ExtensionInfo.fromJson(Map<String, dynamic> json) => ExtensionInfo(
    name: json['name'] as String,
    pkg: json['pkg'] as String,
    version: json['version'] as String? ?? '1.0.0',
    lang: json['lang'] as String? ?? 'all',
    nsfw: switch (json['nsfw']) {
      final bool b => b,
      final num n => n != 0,
      _ => false,
    },
    sources: (json['sources'] as List<dynamic>? ?? [])
        .map((s) => AnySourceConfig.fromJson(s as Map<String, dynamic>))
        .toList(),
    updatedAt: json['updatedAt'] as String? ?? '',
  );

  final String name;

  /// Unique package-style identifier, e.g. `app.konimanga.extension.en.example`.
  final String pkg;

  /// An opaque content identifier: a truncated SHA-256 of the curated
  /// extension file's raw bytes, stamped in by `tool/build_repo.dart` at
  /// build time, not hand-authored. Despite the name, it's not semver and
  /// carries no ordering: the update check (`ExtensionsProvider.hasUpdate`)
  /// is a plain inequality, "does this differ from what's installed", never
  /// "is this greater than". Deliberately hashes raw file bytes rather than
  /// this class's own `toJson()` output, so a future engine serialization
  /// change never mass-invalidates every extension's version with no real
  /// content change behind it.
  final String version;
  final String lang;
  final bool nsfw;
  final List<AnySourceConfig> sources;

  /// The curated file's last-changed date (`YYYY-MM-DD`, from `git log`),
  /// stamped in alongside [version], a human-readable companion to it, not
  /// a second source of truth. A history rewrite (force-push, squash) can
  /// make this report the rewrite date instead of the real edit date, so
  /// [version] is what actually answers "is this different"; this is
  /// best-effort decoration for "updated {date}" UI copy. '' when unknown
  /// (an entry built before this field existed, or with no git history).
  final String updatedAt;

  Map<String, dynamic> toJson() => {
    'name': name,
    'pkg': pkg,
    'version': version,
    'lang': lang,
    'nsfw': nsfw ? 1 : 0,
    'sources': sources.map((s) => s.toJson()).toList(),
    if (updatedAt.isNotEmpty) 'updatedAt': updatedAt,
  };
}

/// A source description of either dialect, discriminated by `type`:
/// absent/anything else → HTML scraping ([SourceConfig]), `"api"` → JSON
/// API ([ApiSourceConfig]).
sealed class AnySourceConfig {
  String get id;
  String get name;
  String get lang;
  String get baseUrl;

  /// Optional site icon as a `data:image/png;base64,…` URI (inlined by
  /// `tool/build_repo.dart` from `extensions/icons/`), or an `http(s)` URL; ''
  /// when none. Shown in the app's source/extension lists.
  String get icon;
  Map<String, dynamic> toJson();

  static AnySourceConfig fromJson(Map<String, dynamic> json) =>
      json['type'] == 'api'
      ? ApiSourceConfig.fromJson(json)
      : SourceConfig.fromJson(json);
}

/// Parses an operation's optional explicit `steps:` pipeline (the escape hatch
/// that overrides a config block's desugared extraction). Validated at load so
/// a malformed pipeline fails on parse, not at fetch time.
Pipeline? _stepsFromJson(Object? json) =>
    json == null ? null : Pipeline.fromJson(json as List<dynamic>);

/// Declarative description of an HTML-scraping source.
class SourceConfig implements AnySourceConfig {
  SourceConfig({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
    this.icon = '',
    this.webview = false,
    this.warmImageByUrl = false,
    this.warmImageViaImgTag = false,
    this.loginUrl = '',
    this.localStorageSeed = const {},
    this.localStoragePreferences = const [],
    this.js = false,
    this.headers = const {},
    this.rateLimit,
    this.imageRateLimit,
    required this.popular,
    this.latest,
    this.search,
    this.tag,
    this.details = const DetailsConfig(),
    required this.chapters,
    required this.pages,
    this.filters = const [],
  });

  factory SourceConfig.fromJson(Map<String, dynamic> json) => SourceConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    lang: json['lang'] as String? ?? 'all',
    baseUrl: json['baseUrl'] as String,
    icon: json['icon'] as String? ?? '',
    webview: json['webview'] as bool? ?? false,
    warmImageByUrl: json['warmImageByUrl'] as bool? ?? false,
    warmImageViaImgTag: json['warmImageViaImgTag'] as bool? ?? false,
    loginUrl: json['loginUrl'] as String? ?? '',
    localStorageSeed: json['localStorageSeed'] as Map<String, dynamic>? ?? const {},
    localStoragePreferences:
        (json['localStoragePreferences'] as List<dynamic>? ?? [])
            .map(
              (p) => LocalStoragePreferenceConfig.fromJson(
                p as Map<String, dynamic>,
              ),
            )
            .toList(),
    js: json['js'] as bool? ?? false,
    headers: (json['headers'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
    imageRateLimit: json['imageRateLimit'] == null
        ? null
        : RateLimitConfig.fromJson(
            json['imageRateLimit'] as Map<String, dynamic>,
          ),
    rateLimit: json['rateLimit'] == null
        ? null
        : RateLimitConfig.fromJson(json['rateLimit'] as Map<String, dynamic>),
    popular: ListingConfig.fromJson(json['popular'] as Map<String, dynamic>),
    latest: json['latest'] == null
        ? null
        : ListingConfig.fromJson(json['latest'] as Map<String, dynamic>),
    search: json['search'] == null
        ? null
        : ListingConfig.fromJson(json['search'] as Map<String, dynamic>),
    tag: json['tag'] == null
        ? null
        : ListingConfig.fromJson(json['tag'] as Map<String, dynamic>),
    details: json['details'] == null
        ? const DetailsConfig()
        : DetailsConfig.fromJson(json['details'] as Map<String, dynamic>),
    chapters: ChaptersConfig.fromJson(json['chapters'] as Map<String, dynamic>),
    pages: PagesConfig.fromJson(json['pages'] as Map<String, dynamic>),
    filters: (json['filters'] as List<dynamic>? ?? [])
        .map((f) => FilterConfig.fromJson(f as Map<String, dynamic>))
        .toList(),
  );

  @override
  final String id;
  @override
  final String name;
  @override
  final String lang;
  @override
  final String baseUrl;
  @override
  final String icon;

  /// Route this source's page GETs through the app's WebView (real browser
  /// fingerprint + Cloudflare clearance) instead of the HTTP client, for hosts
  /// whose Cloudflare mode re-challenges cookie-replay from a non-browser client.
  final bool webview;

  /// For a `webview` source: when warming a cover/page image's origin before
  /// fetching its bytes, navigate to the image's own URL instead of its bare
  /// origin. Default (false, bare origin) is what most sites need; some
  /// only run their challenge-solving JS on a real document there. A handful
  /// of CDN-only hosts (no real page at `/`) do the opposite: they WAF-block
  /// a bare root-path request outright while serving the actual asset path
  /// with no challenge at all, and need this set to true. See
  /// `WebViewFetcher.fetchBytes`'s `warmByUrl` param.
  final bool warmImageByUrl;

  /// For a `webview` source: fetch cover/page image bytes by navigating to
  /// (or reusing, if already parked there) a page at this source's own
  /// `baseUrl`, then injecting a same-page `<img crossorigin="anonymous">`
  /// for the image URL and reading it back via a canvas, instead of
  /// [warmImageByUrl]'s direct navigation to the image's own URL/origin.
  /// Two failure modes this recovers from that [warmImageByUrl] can't: (1)
  /// a WAF that checks the *site's* Referer specifically, not the image
  /// host's own origin (an `<img>` tag on a page at `baseUrl` sends exactly
  /// that Referer automatically; a top-level navigation to the image's own
  /// origin never can); (2) a CDN that mislabels real image bytes with a
  /// non-image `Content-Type` (e.g. `application/octet-stream`); a direct
  /// navigation there never renders as `document.images[0]` for
  /// [warmImageByUrl] to canvas-extract, while an `<img>` tag decodes by
  /// sniffing the bytes regardless of the declared type. Needs the CDN to
  /// send `Access-Control-Allow-Origin` permitting the canvas read; most
  /// do, but not all (confirmed live against a real source: its covers
  /// reject every `crossorigin="anonymous"` request outright). Tried first
  /// when both flags are set; on a failed extraction it falls back to
  /// [warmImageByUrl]'s full-page-navigation approach instead, which has no
  /// CORS check at all; the two are complementary fallbacks for different
  /// hosts of the *same* source, not mutually exclusive alternatives. See
  /// `WebViewFetcher.fetchBytes`'s `viaImgTag` param.
  final bool warmImageViaImgTag;

  /// Absolute URL of this source's own login page. Gates whether the app
  /// offers a "log in" action for it at all; empty means the source has no
  /// login concept. Purely a UI trigger for the app's WebView-based login
  /// capture (`openLoginSession` in `package:koni_dojo_webview`): the engine
  /// itself never fetches this URL or knows what "logged in" means for a
  /// given source; a captured session lives entirely in the platform's
  /// WebView cookie jar (persisted by the app the same way a Cloudflare
  /// clearance is, so it survives relaunches and an unrelated
  /// `deleteAllCookies()` elsewhere). Meaningful only alongside `webview:
  /// true`. A login session only reaches non-WebView requests if the app
  /// also replays it as headers, which nothing here does automatically.
  final String loginUrl;

  /// For a `webview` source: `key -> JSON value` entries to seed into the
  /// WebView's `localStorage` for this source's origin, once per process,
  /// before the first real fetch there. For a purely client-side gate that
  /// blocks real content but isn't session state: an age/content-warning
  /// interstitial that sets a preference flag client-side rather than
  /// through the account or a cookie (confirmed live against a real source:
  /// its reader checks a boolean nested in a `localStorage`-persisted
  /// preferences blob, unrelated to being logged in). Applying this needs a
  /// document already loaded on the target origin; the WebView navigates
  /// there once, runs `localStorage.setItem` for each entry (value
  /// re-serialized with `jsonEncode`, matching what the site's own
  /// `JSON.stringify` would store), then the real navigation proceeds.
  /// Distinct from `loginUrl`: this is a fixed, declared preference the
  /// config author supplies, not a captured per-account secret, so it lives
  /// in the config instead of a `ClearanceStore`/login-session seam.
  final Map<String, dynamic> localStorageSeed;

  /// User-facing consent toggles that patch [localStorageSeed] at fetch
  /// time: for a preference [localStorageSeed] shouldn't just force one way
  /// for everyone (e.g. an "accept gore content" toggle, which
  /// [localStorageSeed] leaves at the site's own safe default rather than
  /// baking in). Each entry writes one boolean into the seed structure
  /// (see [LocalStoragePreferenceConfig.seedKey]/[LocalStoragePreferenceConfig.path]);
  /// the app resolves the value via a `LocalStoragePreferenceStore`
  /// (keyed by this source's id), falling back to
  /// [LocalStoragePreferenceConfig.defaultValue] when nothing's stored.
  /// Empty means this source has no such toggles.
  final List<LocalStoragePreferenceConfig> localStoragePreferences;

  /// Opt-in to running `js` pipeline steps (sandboxed QuickJS), a capability
  /// gate for the small set of sources that mint a token by executing the
  /// site's own JavaScript. A config with a `js` step must set this; the build
  /// (`tool/build_repo.dart`) enforces it, keeping remote-code execution to
  /// curated, reviewed configs.
  final bool js;
  final Map<String, String> headers;

  /// Polite request budget for this site; null means unthrottled.
  final RateLimitConfig? rateLimit;

  /// Extra spacing for **image** fetches, for the rare CDN that wants a rate
  /// rather than the concurrency cap images get by default. Null (the normal
  /// case) leaves image fetches capped but unspaced — see [RateLimitConfig].
  final RateLimitConfig? imageRateLimit;
  final ListingConfig popular;

  /// "Latest updates" listing. Carried in the format for forward
  /// compatibility; the engine does not expose it yet.
  final ListingConfig? latest;
  final ListingConfig? search;

  /// Exact-match browse for one or more already-known tag values (e.g. a
  /// value out of a manga's own `details.genres`, extraction and browsing
  /// are named differently on purpose; see [ListingConfig.tagParam]'s doc),
  /// distinct from [search]: no free-text relevance ranking, no
  /// [FilterConfig.optionsFrom]-style enumerable vocabulary either. For a
  /// site whose tags are too many to list up front (confirmed live: one real
  /// source has one tag per model/publisher ever uploaded, not a small
  /// curated taxonomy), this is how "browse everything tagged X" reaches its
  /// own precise listing endpoint instead of routing through a fuzzy keyword
  /// search. Null means the source offers no such listing.
  final ListingConfig? tag;
  final DetailsConfig details;
  final ChaptersConfig chapters;
  final PagesConfig pages;

  /// Search filters; selections become query parameters on the [search]
  /// listing's URL. Empty means the source offers no filtering.
  final List<FilterConfig> filters;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lang': lang,
    'baseUrl': baseUrl,
    if (js) 'js': js,
    if (icon.isNotEmpty) 'icon': icon,
    if (webview) 'webview': true,
    if (warmImageByUrl) 'warmImageByUrl': true,
    if (warmImageViaImgTag) 'warmImageViaImgTag': true,
    if (loginUrl.isNotEmpty) 'loginUrl': loginUrl,
    if (localStorageSeed.isNotEmpty) 'localStorageSeed': localStorageSeed,
    if (localStoragePreferences.isNotEmpty)
      'localStoragePreferences': localStoragePreferences
          .map((p) => p.toJson())
          .toList(),
    if (headers.isNotEmpty) 'headers': headers,
    if (rateLimit != null) 'rateLimit': rateLimit!.toJson(),
    if (imageRateLimit != null) 'imageRateLimit': imageRateLimit!.toJson(),
    'popular': popular.toJson(),
    if (latest != null) 'latest': latest!.toJson(),
    if (search != null) 'search': search!.toJson(),
    if (tag != null) 'tag': tag!.toJson(),
    'details': details.toJson(),
    'chapters': chapters.toJson(),
    'pages': pages.toJson(),
    if (filters.isNotEmpty) 'filters': filters.map((f) => f.toJson()).toList(),
  };
}

/// One user-facing toggle a `webview` source exposes, patching a single
/// boolean into `SourceConfig.localStorageSeed` at fetch time. Deliberately
/// bool-only, one location per entry; this isn't a general JSON-patch DSL,
/// just enough to expose "accept gore content"-shaped preferences the config
/// author doesn't want to force one way for everyone.
///
/// ```json
/// {
///   "id": "acceptGore", "label": "Show gore / graphic violence",
///   "seedKey": "filterPreferences", "path": ["matureContent", "acceptGore"],
///   "default": false
/// }
/// ```
class LocalStoragePreferenceConfig {
  const LocalStoragePreferenceConfig({
    required this.id,
    required this.label,
    required this.seedKey,
    required this.path,
    this.defaultValue = false,
  });

  factory LocalStoragePreferenceConfig.fromJson(Map<String, dynamic> json) =>
      LocalStoragePreferenceConfig(
        id: json['id'] as String,
        label: json['label'] as String,
        seedKey: json['seedKey'] as String,
        path: (json['path'] as List).cast<String>(),
        defaultValue: json['default'] as bool? ?? false,
      );

  /// Stable identifier: the key a `LocalStoragePreferenceStore` stores this
  /// toggle's override under. Not shown to the user.
  final String id;

  /// User-facing label for this toggle's control.
  final String label;

  /// Top-level key within `localStorageSeed` this toggle writes into (e.g.
  /// `"filterPreferences"`, matches a `localStorageSeed` entry's key, which
  /// must already exist there since this only overwrites one boolean inside
  /// it, never creates the surrounding structure from scratch).
  final String seedKey;

  /// Path of nested keys under [seedKey] to the boolean this toggle writes
  /// (e.g. `["matureContent", "acceptGore"]`).
  final List<String> path;

  /// Value used when nothing's stored in the app's
  /// `LocalStoragePreferenceStore` for this toggle's [id] yet.
  final bool defaultValue;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'seedKey': seedKey,
    'path': path,
    if (defaultValue) 'default': true,
  };
}

/// A declarative search filter group: the user's selected options are
/// appended to the search listing's URL as query parameters.
///
/// ```json
/// {
///   "id": "genres", "name": "Genres",
///   "param": "genre[]",
///   "excludeParam": "genre_exclude[]",      // optional: enables exclusion
///   "join": "",                             // "" repeats the parameter;
///                                           // e.g. "," joins values into one
///   "options": [{"value": "horror", "label": "Horror"}, ...]
/// }
/// ```
class FilterConfig {
  const FilterConfig({
    required this.id,
    required this.name,
    required this.param,
    this.excludeParam = '',
    this.join = '',
    this.options = const [],
    this.optionsFrom,
  });

  factory FilterConfig.fromJson(Map<String, dynamic> json) => FilterConfig(
    id: json['id'] as String,
    name: json['name'] as String? ?? json['id'] as String,
    param: json['param'] as String,
    excludeParam: json['excludeParam'] as String? ?? '',
    join: json['join'] as String? ?? '',
    options: [
      for (final option in json['options'] as List<dynamic>? ?? [])
        FilterOptionConfig.fromJson(option as Map<String, dynamic>),
    ],
    optionsFrom: json['optionsFrom'] == null
        ? null
        : OptionsFromConfig.fromJson(
            json['optionsFrom'] as Map<String, dynamic>,
          ),
  );

  final String id;
  final String name;

  /// Query parameter carrying included options.
  final String param;

  /// Query parameter carrying excluded options; '' disables exclusion for
  /// this group.
  final String excludeParam;

  /// How multiple values serialize: '' repeats the parameter
  /// (`?g=a&g=b`), any other string joins them into one value (`?g=a,b`).
  final String join;
  final List<FilterOptionConfig> options;

  /// Discovers the option list from the source at runtime, the same way the
  /// reference API-dialect config does; the static [options] then serve as
  /// a fallback when the fetch fails.
  final OptionsFromConfig? optionsFrom;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'param': param,
    if (excludeParam.isNotEmpty) 'excludeParam': excludeParam,
    if (join.isNotEmpty) 'join': join,
    if (options.isNotEmpty) 'options': options.map((o) => o.toJson()).toList(),
    if (optionsFrom != null) 'optionsFrom': optionsFrom!.toJson(),
  };
}

/// Runtime discovery of a filter group's options. [path] is fetched from
/// the source; extraction uses the fields matching the source dialect:
/// JSON paths ([items]/[value]/[label]) for API sources, CSS selectors
/// ([itemSelector]/[valueAttr]/[labelSelector]) for HTML sources.
class OptionsFromConfig {
  const OptionsFromConfig({
    required this.path,
    this.items = 'data',
    this.value = const JsonValueSpec(),
    this.label = const JsonValueSpec(),
    this.groupBy,
    this.itemSelector = '',
    this.valueAttr = 'value',
    this.labelSelector = '',
    this.labelAttr = '',
  });

  factory OptionsFromConfig.fromJson(Map<String, dynamic> json) =>
      OptionsFromConfig(
        path: json['path'] as String,
        items: json['items'] as String? ?? 'data',
        value: JsonValueSpec.fromJson(json['value']),
        label: JsonValueSpec.fromJson(json['label']),
        groupBy: json['groupBy'] == null
            ? null
            : GroupByConfig.fromJson(json['groupBy'] as Map<String, dynamic>),
        itemSelector: json['itemSelector'] as String? ?? '',
        valueAttr: json['valueAttr'] as String? ?? 'value',
        labelSelector: json['labelSelector'] as String? ?? '',
        labelAttr: json['labelAttr'] as String? ?? '',
      );

  final String path;

  // JSON dialect.
  final String items;
  final JsonValueSpec value;
  final JsonValueSpec label;

  /// Splits the discovered options into one filter group per distinct
  /// value at its path (e.g. a taxonomy split into genre/theme/format/
  /// content groups).
  final GroupByConfig? groupBy;

  // HTML dialect.
  final String itemSelector;
  final String valueAttr;
  final String labelSelector;
  final String labelAttr;

  Map<String, dynamic> toJson() => {
    'path': path,
    if (itemSelector.isEmpty) 'items': items,
    if (!value.isEmpty) 'value': value.toJson(),
    if (!label.isEmpty) 'label': label.toJson(),
    if (groupBy != null) 'groupBy': groupBy!.toJson(),
    if (itemSelector.isNotEmpty) 'itemSelector': itemSelector,
    if (itemSelector.isNotEmpty) 'valueAttr': valueAttr,
    if (labelSelector.isNotEmpty) 'labelSelector': labelSelector,
    if (labelAttr.isNotEmpty) 'labelAttr': labelAttr,
  };
}

/// How discovered options split into groups: the value at [path] keys the
/// group; [names] maps keys to display names (unmapped keys show as-is)
/// and [order] pins the group order (unlisted keys follow, as found).
class GroupByConfig {
  const GroupByConfig({
    required this.path,
    this.names = const {},
    this.order = const [],
  });

  factory GroupByConfig.fromJson(Map<String, dynamic> json) => GroupByConfig(
    path: json['path'] as String,
    names: (json['names'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
    order: (json['order'] as List<dynamic>? ?? []).cast<String>(),
  );

  final String path;
  final Map<String, String> names;
  final List<String> order;

  Map<String, dynamic> toJson() => {
    'path': path,
    if (names.isNotEmpty) 'names': names,
    if (order.isNotEmpty) 'order': order,
  };
}

/// One choice of a [FilterConfig]: [value] is sent to the site, [label]
/// shown to the user.
class FilterOptionConfig {
  const FilterOptionConfig({required this.value, required this.label});

  factory FilterOptionConfig.fromJson(Map<String, dynamic> json) =>
      FilterOptionConfig(
        value: json['value'] as String,
        label: json['label'] as String? ?? json['value'] as String,
      );

  final String value;
  final String label;

  Map<String, dynamic> toJson() => {'value': value, 'label': label};
}

/// At most [requests] HTTP requests to the **site** per [perMs] milliseconds,
/// enforced across listings, search, details, chapters and page lists.
///
/// Deliberately not applied to image fetches. A source's pages and covers
/// routinely come from a CDN that never made this promise, and spacing those
/// requests out is what pins a phone's radio for a whole reading session;
/// images take a concurrency cap instead (`ConcurrencyGate`). A host whose
/// image CDN really does want a rate declares `imageRateLimit` separately.
class RateLimitConfig {
  const RateLimitConfig({this.requests = 1, this.perMs = 1000});

  factory RateLimitConfig.fromJson(Map<String, dynamic> json) =>
      RateLimitConfig(
        requests: json['requests'] as int? ?? 1,
        perMs: json['perMs'] as int? ?? 1000,
      );

  final int requests;
  final int perMs;

  Map<String, dynamic> toJson() => {'requests': requests, 'perMs': perMs};
}

/// A find/replace rewrite of a scraped string: [find] replaces literally,
/// [pattern] is a regular expression whose replacement may reference groups
/// as `$1`..`$9`. [find] wins when both are given.
class ValueRewrite {
  const ValueRewrite({this.find = '', this.pattern = '', this.replace = ''});

  factory ValueRewrite.fromJson(Map<String, dynamic> json) => ValueRewrite(
    find: json['find'] as String? ?? '',
    pattern: json['pattern'] as String? ?? '',
    replace: json['replace'] as String? ?? '',
  );

  final String find;
  final String pattern;
  final String replace;

  String apply(String input) {
    if (find.isNotEmpty) return input.replaceAll(find, replace);
    if (pattern.isEmpty) return input;
    return input.replaceAllMapped(
      RegExp(pattern),
      (m) => expandGroupRefs(m, replace),
    );
  }

  Map<String, dynamic> toJson() => {
    if (find.isNotEmpty) 'find': find,
    if (pattern.isNotEmpty) 'pattern': pattern,
    'replace': replace,
  };
}

/// Expands `$1`..`$9` group references in [replacement] against [match].
String expandGroupRefs(Match match, String replacement) =>
    replacement.replaceAllMapped(
      RegExp(r'\$(\d)'),
      (r) => match.group(int.parse(r[1]!)) ?? '',
    );

/// Derives the URL actually fetched (chapter list, page list) from the
/// stored one: an optional regex rewrite, then an optional literal suffix.
/// A [pattern] that does not match leaves the URL unchanged.
///
/// [method] (default `GET`) issues the request; `POST` sends [body] (a
/// form-encoded template whose `$1`..`$9` reference [pattern]'s groups on the
/// pre-transform URL) with optional [headers], the shape Madara needs for
/// `ajax/chapters/` and `admin-ajax.php`.
class RequestTransform {
  const RequestTransform({
    this.pattern = '',
    this.replace = '',
    this.suffix = '',
    this.url = '',
    this.method = 'GET',
    this.body = '',
    this.headers = const {},
    this.idSelector = '',
    this.idAttr = '',
  });

  factory RequestTransform.fromJson(Map<String, dynamic> json) =>
      RequestTransform(
        pattern: json['pattern'] as String? ?? '',
        replace: json['replace'] as String? ?? '',
        suffix: json['suffix'] as String? ?? '',
        url: json['url'] as String? ?? '',
        method: (json['method'] as String? ?? 'GET').toUpperCase(),
        body: json['body'] as String? ?? '',
        headers: (json['headers'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(k, v as String),
        ),
        idSelector: json['idSelector'] as String? ?? '',
        idAttr: json['idAttr'] as String? ?? '',
      );

  final String pattern;
  final String replace;
  final String suffix;

  /// Explicit request target, used instead of the [apply]-derived URL, for
  /// requests that go to a fixed endpoint rather than a rewrite of the source
  /// URL (e.g. Madara's `manga_get_chapters` to `admin-ajax.php`). Resolved
  /// against `baseUrl`; `{id}` is substituted (see [idSelector]).
  final String url;
  final String method;
  final String body;
  final Map<String, String> headers;

  /// Two-phase fetch: when set, the source page is fetched first and the value
  /// at this selector/[idAttr] is captured as `{id}` for [url] and [body],
  /// the post id Madara's legacy chapter endpoint needs. Empty disables it.
  final String idSelector;
  final String idAttr;

  bool get isPost => method == 'POST';
  bool get hasIdLookup => idSelector.isNotEmpty || idAttr.isNotEmpty;

  String apply(String url) {
    var result = url;
    if (pattern.isNotEmpty) {
      result = result.replaceFirstMapped(
        RegExp(pattern),
        (m) => expandGroupRefs(m, replace),
      );
    }
    return '$result$suffix';
  }

  /// The POST body for [url]: `$1`..`$9` in [body] expand from [pattern]'s
  /// match on the (pre-transform) URL, so a body can carry an id pulled from
  /// the manga/chapter URL.
  String bodyFor(String url) {
    if (body.isEmpty || pattern.isEmpty) return body;
    final match = RegExp(pattern).firstMatch(url);
    return match == null ? body : expandGroupRefs(match, body);
  }

  Map<String, dynamic> toJson() => {
    if (pattern.isNotEmpty) 'pattern': pattern,
    if (pattern.isNotEmpty) 'replace': replace,
    if (suffix.isNotEmpty) 'suffix': suffix,
    if (url.isNotEmpty) 'url': url,
    if (method != 'GET') 'method': method,
    if (body.isNotEmpty) 'body': body,
    if (headers.isNotEmpty) 'headers': headers,
    if (idSelector.isNotEmpty) 'idSelector': idSelector,
    if (idAttr.isNotEmpty) 'idAttr': idAttr,
  };
}

/// One step of a cover-extraction chain; the first step yielding a
/// non-empty value (after [rewrite]) wins.
class CoverSource {
  const CoverSource({required this.selector, this.attr = 'src', this.rewrite});

  factory CoverSource.fromJson(Map<String, dynamic> json) => CoverSource(
    selector: json['selector'] as String? ?? '',
    attr: json['attr'] as String? ?? 'src',
    rewrite: json['replace'] == null
        ? null
        : ValueRewrite.fromJson(json['replace'] as Map<String, dynamic>),
  );

  final String selector;
  final String attr;
  final ValueRewrite? rewrite;

  Map<String, dynamic> toJson() => {
    'selector': selector,
    'attr': attr,
    if (rewrite != null) 'replace': rewrite!.toJson(),
  };

  static List<CoverSource>? listFromJson(dynamic json) => json == null
      ? null
      : [
          for (final step in json as List<dynamic>)
            CoverSource.fromJson(step as Map<String, dynamic>),
        ];
}

/// Declarative extraction of `<li><strong>Label:</strong> value</li>`-style
/// metadata rows, the common shape Jsoup sources target with
/// `:has(:contains())` selectors, which package:html cannot evaluate.
class RowsConfig {
  const RowsConfig({
    required this.itemSelector,
    this.labelSelector = 'strong',
    this.fields = const {},
  });

  factory RowsConfig.fromJson(Map<String, dynamic> json) => RowsConfig(
    itemSelector: json['itemSelector'] as String,
    labelSelector: json['labelSelector'] as String? ?? 'strong',
    fields: (json['fields'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, RowField.fromJson(v as Map<String, dynamic>)),
    ),
  );

  final String itemSelector;
  final String labelSelector;

  /// Keyed by the manga field to fill: `author`, `status`, `genres` or
  /// `description`. `genres` collects a list; the others join their
  /// matches with the field's `join` string.
  final Map<String, RowField> fields;

  Map<String, dynamic> toJson() => {
    'itemSelector': itemSelector,
    'labelSelector': labelSelector,
    'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
  };
}

/// Where one metadata field lives: rows whose label contains any of
/// [labels] (case-insensitive) contribute every [valueSelector] match.
class RowField {
  const RowField({
    required this.labels,
    this.valueSelector = '',
    this.join = ', ',
  });

  factory RowField.fromJson(Map<String, dynamic> json) => RowField(
    labels: switch (json['label']) {
      final String s => [s],
      final List<dynamic> l => l.cast<String>(),
      _ => const [],
    },
    valueSelector: json['valueSelector'] as String? ?? '',
    join: json['join'] as String? ?? ', ',
  );

  final List<String> labels;
  final String valueSelector;
  final String join;

  Map<String, dynamic> toJson() => {
    'label': labels.length == 1 ? labels.single : labels,
    'valueSelector': valueSelector,
    'join': join,
  };
}

/// A paginated catalog listing (popular, latest or search results).
///
/// [path] is appended to the base URL after replacing `{page}`, `{offset}`
/// (= `(page - 1) * pageSize`) and `{query}` placeholders.
class ListingConfig {
  const ListingConfig({
    this.path = '',
    this.pageSize = 0,
    this.queryReplace,
    this.queryMap = const {},
    this.method = 'GET',
    this.body = '',
    this.headers = const {},
    this.itemSelector = '',
    this.titleSelector = 'a',
    this.titleAttr = '',
    this.urlSelector = 'a',
    this.urlAttr = 'href',
    this.coverSelector = 'img',
    this.coverAttr = 'src',
    this.cover,
    this.nextPageSelector = '',
    this.tagParam = '',
    this.tagExcludeParam = '',
    this.tagJoin = '',
    this.steps,
  });

  factory ListingConfig.fromJson(Map<String, dynamic> json) => ListingConfig(
    path: json['path'] as String? ?? '',
    pageSize: json['pageSize'] as int? ?? 0,
    queryReplace: json['queryReplace'] == null
        ? null
        : ValueRewrite.fromJson(json['queryReplace'] as Map<String, dynamic>),
    queryMap: (json['queryMap'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
    method: (json['method'] as String? ?? 'GET').toUpperCase(),
    body: json['body'] as String? ?? '',
    headers: (json['headers'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
    itemSelector: json['itemSelector'] as String? ?? '',
    titleSelector: json['titleSelector'] as String? ?? 'a',
    titleAttr: json['titleAttr'] as String? ?? '',
    urlSelector: json['urlSelector'] as String? ?? 'a',
    urlAttr: json['urlAttr'] as String? ?? 'href',
    coverSelector: json['coverSelector'] as String? ?? 'img',
    coverAttr: json['coverAttr'] as String? ?? 'src',
    cover: CoverSource.listFromJson(json['cover']),
    nextPageSelector: json['nextPageSelector'] as String? ?? '',
    tagParam: json['tagParam'] as String? ?? '',
    tagExcludeParam: json['tagExcludeParam'] as String? ?? '',
    tagJoin: json['tagJoin'] as String? ?? '',
    steps: _stepsFromJson(json['steps']),
  );

  /// Empty only when [steps] supplies the extraction instead of the sugar.
  final String path;

  /// Items per page, used only to compute the `{offset}` placeholder.
  final int pageSize;

  /// Sanitization applied to the raw query before `{query}` substitution.
  final ValueRewrite? queryReplace;

  /// Exact-match (case-insensitive) rewrite of the raw query, checked before
  /// [queryReplace], for a fixed vocabulary whose site-side browse value
  /// doesn't derive from its display text by any rule (e.g. a genre tag like
  /// "Sci-fi" that browses under an unrelated slug like "sf"). Same
  /// precedent/shape as [DetailsConfig.statusMap]: a query that isn't a key
  /// here just falls through to [queryReplace]/[path] unchanged.
  final Map<String, String> queryMap;

  /// HTTP method for the listing; `POST` sends [body] (with the same
  /// `{page}`/`{offset}`/`{query}` substitution as [path]) and [headers],
  /// for AJAX load-more endpoints that only answer POST.
  final String method;
  final String body;
  final Map<String, String> headers;
  final String itemSelector;
  final String titleSelector;
  final String titleAttr;
  final String urlSelector;
  final String urlAttr;
  final String coverSelector;
  final String coverAttr;

  /// Multi-step cover extraction; when given it overrides
  /// [coverSelector]/[coverAttr].
  final List<CoverSource>? cover;
  final String nextPageSelector;

  /// Meaningful only on [SourceConfig.tag]: the query parameter carrying
  /// *every* [TagQuery.included] value (not just the extras beyond the
  /// first; a source using this doesn't also rely on `{query}` in [path]
  /// for the primary tag). Empty means the source can only browse one tag
  /// at a time, via `{query}` in [path]/[body]; [TagCapabilities.multiple]
  /// is derived from whether this is set, not hand-declared.
  final String tagParam;

  /// Meaningful only on [SourceConfig.tag]: the query parameter carrying
  /// [TagQuery.excluded]. Empty means the source can't exclude a tag;
  /// [TagCapabilities.exclusion] is derived from whether this is set.
  final String tagExcludeParam;

  /// How [tagParam]/[tagExcludeParam] serialize multiple values: empty
  /// repeats the parameter (`?tag=a&tag=b`), any other string joins them
  /// into one value (`?tag=a,b`), same convention as [FilterConfig.join].
  final String tagJoin;

  /// Explicit pipeline overriding the desugared listing extraction; sugar
  /// fields and the declarative `filters` are then not applied.
  final Pipeline? steps;

  List<CoverSource> get coverChain =>
      cover ?? [CoverSource(selector: coverSelector, attr: coverAttr)];

  Map<String, dynamic> toJson() => {
    'path': path,
    if (pageSize != 0) 'pageSize': pageSize,
    if (queryReplace != null) 'queryReplace': queryReplace!.toJson(),
    if (queryMap.isNotEmpty) 'queryMap': queryMap,
    if (method != 'GET') 'method': method,
    if (body.isNotEmpty) 'body': body,
    if (headers.isNotEmpty) 'headers': headers,
    'itemSelector': itemSelector,
    'titleSelector': titleSelector,
    'titleAttr': titleAttr,
    'urlSelector': urlSelector,
    'urlAttr': urlAttr,
    'coverSelector': coverSelector,
    'coverAttr': coverAttr,
    if (cover != null) 'cover': [for (final step in cover!) step.toJson()],
    'nextPageSelector': nextPageSelector,
    if (tagParam.isNotEmpty) 'tagParam': tagParam,
    if (tagExcludeParam.isNotEmpty) 'tagExcludeParam': tagExcludeParam,
    if (tagJoin.isNotEmpty) 'tagJoin': tagJoin,
    if (steps != null) 'steps': steps!.toJson(),
  };
}

class DetailsConfig {
  const DetailsConfig({
    this.titleSelector = '',
    this.authorSelector = '',
    this.descriptionSelector = '',
    this.coverSelector = '',
    this.coverAttr = 'src',
    this.cover,
    this.bannerSelector = '',
    this.bannerAttr = 'src',
    this.banner,
    this.backgroundSelector = '',
    this.backgroundAttr = 'src',
    this.background,
    this.genreSelector = '',
    this.genreAttr = '',
    this.unlistedChaptersSelector = '',
    this.unlistedChaptersAttr = '',
    this.rows,
    this.statusMap = const {},
    this.steps,
  });

  factory DetailsConfig.fromJson(Map<String, dynamic> json) => DetailsConfig(
    titleSelector: json['titleSelector'] as String? ?? '',
    authorSelector: json['authorSelector'] as String? ?? '',
    descriptionSelector: json['descriptionSelector'] as String? ?? '',
    coverSelector: json['coverSelector'] as String? ?? '',
    coverAttr: json['coverAttr'] as String? ?? 'src',
    cover: CoverSource.listFromJson(json['cover']),
    bannerSelector: json['bannerSelector'] as String? ?? '',
    bannerAttr: json['bannerAttr'] as String? ?? 'src',
    banner: CoverSource.listFromJson(json['banner']),
    backgroundSelector: json['backgroundSelector'] as String? ?? '',
    backgroundAttr: json['backgroundAttr'] as String? ?? 'src',
    background: CoverSource.listFromJson(json['background']),
    genreSelector: json['genreSelector'] as String? ?? '',
    genreAttr: json['genreAttr'] as String? ?? '',
    unlistedChaptersSelector: json['unlistedChaptersSelector'] as String? ?? '',
    unlistedChaptersAttr: json['unlistedChaptersAttr'] as String? ?? '',
    rows: json['rows'] == null
        ? null
        : RowsConfig.fromJson(json['rows'] as Map<String, dynamic>),
    statusMap: (json['statusMap'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
    steps: _stepsFromJson(json['steps']),
  );

  final String titleSelector;
  final String authorSelector;
  final String descriptionSelector;
  final String coverSelector;
  final String coverAttr;

  /// Multi-step cover extraction; when given it overrides
  /// [coverSelector]/[coverAttr].
  final List<CoverSource>? cover;
  final String bannerSelector;
  final String bannerAttr;

  /// Multi-step banner extraction; when given it overrides
  /// [bannerSelector]/[bannerAttr]. A wide hero image distinct from [cover]
  /// (a poster-shaped thumbnail) and from [background] (see below); some
  /// sites layer both a character-art banner *and* a separate tiled backdrop
  /// (Webtoons: a square `og:image` poster as the cover, a wide character-art
  /// banner, and a `repeat-x` mood-color strip beneath it). Empty means the
  /// source has no such image; the app then has no hero banner for this
  /// manga, not an error.
  final List<CoverSource>? banner;
  final String backgroundSelector;
  final String backgroundAttr;

  /// Multi-step background extraction; when given it overrides
  /// [backgroundSelector]/[backgroundAttr]. Distinct from [banner]: a tiled
  /// backdrop meant to sit *beneath* it, often a near-solid per-series mood
  /// color rather than character art, a cleaner source for tint-color
  /// extraction than [banner] tends to be. CSS `background-image` URLs
  /// (Webtoons: `<div style="background:url('...') repeat-x">`) don't live in
  /// a plain `src`/`href` attribute; extract them with `attr: "style"` plus a
  /// `rewrite` pulling the URL out of the raw `url('...')` value; no
  /// dedicated engine support needed, the existing chain `rewrite` (regex
  /// `pattern`/`replace` with `$1` group refs) already does this. Empty means
  /// the source has no such image, not an error.
  final List<CoverSource>? background;

  /// Every element matching [genreSelector] contributes one genre (its text,
  /// or [genreAttr] when set); unlike [rows], no label is required, for
  /// sites that just render a flat list of tag/genre links with nothing
  /// marking what kind of row it is (confirmed live: one real source renders
  /// a bare `<a href="/tags/…">` pair, no "Tags:" prefix to key a row match
  /// off of). Overridden by [rows]'s own `genres` field when that's also
  /// configured and matches.
  final String genreSelector;
  final String genreAttr;

  /// A count the site *advertises* but doesn't expose through [chapters],
  /// e.g. Webtoons' "Read 12 new episodes only on the app!" message: episodes
  /// that exist and are numbered, but simply aren't reachable through the web
  /// surface this config scrapes at all. Distinct from
  /// `ChaptersConfig.lockedSelector`/`SourceChapter.locked` (a chapter that
  /// *appears* in the list but is gated behind payment); this is chapters
  /// that never appear in the list to begin with. The matched text is parsed
  /// leniently: the first run of digits found, so surrounding prose ("Read
  /// 12 new episodes...") doesn't need to be stripped by the selector. Empty
  /// selector (the default) or unparseable/absent text both mean 0; most
  /// sources have no such concept.
  final String unlistedChaptersSelector;
  final String unlistedChaptersAttr;

  /// Label-row extraction of author/status/genres/description.
  final RowsConfig? rows;

  /// Maps the site's status text (matched case-insensitively) to a
  /// `PublicationStatus` name: ongoing, completed, hiatus or cancelled.
  final Map<String, String> statusMap;

  /// Explicit pipeline overriding the direct details fetch (e.g. a details
  /// page that needs an id captured from a first request). The adapter still
  /// parses the terminal body inline for the flat fields + label rows.
  final Pipeline? steps;

  List<CoverSource> get coverChain =>
      cover ??
      (coverSelector.isEmpty
          ? const []
          : [CoverSource(selector: coverSelector, attr: coverAttr)]);

  List<CoverSource> get bannerChain =>
      banner ??
      (bannerSelector.isEmpty
          ? const []
          : [CoverSource(selector: bannerSelector, attr: bannerAttr)]);

  List<CoverSource> get backgroundChain =>
      background ??
      (backgroundSelector.isEmpty
          ? const []
          : [CoverSource(selector: backgroundSelector, attr: backgroundAttr)]);

  Map<String, dynamic> toJson() => {
    'titleSelector': titleSelector,
    'authorSelector': authorSelector,
    'descriptionSelector': descriptionSelector,
    'coverSelector': coverSelector,
    'coverAttr': coverAttr,
    if (cover != null) 'cover': [for (final step in cover!) step.toJson()],
    if (bannerSelector.isNotEmpty) 'bannerSelector': bannerSelector,
    if (bannerSelector.isNotEmpty) 'bannerAttr': bannerAttr,
    if (banner != null) 'banner': [for (final step in banner!) step.toJson()],
    if (backgroundSelector.isNotEmpty)
      'backgroundSelector': backgroundSelector,
    if (backgroundSelector.isNotEmpty) 'backgroundAttr': backgroundAttr,
    if (background != null)
      'background': [for (final step in background!) step.toJson()],
    if (genreSelector.isNotEmpty) 'genreSelector': genreSelector,
    if (genreAttr.isNotEmpty) 'genreAttr': genreAttr,
    if (unlistedChaptersSelector.isNotEmpty)
      'unlistedChaptersSelector': unlistedChaptersSelector,
    if (unlistedChaptersAttr.isNotEmpty)
      'unlistedChaptersAttr': unlistedChaptersAttr,
    if (rows != null) 'rows': rows!.toJson(),
    if (statusMap.isNotEmpty) 'statusMap': statusMap,
    if (steps != null) 'steps': steps!.toJson(),
  };
}

class ChaptersConfig {
  const ChaptersConfig({
    this.request,
    this.itemSelector = '',
    this.nameSelector = 'a',
    this.nameAttr = '',
    this.urlSelector = 'a',
    this.urlAttr = 'href',
    this.dateSelector = '',
    this.dateAttr = '',
    this.lockedSelector = '',
    this.officialSelector = '',
    this.officialAttr = '',
    this.officialValue = '',
    this.reversed = true,
    this.steps,
  });

  factory ChaptersConfig.fromJson(Map<String, dynamic> json) => ChaptersConfig(
    request: json['request'] == null
        ? null
        : RequestTransform.fromJson(json['request'] as Map<String, dynamic>),
    itemSelector: json['itemSelector'] as String? ?? '',
    nameSelector: json['nameSelector'] as String? ?? 'a',
    nameAttr: json['nameAttr'] as String? ?? '',
    urlSelector: json['urlSelector'] as String? ?? 'a',
    urlAttr: json['urlAttr'] as String? ?? 'href',
    dateSelector: json['dateSelector'] as String? ?? '',
    dateAttr: json['dateAttr'] as String? ?? '',
    lockedSelector: json['lockedSelector'] as String? ?? '',
    officialSelector: json['officialSelector'] as String? ?? '',
    officialAttr: json['officialAttr'] as String? ?? '',
    officialValue: json['officialValue'] as String? ?? '',
    reversed: json['reversed'] as bool? ?? true,
    steps: _stepsFromJson(json['steps']),
  );

  /// Derives the chapter-list URL from the manga URL; null fetches the
  /// manga URL itself.
  final RequestTransform? request;

  /// Empty only when [steps] supplies the extraction instead of the sugar.
  final String itemSelector;
  final String nameSelector;
  final String nameAttr;
  final String urlSelector;
  final String urlAttr;

  /// Optional CSS selector (and [dateAttr]) for a chapter's upload date.
  /// Empty disables date parsing; the parsed text is read leniently
  /// ([parseSourceDate]), so unparseable formats just yield no date.
  final String dateSelector;
  final String dateAttr;

  /// Optional CSS selector checked for **presence** (not text/attribute)
  /// within the chapter item; a match means this chapter is locked behind
  /// payment (a "coin"/premium plugin's lock icon or price badge, e.g.
  /// `i.fa-lock`). Empty means the source has no such concept; every chapter
  /// reads as unlocked.
  final String lockedSelector;

  /// Marks a chapter as an official (licensed) translation rather than a fan
  /// scanlation; unlike [lockedSelector], this is a **value** check, not
  /// presence: [officialSelector] (and optional [officialAttr]; empty reads
  /// text) locates an element whose extracted value *contains*
  /// [officialValue]. Needed because some sites render the identical badge
  /// element for every chapter and only vary an attribute on it (confirmed
  /// live: one real source renders the same checkmark `<svg>` for every
  /// chapter, distinguishing official vs fan only by its `stroke` color);
  /// a presence-only check can't tell those apart. Empty [officialValue]
  /// means the source has no such concept; every chapter reads as
  /// unofficial.
  final String officialSelector;
  final String officialAttr;
  final String officialValue;

  /// True when the site lists newest chapters first (the common case);
  /// the engine then reverses the list into reading order.
  final bool reversed;

  /// Explicit pipeline overriding the desugared chapter extraction (e.g.
  /// object-keyed chapter maps, a JSON id→request hop). Sugar fields ignored.
  final Pipeline? steps;

  Map<String, dynamic> toJson() => {
    if (request != null) 'request': request!.toJson(),
    'itemSelector': itemSelector,
    'nameSelector': nameSelector,
    'nameAttr': nameAttr,
    'urlSelector': urlSelector,
    'urlAttr': urlAttr,
    if (dateSelector.isNotEmpty) 'dateSelector': dateSelector,
    if (dateAttr.isNotEmpty) 'dateAttr': dateAttr,
    if (lockedSelector.isNotEmpty) 'lockedSelector': lockedSelector,
    if (officialSelector.isNotEmpty) 'officialSelector': officialSelector,
    if (officialAttr.isNotEmpty) 'officialAttr': officialAttr,
    if (officialValue.isNotEmpty) 'officialValue': officialValue,
    'reversed': reversed,
    if (steps != null) 'steps': steps!.toJson(),
  };
}

// ---------------------------------------------------------------------
// The JSON-API dialect (`"type": "api"`): the same declarative idea as the
// HTML dialect, with JSON paths/templates where that one has CSS
// selectors, for sites whose data comes from a JSON:API-style endpoint.

/// Extraction of one string value from a JSON node: the first non-empty
/// [paths] hit (after `{lang}`-style variable substitution), optionally
/// rendered through [template] (`{value}` = the hit; other placeholders
/// resolve as paths against the item, then the response root). A string in
/// the config is shorthand for a single path.
class JsonValueSpec {
  const JsonValueSpec({
    this.paths = const [],
    this.template = '',
    this.fallback = '',
  });

  factory JsonValueSpec.fromJson(Object? json) {
    if (json == null) return const JsonValueSpec();
    if (json is String) return JsonValueSpec(paths: [json]);
    final map = json as Map<String, dynamic>;
    return JsonValueSpec(
      paths: [
        if (map['path'] != null) map['path'] as String,
        ...(map['paths'] as List<dynamic>? ?? []).cast<String>(),
      ],
      template: map['template'] as String? ?? '',
      fallback: map['default'] as String? ?? '',
    );
  }

  final List<String> paths;
  final String template;
  final String fallback;

  bool get isEmpty => paths.isEmpty && template.isEmpty;

  /// The extracted string; null when nothing matched and no [fallback] is
  /// configured.
  String? evaluate(
    Object? item, {
    Map<String, String> vars = const {},
    Object? root,
  }) {
    Object? raw;
    for (final path in paths) {
      raw = readJsonPath(item, substituteVars(path, vars));
      if (raw != null && '$raw'.isNotEmpty) break;
      raw = null;
    }
    // With paths declared, a miss falls back rather than templating
    // garbage.
    if (paths.isNotEmpty && raw == null) {
      return fallback.isEmpty ? null : fallback;
    }
    if (template.isEmpty) {
      return raw?.toString() ?? (fallback.isEmpty ? null : fallback);
    }
    return renderJsonTemplate(
      template,
      value: raw?.toString(),
      item: item,
      vars: vars,
      root: root,
    );
  }

  /// Replaces `{name}` occurrences from [vars], used on paths, where only
  /// variables (not JSON lookups) make sense.
  static String substituteVars(String input, Map<String, String> vars) {
    var result = input;
    vars.forEach((name, value) {
      result = result.replaceAll('{$name}', value);
    });
    return result;
  }

  Map<String, dynamic> toJson() => {
    if (paths.isNotEmpty) 'paths': paths,
    if (template.isNotEmpty) 'template': template,
    if (fallback.isNotEmpty) 'default': fallback,
  };
}

/// A list of strings: the list at [items], one [value] extraction per
/// element (used for genres).
class JsonListSpec {
  const JsonListSpec({this.items = '', this.value = const JsonValueSpec()});

  factory JsonListSpec.fromJson(Map<String, dynamic> json) => JsonListSpec(
    items: json['items'] as String? ?? '',
    value: JsonValueSpec.fromJson(json['value']),
  );

  final String items;
  final JsonValueSpec value;

  List<String> evaluate(Object? item, {Map<String, String> vars = const {}}) {
    final list = readJsonPath(item, substituted(vars));
    if (list is! List) return const [];
    return [
      for (final element in list)
        if (value.evaluate(element, vars: vars) case final v? when v.isNotEmpty)
          v,
    ];
  }

  String substituted(Map<String, String> vars) =>
      JsonValueSpec.substituteVars(items, vars);

  Map<String, dynamic> toJson() => {'items': items, 'value': value.toJson()};
}

/// A multi-part label, like `Vol. 1 Ch. 2 Title`: each part is a
/// [JsonValueSpec]; missing parts are skipped, the rest joined with
/// [join], and an entirely empty result becomes [fallback].
class JsonNameSpec {
  const JsonNameSpec({
    this.parts = const [],
    this.join = ' ',
    this.fallback = '',
  });

  factory JsonNameSpec.fromJson(Object? json) {
    if (json == null) return const JsonNameSpec();
    final map = json as Map<String, dynamic>;
    if (map['parts'] == null) {
      return JsonNameSpec(parts: [JsonValueSpec.fromJson(json)]);
    }
    return JsonNameSpec(
      parts: [
        for (final part in map['parts'] as List<dynamic>)
          JsonValueSpec.fromJson(part),
      ],
      join: map['join'] as String? ?? ' ',
      fallback: map['default'] as String? ?? '',
    );
  }

  final List<JsonValueSpec> parts;
  final String join;
  final String fallback;

  String evaluate(
    Object? item, {
    Map<String, String> vars = const {},
    Object? root,
  }) {
    final found = [
      for (final part in parts)
        if (part.evaluate(item, vars: vars, root: root) case final v?
            when v.isNotEmpty)
          v,
    ];
    return found.isEmpty ? fallback : found.join(join);
  }

  Map<String, dynamic> toJson() => {
    'parts': [for (final part in parts) part.toJson()],
    'join': join,
    if (fallback.isNotEmpty) 'default': fallback,
  };
}

/// How a manga is read out of an API item, shared by listings and details.
class ApiMangaSpec {
  const ApiMangaSpec({
    this.url = const JsonValueSpec(),
    this.title = const JsonValueSpec(),
    this.description = const JsonValueSpec(),
    this.author = const JsonValueSpec(),
    this.cover = const JsonValueSpec(),
    this.genres = const JsonListSpec(),
  });

  factory ApiMangaSpec.fromJson(Map<String, dynamic> json) => ApiMangaSpec(
    url: JsonValueSpec.fromJson(json['url']),
    title: JsonValueSpec.fromJson(json['title']),
    description: JsonValueSpec.fromJson(json['description']),
    author: JsonValueSpec.fromJson(json['author']),
    cover: JsonValueSpec.fromJson(json['cover']),
    genres: json['genres'] == null
        ? const JsonListSpec()
        : JsonListSpec.fromJson(json['genres'] as Map<String, dynamic>),
  );

  final JsonValueSpec url;
  final JsonValueSpec title;
  final JsonValueSpec description;
  final JsonValueSpec author;
  final JsonValueSpec cover;
  final JsonListSpec genres;

  Map<String, dynamic> toJson() => {
    'url': url.toJson(),
    'title': title.toJson(),
    'description': description.toJson(),
    'author': author.toJson(),
    'cover': cover.toJson(),
    if (genres.items.isNotEmpty) 'genres': genres.toJson(),
  };
}

/// A paginated API listing. [path] supports `{page}`, `{offset}`,
/// `{query}` and `{lang}`; [items] locates the result array and
/// [totalPath] a total count for has-next ( falling back to "page was
/// full" when absent).
class ApiListingConfig {
  const ApiListingConfig({
    this.path = '',
    this.pageSize = 0,
    this.items = 'data',
    this.totalPath = '',
    this.tagParam = '',
    this.tagExcludeParam = '',
    this.tagJoin = '',
    this.steps,
  });

  factory ApiListingConfig.fromJson(Map<String, dynamic> json) =>
      ApiListingConfig(
        path: json['path'] as String? ?? '',
        pageSize: json['pageSize'] as int? ?? 0,
        items: json['items'] as String? ?? 'data',
        totalPath: json['totalPath'] as String? ?? '',
        tagParam: json['tagParam'] as String? ?? '',
        tagExcludeParam: json['tagExcludeParam'] as String? ?? '',
        tagJoin: json['tagJoin'] as String? ?? '',
        steps: _stepsFromJson(json['steps']),
      );

  /// Empty only when [steps] supplies the request instead of the sugar path.
  final String path;
  final int pageSize;
  final String items;
  final String totalPath;

  /// Meaningful only on [ApiSourceConfig.tag]: see
  /// [ListingConfig.tagParam]/[tagExcludeParam]/[tagJoin], same shape,
  /// same derived-capability meaning, mirrored for the API dialect.
  final String tagParam;
  final String tagExcludeParam;
  final String tagJoin;

  /// Explicit pipeline producing the listing response root; the adapter still
  /// reads [items]/[totalPath] and the manga spec off it. Declarative `filters`
  /// are not applied in steps mode.
  final Pipeline? steps;

  Map<String, dynamic> toJson() => {
    'path': path,
    if (pageSize != 0) 'pageSize': pageSize,
    'items': items,
    if (totalPath.isNotEmpty) 'totalPath': totalPath,
    if (tagParam.isNotEmpty) 'tagParam': tagParam,
    if (tagExcludeParam.isNotEmpty) 'tagExcludeParam': tagExcludeParam,
    if (tagJoin.isNotEmpty) 'tagJoin': tagJoin,
    if (steps != null) 'steps': steps!.toJson(),
  };
}

/// Where details for one manga live; the top-level manga spec is applied
/// to the node at [item].
class ApiDetailsConfig {
  const ApiDetailsConfig({this.path = '', this.item = 'data', this.steps});

  factory ApiDetailsConfig.fromJson(Map<String, dynamic> json) =>
      ApiDetailsConfig(
        path: json['path'] as String? ?? '',
        item: json['item'] as String? ?? 'data',
        steps: _stepsFromJson(json['steps']),
      );

  /// Supports `{url}` (the manga's source id) and `{lang}`. Empty only when
  /// [steps] supplies the request.
  final String path;
  final String item;

  /// Explicit pipeline producing the details response root; the adapter reads
  /// [item] + the manga spec off it.
  final Pipeline? steps;

  Map<String, dynamic> toJson() => {
    'path': path,
    'item': item,
    if (steps != null) 'steps': steps!.toJson(),
  };
}

/// The chapter feed: a listing that is fetched page after page until the
/// total is reached (or [maxItems] caps a runaway feed).
class ApiChaptersConfig {
  const ApiChaptersConfig({
    this.path = '',
    this.pageSize = 100,
    this.maxItems = 1000,
    this.items = 'data',
    this.totalPath = '',
    this.chapter = const ApiChapterSpec(),
    this.steps,
  });

  factory ApiChaptersConfig.fromJson(Map<String, dynamic> json) =>
      ApiChaptersConfig(
        path: json['path'] as String? ?? '',
        pageSize: json['pageSize'] as int? ?? 100,
        maxItems: json['maxItems'] as int? ?? 1000,
        items: json['items'] as String? ?? 'data',
        totalPath: json['totalPath'] as String? ?? '',
        chapter: json['chapter'] == null
            ? const ApiChapterSpec()
            : ApiChapterSpec.fromJson(json['chapter'] as Map<String, dynamic>),
        steps: _stepsFromJson(json['steps']),
      );

  /// Supports `{url}`, `{offset}`, `{page}` and `{lang}`. Empty only when
  /// [steps] supplies the request (still paged by the adapter via the seed).
  final String path;
  final int pageSize;
  final int maxItems;
  final String items;
  final String totalPath;
  final ApiChapterSpec chapter;

  /// Explicit pipeline producing each page's chapter-feed root; the adapter
  /// reads [items]/[totalPath] and the [chapter] spec off it, and still loops
  /// pages by seeding `{page}`/`{offset}`.
  final Pipeline? steps;

  Map<String, dynamic> toJson() => {
    'path': path,
    'pageSize': pageSize,
    'maxItems': maxItems,
    'items': items,
    if (totalPath.isNotEmpty) 'totalPath': totalPath,
    'chapter': chapter.toJson(),
    if (steps != null) 'steps': steps!.toJson(),
  };
}

/// How one chapter is read out of a feed item.
class ApiChapterSpec {
  const ApiChapterSpec({
    this.url = const JsonValueSpec(),
    this.name = const JsonNameSpec(),
    this.number = const JsonValueSpec(),
    this.date = const JsonValueSpec(),
    this.skipIf = '',
    this.locked = '',
    this.official = '',
  });

  factory ApiChapterSpec.fromJson(Map<String, dynamic> json) => ApiChapterSpec(
    url: JsonValueSpec.fromJson(json['url']),
    name: JsonNameSpec.fromJson(json['name']),
    number: JsonValueSpec.fromJson(json['number']),
    date: JsonValueSpec.fromJson(json['date']),
    skipIf: json['skipIf'] as String? ?? '',
    locked: json['locked'] as String? ?? '',
    official: json['official'] as String? ?? '',
  );

  final JsonValueSpec url;
  final JsonNameSpec name;
  final JsonValueSpec number;

  /// Optional path to the chapter's upload date (e.g.
  /// `attributes.publishAt`); read leniently via [parseSourceDate].
  final JsonValueSpec date;

  /// Items with a non-null value at this path are dropped (e.g. a chapter
  /// that's actually hosted externally, outside this source).
  final String skipIf;

  /// Optional path to a value indicating this chapter is locked behind
  /// payment, read "truthy" in a JS-like sense (non-null, non-zero,
  /// non-false, non-empty), covering both a boolean flag (`"premium": true`)
  /// and a price field (`"price": 99` locked / `"price": 0` free) with one
  /// mechanism. Empty means the source has no such concept; every chapter
  /// reads as unlocked.
  final String locked;

  /// Optional path to a value indicating this chapter is an official
  /// (licensed) translation rather than a fan scanlation, read "truthy"
  /// the same way [locked] is. Empty means the source has no such concept;
  /// every chapter reads as unofficial.
  final String official;

  Map<String, dynamic> toJson() => {
    'url': url.toJson(),
    'name': name.toJson(),
    'number': number.toJson(),
    if (date.paths.isNotEmpty) 'date': date.toJson(),
    if (skipIf.isNotEmpty) 'skipIf': skipIf,
    if (locked.isNotEmpty) 'locked': locked,
    if (official.isNotEmpty) 'official': official,
  };
}

/// Where a chapter's page image URLs come from: the list at [items] in the
/// response of [path], each element rendered through [template]
/// (`{value}` = the element; other placeholders resolve against the
/// response root, throwing on malformed responses).
class ApiPagesConfig {
  const ApiPagesConfig({
    this.path = '',
    this.items = 'data',
    this.template = '{value}',
    this.steps,
  });

  factory ApiPagesConfig.fromJson(Map<String, dynamic> json) => ApiPagesConfig(
    path: json['path'] as String? ?? '',
    items: json['items'] as String? ?? 'data',
    template: json['template'] as String? ?? '{value}',
    steps: _stepsFromJson(json['steps']),
  );

  /// Supports `{url}` (the chapter's source id) and `{lang}`. Empty only when
  /// [steps] supplies the request.
  final String path;
  final String items;
  final String template;

  /// Explicit pipeline producing the page-list response root; the adapter reads
  /// [items] + renders [template] per element off it.
  final Pipeline? steps;

  Map<String, dynamic> toJson() => {
    'path': path,
    'items': items,
    'template': template,
    if (steps != null) 'steps': steps!.toJson(),
  };
}

/// Declarative description of a JSON-API source (`"type": "api"`), for a
/// site whose data comes from a JSON:API-style endpoint rather than
/// server-rendered HTML.
class ApiSourceConfig implements AnySourceConfig {
  const ApiSourceConfig({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
    required this.apiUrl,
    this.icon = '',
    this.headers = const {},
    this.imageHeaders = const {},
    this.rateLimit,
    this.imageRateLimit,
    this.manga = const ApiMangaSpec(),
    required this.popular,
    this.search,
    this.tag,
    this.details,
    required this.chapters,
    required this.pages,
    this.filters = const [],
  });

  factory ApiSourceConfig.fromJson(
    Map<String, dynamic> json,
  ) => ApiSourceConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    lang: json['lang'] as String? ?? 'all',
    baseUrl: json['baseUrl'] as String,
    apiUrl: json['apiUrl'] as String,
    icon: json['icon'] as String? ?? '',
    headers: (json['headers'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
    imageHeaders: (json['imageHeaders'] as Map<String, dynamic>? ?? {}).map(
      (k, v) => MapEntry(k, v as String),
    ),
    imageRateLimit: json['imageRateLimit'] == null
        ? null
        : RateLimitConfig.fromJson(
            json['imageRateLimit'] as Map<String, dynamic>,
          ),
    rateLimit: json['rateLimit'] == null
        ? null
        : RateLimitConfig.fromJson(json['rateLimit'] as Map<String, dynamic>),
    manga: json['manga'] == null
        ? const ApiMangaSpec()
        : ApiMangaSpec.fromJson(json['manga'] as Map<String, dynamic>),
    popular: ApiListingConfig.fromJson(json['popular'] as Map<String, dynamic>),
    search: json['search'] == null
        ? null
        : ApiListingConfig.fromJson(json['search'] as Map<String, dynamic>),
    tag: json['tag'] == null
        ? null
        : ApiListingConfig.fromJson(json['tag'] as Map<String, dynamic>),
    details: json['details'] == null
        ? null
        : ApiDetailsConfig.fromJson(json['details'] as Map<String, dynamic>),
    chapters: ApiChaptersConfig.fromJson(
      json['chapters'] as Map<String, dynamic>,
    ),
    pages: ApiPagesConfig.fromJson(json['pages'] as Map<String, dynamic>),
    filters: [
      for (final filter in json['filters'] as List<dynamic>? ?? [])
        FilterConfig.fromJson(filter as Map<String, dynamic>),
    ],
  );

  @override
  final String id;
  @override
  final String name;
  @override
  final String lang;
  @override
  final String baseUrl;
  @override
  final String icon;

  /// Root the listing/details/chapters/pages paths resolve against.
  final String apiUrl;
  final Map<String, String> headers;

  /// Headers for fetching covers and pages; API CDNs usually need none.
  final Map<String, String> imageHeaders;
  final RateLimitConfig? rateLimit;

  /// See `SourceConfig.imageRateLimit`. Null for every API source today: the
  /// CDNs they read from are sized for browsers.
  final RateLimitConfig? imageRateLimit;
  final ApiMangaSpec manga;
  final ApiListingConfig popular;
  final ApiListingConfig? search;

  /// Exact-match browse for one or more already-known tag values; see
  /// [SourceConfig.tag], same meaning, mirrored for the API dialect.
  final ApiListingConfig? tag;
  final ApiDetailsConfig? details;
  final ApiChaptersConfig chapters;
  final ApiPagesConfig pages;
  final List<FilterConfig> filters;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'api',
    'id': id,
    'name': name,
    'lang': lang,
    'baseUrl': baseUrl,
    'apiUrl': apiUrl,
    if (icon.isNotEmpty) 'icon': icon,
    if (headers.isNotEmpty) 'headers': headers,
    if (imageHeaders.isNotEmpty) 'imageHeaders': imageHeaders,
    if (rateLimit != null) 'rateLimit': rateLimit!.toJson(),
    if (imageRateLimit != null) 'imageRateLimit': imageRateLimit!.toJson(),
    'manga': manga.toJson(),
    'popular': popular.toJson(),
    if (search != null) 'search': search!.toJson(),
    if (tag != null) 'tag': tag!.toJson(),
    if (details != null) 'details': details!.toJson(),
    'chapters': chapters.toJson(),
    'pages': pages.toJson(),
    if (filters.isNotEmpty) 'filters': filters.map((f) => f.toJson()).toList(),
  };
}

/// Extracts page image URLs from an inline `<script>` JSON blob, the shape
/// readers like MangaThemesia's `ts_reader.run({...})` use instead of `<img>`
/// tags. [pattern]'s first capture group must yield the JSON text; [itemsPath]
/// locates the image list within it (empty = the captured JSON is itself the
/// list); each element renders through [template] (`{value}` = the element).
class ScriptPagesConfig {
  const ScriptPagesConfig({
    required this.pattern,
    this.itemsPath = '',
    this.template = '{value}',
  });

  factory ScriptPagesConfig.fromJson(Map<String, dynamic> json) =>
      ScriptPagesConfig(
        pattern: json['pattern'] as String,
        itemsPath: json['itemsPath'] as String? ?? '',
        template: json['template'] as String? ?? '{value}',
      );

  final String pattern;
  final String itemsPath;
  final String template;

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    if (itemsPath.isNotEmpty) 'itemsPath': itemsPath,
    if (template != '{value}') 'template': template,
  };
}

class PagesConfig {
  const PagesConfig({
    this.request,
    this.imageSelector = '',
    this.imageAttr = 'src',
    this.script,
    this.steps,
  });

  factory PagesConfig.fromJson(Map<String, dynamic> json) => PagesConfig(
    request: json['request'] == null
        ? null
        : RequestTransform.fromJson(json['request'] as Map<String, dynamic>),
    imageSelector: json['imageSelector'] as String? ?? '',
    imageAttr: json['imageAttr'] as String? ?? 'src',
    script: json['script'] == null
        ? null
        : ScriptPagesConfig.fromJson(json['script'] as Map<String, dynamic>),
    steps: _stepsFromJson(json['steps']),
  );

  /// Derives the page-list URL from the chapter URL; null fetches the
  /// chapter URL itself.
  final RequestTransform? request;
  final String imageSelector;
  final String imageAttr;

  /// When set, pages come from an inline JSON script blob (`ts_reader.run`) as
  /// the primary source. [imageSelector], if also set, is a fallback: it runs
  /// only when the script yields nothing, the shape MangaThemesia sites take
  /// when they drop the script blob but still render `<img>` tags (see
  /// `_HtmlEngine.fetchPages`).
  final ScriptPagesConfig? script;

  /// Explicit pipeline overriding the desugared single-step extraction, the
  /// escape hatch for shapes the sugar fields can't express (e.g. HTML page →
  /// capture id → JSON ajax). When set, the sugar fields above are ignored.
  final Pipeline? steps;

  Map<String, dynamic> toJson() => {
    if (request != null) 'request': request!.toJson(),
    'imageSelector': imageSelector,
    'imageAttr': imageAttr,
    if (script != null) 'script': script!.toJson(),
    if (steps != null) 'steps': steps!.toJson(),
  };
}
