import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'publication_status.dart';
import 'source_image.dart';
import 'web_view_fetcher.dart';

// [PublicationStatus] lives in its own file so consumers (the app's model layer
// branches on it to tell a *completed* series from a merely *up to date* one)
// can import it without pulling the rest of the engine. Re-exported here so the
// many `import '…/source.dart'` users keep resolving it unchanged.
export 'publication_status.dart';
// The image-fetch policy + its request/notice types travel with Source: every
// caller of imageBytes/imageRequest needs them.
export 'source_image.dart';

/// Replays a host's previously-captured Cloudflare clearance (the cookie a
/// browser earned passing a challenge, plus the matching User-Agent) onto
/// outbound source requests. The app supplies a drift-backed implementation;
/// standalone use of the engine leaves [Source.clearanceStore] null.
abstract interface class ClearanceStore {
  /// Materializes persisted clearances (idempotent; safe to call again).
  Future<void> load();

  /// Headers to merge **last** over a request's own headers for [url]'s host;
  /// empty when there's no clearance, so callers fall back untouched.
  Map<String, String> headersFor(String url);
}

/// User overrides for a `webview` source's declared
/// `SourceConfig.localStoragePreferences`, e.g. "also accept gore content"
/// on top of whatever the config's `localStorageSeed` bakes in by default.
/// Keyed by source id (a preference is inherently per-source, unlike
/// [ClearanceStore]'s per-host keying), value `true`/`false` per declared
/// preference id; a preference with no entry here falls back to its own
/// `SourceConfig.LocalStoragePreferenceConfig.defaultValue`. The app
/// supplies a persisted implementation; standalone use of the engine leaves
/// [Source.localStoragePreferenceStore] null, so every source just gets its
/// config's declared defaults.
abstract interface class LocalStoragePreferenceStore {
  /// Materializes persisted overrides (idempotent; safe to call again).
  Future<void> load();

  /// This source's stored overrides, by preference id. Missing keys mean
  /// "use that preference's own default"; this never needs to return every
  /// declared preference, only the ones a user has actually changed.
  Map<String, bool> valuesFor(String sourceId);
}

/// One user-facing toggle a `webview` source exposes, the UI-relevant
/// subset of `SourceConfig.LocalStoragePreferenceConfig` (which also carries
/// where in the seed it writes, an `_HtmlEngine`-only detail this doesn't
/// need). A plain record, not a class, so imperative sources can expose
/// these too without depending on the declarative config types.
typedef LocalStoragePreference = ({String id, String label, bool defaultValue});

/// Models exchanged with online sources, mirroring Mihon's `SManga`,
/// `SChapter` and `Page` types.
class SourceManga {
  SourceManga({
    required this.url,
    required this.title,
    this.thumbnailUrl = '',
    this.bannerUrl = '',
    this.backgroundUrl = '',
    this.author = '',
    this.description = '',
    this.genres = const [],
    this.status = PublicationStatus.unknown,
    this.unlistedChapterCount = 0,
  });

  /// Source-relative identifier of this manga (path or API id).
  final String url;
  String title;
  String thumbnailUrl;

  /// A wide hero image distinct from [thumbnailUrl] (a poster-shaped cover)
  /// and from [backgroundUrl] (a tiled backdrop meant to sit beneath it);
  /// see `DetailsConfig.banner`. '' means the source has none; the app then
  /// has no hero banner for this manga, not an error.
  String bannerUrl;

  /// A tiled backdrop distinct from [bannerUrl], often a near-solid
  /// per-series mood color rather than character art, so typically a
  /// cleaner tint-color source than [bannerUrl]; see
  /// `DetailsConfig.background`. '' means the source has none.
  String backgroundUrl;
  String author;
  String description;
  List<String> genres;
  PublicationStatus status;

  /// Chapters the site advertises but doesn't expose through [Source.fetchChapters]
  /// at all (see `DetailsConfig.unlistedChaptersSelector`); 0 means either the
  /// source has no such concept, or the count wasn't parseable.
  int unlistedChapterCount;
}

class SourceChapter {
  SourceChapter({
    required this.url,
    required this.name,
    this.number = -1,
    this.dateUpload,
    this.locked = false,
    this.official = false,
  });

  /// Source-relative identifier of this chapter (path or API id).
  final String url;
  final String name;
  final double number;

  /// When the source published this chapter, if it reports a parseable date;
  /// null otherwise.
  final DateTime? dateUpload;

  /// Whether the source gates this chapter behind payment (a "coin"/premium
  /// system) rather than making it freely readable. The app is a
  /// content-neutral reader (it never facilitates payment on a source's
  /// behalf), so a locked chapter is represented (correct chapter count,
  /// accurate "latest chapter"), not hidden, but isn't openable in the
  /// reader.
  final bool locked;

  /// Whether this chapter is an official (licensed) translation rather than
  /// a fan scanlation. Some sites upload a chapter as a fan translation
  /// first, then replace it in place with the official release
  /// once one exists, same chapter number/slot, different underlying
  /// pages, so this flipping from false to true on an otherwise-unchanged
  /// chapter is the signal that its content actually changed and a reader
  /// that cached the old pages may want to re-fetch them. koni_dojo only
  /// reports the current state; deciding what to do when it changes (e.g.
  /// re-downloading) is the app's call, not this engine's.
  final bool official;
}

/// Best-effort parse of a source-supplied chapter date string. Handles ISO-8601
/// (e.g. an API source's `publishAt`) and epoch seconds/milliseconds; returns null
/// for empty input or formats it can't read (relative strings like "2 days
/// ago", locale-specific dates), so callers degrade to no date rather than a
/// wrong one.
DateTime? parseSourceDate(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  // Try epoch first: a bare integer would otherwise be mis-read by
  // DateTime.tryParse. Sub-1e12 magnitudes are seconds, larger are
  // milliseconds (both cross over around the year 2001).
  final epoch = int.tryParse(value);
  if (epoch != null) {
    final ms = epoch.abs() < 1000000000000 ? epoch * 1000 : epoch;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  return DateTime.tryParse(value)?.toUtc();
}

/// One page of a paginated catalog listing.
class CatalogPage {
  CatalogPage({required this.items, required this.hasNextPage});

  final List<SourceManga> items;
  final bool hasNextPage;
}

/// How one filter option is currently set.
enum FilterState { off, included, excluded }

/// One selectable option of a [FilterGroup]: a tag, genre, status, ...
class FilterOption {
  const FilterOption({required this.id, required this.label});

  /// Value the source sends (a tag UUID, a slug, ...).
  final String id;

  /// What the filter sheet shows.
  final String label;
}

/// A named group of filter options a source can narrow browsing by
/// (e.g. "Genres").
class FilterGroup {
  const FilterGroup({
    required this.id,
    required this.name,
    required this.options,
    this.supportsExclusion = false,
  });

  final String id;
  final String name;
  final List<FilterOption> options;

  /// Whether options in this group cycle off → included → excluded, or
  /// only off → included.
  final bool supportsExclusion;
}

/// The user's tri-state choices across a source's filter groups, keyed by
/// group id and option id. Mutable: the filter sheet edits a [copy] and
/// applies it back.
class FilterSelection {
  final Map<String, Set<String>> _included = {};
  final Map<String, Set<String>> _excluded = {};

  Set<String> included(String groupId) => _included[groupId] ?? const {};
  Set<String> excluded(String groupId) => _excluded[groupId] ?? const {};

  /// Every included option id across all groups (for sources whose API
  /// takes one flat list of tag ids, not grouped).
  List<String> get allIncluded => [for (final ids in _included.values) ...ids];

  List<String> get allExcluded => [for (final ids in _excluded.values) ...ids];

  FilterState stateOf(String groupId, String optionId) {
    if (included(groupId).contains(optionId)) return FilterState.included;
    if (excluded(groupId).contains(optionId)) return FilterState.excluded;
    return FilterState.off;
  }

  void set(String groupId, String optionId, FilterState state) {
    _included[groupId]?.remove(optionId);
    _excluded[groupId]?.remove(optionId);
    switch (state) {
      case FilterState.included:
        (_included[groupId] ??= {}).add(optionId);
      case FilterState.excluded:
        (_excluded[groupId] ??= {}).add(optionId);
      case FilterState.off:
        break;
    }
  }

  /// Advances an option: off → included → excluded → off, skipping the
  /// excluded state when [group] doesn't support it.
  void cycle(FilterGroup group, String optionId) {
    final next = switch (stateOf(group.id, optionId)) {
      FilterState.off => FilterState.included,
      FilterState.included =>
        group.supportsExclusion ? FilterState.excluded : FilterState.off,
      FilterState.excluded => FilterState.off,
    };
    set(group.id, optionId, next);
  }

  /// Number of set options, for the filter button badge.
  int get count =>
      _included.values.fold<int>(0, (sum, ids) => sum + ids.length) +
      _excluded.values.fold<int>(0, (sum, ids) => sum + ids.length);

  bool get isEmpty => count == 0;

  void clear() {
    _included.clear();
    _excluded.clear();
  }

  FilterSelection copy() {
    final copy = FilterSelection();
    _included.forEach((group, ids) => copy._included[group] = {...ids});
    _excluded.forEach((group, ids) => copy._excluded[group] = {...ids});
    return copy;
  }
}

// ── The composed source value ───────────────────────────────────────────────
// There is exactly **one** concrete [Source], a value, never subclassed.
// Behaviour is assembled from operation closures ([SourceOps]), by the
// declarative engine builders (`htmlSource`/`apiSource`) or hand-written for
// imperative sources; cross-cutting seams (clearance, consent preferences)
// are injected setters, not transport middleware. See
// `docs/architecture-decisions.md`.

/// What a listing op is asked for. Empty [query] means popular/latest; the op
/// itself encodes which listing, so there's no "type" field.
class ListingQuery {
  const ListingQuery({this.page = 1, this.query = '', this.filters});
  final int page;
  final String query;
  final FilterSelection? filters;
}

/// Opaque source-relative identifier of a manga (today's `SourceManga.url`). Ops
/// carry only the id and return fresh models; the caller merges, so nothing
/// mutates a shared object.
class MangaRef {
  const MangaRef(this.url, {this.knownThumbnailUrl = ''});
  final String url;

  /// A thumbnail already known for this manga (e.g. from the listing a
  /// reader tapped into it from), used as a fallback when the details page's
  /// own cover extraction finds nothing; some sites genuinely have no cover
  /// on the details page itself despite listing one on `popular`/`search`.
  final String knownThumbnailUrl;
}

class ChapterRef {
  const ChapterRef(this.url);
  final String url;
}

/// A page to fetch, carrying the headers (or an already-signed URL) needed to
/// fetch it directly, so `background_downloader` and the reader both work
/// without re-running the source's transport.
class PageRef {
  PageRef(this.url, {Map<String, String>? headers}) : headers = {...?headers};
  final Uri url;
  final Map<String, String> headers;
}

typedef ListingOp = Future<CatalogPage> Function(ListingQuery);
typedef DetailsOp = Future<SourceManga> Function(MangaRef);
typedef ChaptersOp = Future<List<SourceChapter>> Function(MangaRef);
typedef PagesOp = Future<List<PageRef>> Function(ChapterRef);
typedef FiltersOp = Future<List<FilterGroup>> Function();

Future<List<FilterGroup>> _noFilters() async => const [];

/// What's asked of a [TagOp]: browse everything carrying every tag in
/// [included], carrying none of [excluded]: [included] `AND`-ed together,
/// not `OR`; a source that can't express that combination just ignores
/// what it can't do (see [TagCapabilities]).
class TagQuery {
  const TagQuery({
    required this.included,
    this.excluded = const {},
    this.page = 1,
  });
  final Set<String> included;
  final Set<String> excluded;
  final int page;
}

typedef TagOp = Future<CatalogPage> Function(TagQuery);

/// What a source's [TagOp] can actually express (declared once, from its
/// own config, not discovered), so a caller can decide what to offer (a
/// second tag chip, an exclude toggle) before trying something the source
/// would just silently drop.
class TagCapabilities {
  const TagCapabilities({this.multiple = false, this.exclusion = false});

  /// More than one [TagQuery.included] value has an effect (`AND`-ed). False
  /// means only the first is used; extras are silently ignored.
  final bool multiple;

  /// [TagQuery.excluded] has an effect. False means it's silently ignored.
  final bool exclusion;
}

Future<CatalogPage> _noTagListing(TagQuery query) async =>
    CatalogPage(items: const [], hasNextPage: false);

/// The source's behaviours as composable values. Reuse comes from sharing the
/// builders that produce these; variation from swapping one with [copyWith].
class SourceOps {
  SourceOps({
    required this.popular,
    required this.search,
    required this.details,
    required this.chapters,
    required this.pages,
    FiltersOp? filters,
    TagOp? tag,
    this.tagCapabilities = const TagCapabilities(),
  }) : filters = filters ?? _noFilters,
       tag = tag ?? _noTagListing;

  final ListingOp popular;
  final ListingOp search;
  final DetailsOp details;
  final ChaptersOp chapters;
  final PagesOp pages;
  final FiltersOp filters;

  /// Exact-match browse for one or more already-known tag values; see
  /// [SourceConfig.tag]. Defaults to an always-empty listing for sources
  /// that don't compose one in.
  final TagOp tag;
  final TagCapabilities tagCapabilities;

  SourceOps copyWith({
    ListingOp? popular,
    ListingOp? search,
    DetailsOp? details,
    ChaptersOp? chapters,
    PagesOp? pages,
    FiltersOp? filters,
    TagOp? tag,
    TagCapabilities? tagCapabilities,
  }) => SourceOps(
    popular: popular ?? this.popular,
    search: search ?? this.search,
    details: details ?? this.details,
    chapters: chapters ?? this.chapters,
    pages: pages ?? this.pages,
    filters: filters ?? this.filters,
    tag: tag ?? this.tag,
    tagCapabilities: tagCapabilities ?? this.tagCapabilities,
  );
}

/// Stable descriptor of a source.
class SourceInfo {
  const SourceInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
    this.icon = '',
  });
  final String id;
  final String name;
  final String lang;
  final String baseUrl;

  /// Optional site icon (a `data:image/png;base64,…` URI or `http(s)` URL); ''
  /// when none. Shown in the app's source lists.
  final String icon;
}

/// The one concrete source type: data + composed ops, with an ergonomic facade
/// so callers write `source.popular(1)`. Built by `htmlSource`/`apiSource` (the
/// declarative engines) or hand-written for imperative sources, never
/// subclassed. [imageHeaders]/[throttle]/[clearanceStore] are cross-cutting
/// concerns the builder wires to its transport, and [imageBytes] is the one
/// place the resulting fetch policy lives — see `fetchSourceImage`.
class Source {
  Source({
    required this.info,
    required SourceOps ops,
    Map<String, String> Function(String url)? imageHeaders,
    Future<void> Function()? throttle,
    void Function(ClearanceStore?)? clearanceSink,
    void Function(LocalStoragePreferenceStore?)? localStoragePreferenceSink,
    http.Client? client,
    WebViewFetcher? webViewFetcher,
    void Function()? beginShare,
    void Function()? endShare,
    this.warmImageByUrl = false,
    this.warmImageViaImgTag = false,
    this.requiresWebView = false,
    this.loginUrl = '',
    this.localStoragePreferences = const <LocalStoragePreference>[],
  }) : _ops = ops,
       _imageHeaders = imageHeaders,
       _throttle = throttle,
       _clearanceSink = clearanceSink,
       _localStoragePreferenceSink = localStoragePreferenceSink,
       _client = client,
       _webViewFetcher = webViewFetcher,
       _beginShare = beginShare,
       _endShare = endShare;

  final SourceInfo info;
  final SourceOps _ops;
  final Map<String, String> Function(String url)? _imageHeaders;
  final Future<void> Function()? _throttle;
  final void Function(ClearanceStore?)? _clearanceSink;
  final void Function(LocalStoragePreferenceStore?)?
  _localStoragePreferenceSink;
  /// Transport for [imageBytes]. Optional so a hand-composed Source stays
  /// cheap to build; one is created on first use when absent, because a
  /// Source that can't fetch its own images would be an incomplete value and
  /// every test double would have to know that.
  final http.Client? _client;
  final WebViewFetcher? _webViewFetcher;
  http.Client? _lazyClient;
  final void Function()? _beginShare;
  final void Function()? _endShare;

  /// Runs [body] with identical GETs to this source coalesced into one
  /// request.
  ///
  /// For a caller that legitimately needs the same page twice: loading a
  /// series screen asks for details and then chapters, and on most sites both
  /// parse the same document. On a [requiresWebView] source that was two full
  /// browser navigations to render one screen.
  ///
  /// **Scoped, deliberately, rather than a cache with a time-to-live.** A TTL
  /// would silently answer a user-initiated refresh with a stale page, and the
  /// bug it caused would appear seconds later somewhere else entirely. Here
  /// the sharing lasts exactly as long as the caller says it does; the next
  /// scope refetches. Nesting is refcounted, so an inner scope doesn't end an
  /// outer one.
  ///
  /// GETs only: a POST is a request to change something, and two of them are
  /// not one.
  Future<T> withSharedRequests<T>(Future<T> Function() body) async {
    _beginShare?.call();
    try {
      return await body();
    } finally {
      _endShare?.call();
    }
  }

  /// Whether this source's images need a transport that can adapt per
  /// request, which rules out handing them to an OS background downloader.
  ///
  /// [requiresWebView] is the real marker: these requests only work from a
  /// browser, so a request built now and performed hours later by something
  /// else can neither refresh what expired nor escalate when the wall comes
  /// back. [warmImageByUrl]/[warmImageViaImgTag] widen it — both exist only
  /// to tell a browser *how* to fetch an image, so a source setting either is
  /// saying its images need one even where the marker is absent (an
  /// imperative source, say, with no config to mirror).
  ///
  /// A host is expected to route these away from a deferred transport and
  /// **say so**: on mobile, "downloading" normally means it continues with
  /// the app closed, and for these sources it won't.
  ///
  /// Not yet the whole question — a source that signs each request needs the
  /// same routing and sets none of these. When request signing lands, this is
  /// the one place that has to learn about it.
  bool get requiresLiveTransport =>
      requiresWebView || warmImageByUrl || warmImageViaImgTag;

  /// URL and headers for one of this source's images, for a host that has to
  /// perform the fetch itself.
  ///
  /// Exists for exactly one caller shape: a transport that isn't Dart. The
  /// app's native download runner hands the request to a platform downloader
  /// that keeps working while the process is suspended, so it can't call
  /// [imageBytes]. Everything else should — this gives up wall detection and
  /// WebView recovery, and the caller takes on both.
  ///
  /// See [requiresWebView]: a source that needs a browser can't be served by
  /// this at all.
  SourceImageRequest imageRequest(Uri url) => (
    url: url,
    headers: _imageHeaders?.call(url.toString()) ?? const <String, String>{},
  );

  /// The bytes of one of this source's images — a page or a cover.
  ///
  /// Handles the source's own header set, rate limit, wall detection and
  /// (where the host supplied a browser) challenge recovery. Prefer this over
  /// fetching a page URL directly: the flags that decide *how* to recover
  /// belong to the source, and a caller that reaches for them itself is a
  /// caller that will eventually get them wrong.
  ///
  /// Throws `CloudflareChallengeException` when the source is walled and no
  /// browser recovered it; `http.ClientException` for ordinary failures.
  Future<Uint8List> imageBytes(
    Uri url, {
    Map<String, String>? headers,
    void Function(SourceImageNotice notice)? onNotice,
    void Function(int received, int? total)? onProgress,
  }) => fetchSourceImage(
    url,
    client: _client ?? (_lazyClient ??= http.Client()),
    headers: headers ?? imageRequest(url).headers,
    webViewFetcher: _webViewFetcher,
    warmByUrl: warmImageByUrl,
    viaImgTag: warmImageViaImgTag,
    baseUrl: info.baseUrl,
    throttle: _throttle,
    onNotice: onNotice,
    onProgress: onProgress,
  );

  /// Mirrors `SourceConfig.warmImageByUrl`. See
  /// `WebViewFetcher.fetchBytes`'s `warmByUrl` param. False (the default)
  /// for every source that doesn't set it, imperative sources included.
  final bool warmImageByUrl;

  /// Mirrors `SourceConfig.warmImageViaImgTag`. See
  /// `WebViewFetcher.fetchBytes`'s `viaImgTag` param. Takes precedence over
  /// [warmImageByUrl] when both are true.
  final bool warmImageViaImgTag;

  /// Mirrors `SourceConfig.webview`: this source's requests have to go
  /// through a real browser, because a plain HTTP client earns a challenge
  /// page instead of content.
  ///
  /// A capability marker, not a hint. It tells a host application that this
  /// source cannot be served by a transport that builds a request ahead of
  /// time and performs it elsewhere — an OS-level background downloader, a
  /// pre-signed batch, a cached request plan. Such a transport can only carry
  /// a fixed URL and a fixed header map, so every request would go out with
  /// credentials frozen at build time and no way to escalate to the browser
  /// when the wall comes back.
  ///
  /// False for imperative sources, which have no config to mirror; one that
  /// needs a browser should pass it explicitly.
  final bool requiresWebView;

  /// Mirrors `SourceConfig.loginUrl`; '' means this source has no login
  /// concept. Purely a UI trigger; see that field's doc.
  final String loginUrl;

  /// Mirrors `SourceConfig.localStoragePreferences`; empty means this
  /// source has no user-facing consent toggles. Purely a UI trigger (render
  /// one control per entry, write changes through
  /// [localStoragePreferenceStore]); the values only actually take effect on
  /// the next fetch, through whatever store was wired in.
  final List<LocalStoragePreference> localStoragePreferences;

  String get id => info.id;
  String get name => info.name;
  String get lang => info.lang;
  String get baseUrl => info.baseUrl;
  String get icon => info.icon;

  Future<CatalogPage> popular(int page) =>
      _ops.popular(ListingQuery(page: page));

  Future<CatalogPage> search(
    String query,
    int page, {
    FilterSelection? filters,
  }) => _ops.search(ListingQuery(page: page, query: query, filters: filters));

  /// Fresh details for [ref]; the caller merges into its own model.
  Future<SourceManga> details(MangaRef ref) => _ops.details(ref);

  /// Chapters in reading order (first chapter first).
  Future<List<SourceChapter>> chapters(MangaRef ref) => _ops.chapters(ref);

  /// Full-size pages in reading order, each carrying the headers to fetch it.
  Future<List<PageRef>> pages(ChapterRef ref) => _ops.pages(ref);

  /// Filter groups for the filter sheet; may hit the network (builders cache).
  Future<List<FilterGroup>> filters() => _ops.filters();

  /// True when a real filters op was composed in (vs. the default no-op).
  bool get hasFilters => _ops.filters != _noFilters;

  /// Exact-match browse for one or more already-known tag values, e.g. an
  /// entry out of a manga's own [SourceManga.genres], tapped to see
  /// everything else carrying it. [included] are `AND`-ed; a source that
  /// can't express more than one, or can't express [excluded] at all, just
  /// ignores what it can't do; check [tagCapabilities] first. See
  /// [SourceConfig.tag].
  Future<CatalogPage> tag(
    Set<String> included,
    int page, {
    Set<String> excluded = const {},
  }) => _ops.tag(TagQuery(included: included, excluded: excluded, page: page));

  /// True when a real tag-browse op was composed in (vs. the default
  /// always-empty listing).
  bool get hasTagListing => _ops.tag != _noTagListing;

  /// What [tag] can actually express for this source; see [TagCapabilities].
  TagCapabilities get tagCapabilities => _ops.tagCapabilities;

  /// Headers for fetching a **cover** image at [url] (Referer + any Cloudflare
  /// clearance for that url's own host). Page images carry their own headers
  /// on each [PageRef]. Takes the url so clearance is never attached to a host
  /// other than the one it was actually solved for.
  Map<String, String> imageHeadersFor(String url) =>
      _imageHeaders?.call(url) ?? const {};

  /// Completes when the next direct image request may be sent (rate limiting).
  Future<void> throttle() => _throttle?.call() ?? Future.value();

  ClearanceStore? _clearance;
  ClearanceStore? get clearanceStore => _clearance;

  /// Wires a host's Cloudflare clearance into the source's transport after
  /// construction (the registry sets it; null in standalone use).
  set clearanceStore(ClearanceStore? store) {
    _clearance = store;
    _clearanceSink?.call(store);
  }

  LocalStoragePreferenceStore? _localStoragePreferences;
  LocalStoragePreferenceStore? get localStoragePreferenceStore =>
      _localStoragePreferences;

  /// Wires the app's consent-toggle overrides into the source's transport
  /// after construction, same pattern as [clearanceStore].
  set localStoragePreferenceStore(LocalStoragePreferenceStore? store) {
    _localStoragePreferences = store;
    _localStoragePreferenceSink?.call(store);
  }
}
