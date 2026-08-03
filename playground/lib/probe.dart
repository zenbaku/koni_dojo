// Live-probe plumbing: per-row probe state, the full-chain runner (`runProbe`,
// driving the shared `probeSource`), and a single-stage runner (`runStage`) for
// exercising one operation with a custom input: the Extension Lab's "try a
// stage with different parameters" affordance.
import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:koni_dojo/koni_dojo.dart';

import 'cloudflare.dart';
import 'consent.dart';
import 'js.dart';

enum ProbePhase { idle, running, done }

/// A single operation that can be run on its own, plus the full smoke chain.
enum ProbeStage {
  full('Full probe', ''),
  popular('Popular', 'page #'),
  search('Search', 'query'),
  tag('Tag', 'tag (comma for multiple)'),
  details('Details', 'manga url / id'),
  chapters('Chapters', 'manga url / id'),
  pages('Pages', 'chapter url / id');

  const ProbeStage(this.label, this.inputHint);

  final String label;

  /// Placeholder for this stage's primary input field.
  final String inputHint;
}

/// Pulls the one source object out of whatever shape was given: a full
/// extension file (`{..., "sources": [...]}`), a repo index (list of those),
/// or a bare source config, the same tolerance `tool/live_probe.dart` has.
AnySourceConfig parseConfig(String text) {
  final json = jsonDecode(text);
  final entry = json is List ? json.first : json;
  final source = (entry is Map && entry.containsKey('sources'))
      ? (entry['sources'] as List).first
      : entry;
  return AnySourceConfig.fromJson((source as Map).cast<String, dynamic>());
}

/// The `tag` listing's param wiring plus the source's declared `filters`,
/// pulled out of either dialect config, so the Tag stage can tell whether
/// any filter group's *own* param happens to be the exact one `tag` reads
/// (confirmed live: one real source's `tag.tagParam` and its "tags" filter
/// group's `param` are both `included_tag`: same underlying query
/// parameter, so that group's already-known options are valid values to
/// browse by, not a guess).
typedef _TagWiring = ({
  String tagParam,
  String tagExcludeParam,
  List<FilterConfig> filters,
});

_TagWiring? _tagWiring(AnySourceConfig config) => switch (config) {
  SourceConfig(:final tag?, :final filters) => (
    tagParam: tag.tagParam,
    tagExcludeParam: tag.tagExcludeParam,
    filters: filters,
  ),
  ApiSourceConfig(:final tag?, :final filters) => (
    tagParam: tag.tagParam,
    tagExcludeParam: tag.tagExcludeParam,
    filters: filters,
  ),
  _ => null,
};

/// The filter group(s) whose `param` matches the `tag` listing's own
/// `tagParam`; see [_TagWiring]. Empty when `tag` only browses one value
/// at a time (no `tagParam` configured, nothing to match) or no filter
/// group happens to share it.
List<FilterConfig> tagRelevantFilters(AnySourceConfig config) {
  final wiring = _tagWiring(config);
  if (wiring == null || wiring.tagParam.isEmpty) return const [];
  return [
    for (final f in wiring.filters)
      if (f.param == wiring.tagParam) f,
  ];
}

/// Builds a throwaway [Source] for [configText] and loads every declared
/// filter group (`source.filters()`): the Search stage's picker (query +
/// filters combine, unlike Tag's picker which replaces free text). Empty
/// when the source declares none. Non-Cloudflare-guarded (unlike
/// [runStage]/[runProbe]): a group backed by `optionsFrom` on a
/// Cloudflare-hard host may fail here, in which case the caller falls back
/// to no filters rather than blocking on a challenge solve.
Future<List<FilterGroup>> loadFilterGroups(String configText) async {
  final config = parseConfig(configText);
  final client = http.Client();
  try {
    final source = switch (config) {
      ApiSourceConfig c => apiSource(c, client: client),
      SourceConfig c => htmlSource(
        c,
        client: client,
        jsRunner: playgroundJsRunner,
      ),
    };
    // A clearance already solved earlier this session (e.g. running Popular
    // first) lets a Cloudflare-gated optionsFrom fetch succeed here too,
    // without this simplified path needing its own guard/solve flow.
    source.clearanceStore = playgroundClearance;
    if (!source.hasFilters) return const [];
    return await source.filters();
  } finally {
    client.close();
  }
}

/// [loadFilterGroups] narrowed to the group(s) matching [tagRelevantFilters]:
/// the known-option picker the Tag stage shows instead of a blind
/// free-text field, when the source has one.
Future<List<FilterGroup>> loadTagFilterGroups(String configText) async {
  final relevant = tagRelevantFilters(parseConfig(configText));
  if (relevant.isEmpty) return const [];
  final relevantIds = relevant.map((f) => f.id).toSet();
  final all = await loadFilterGroups(configText);
  return [
    for (final g in all)
      if (relevantIds.contains(g.id) ||
          relevantIds.contains(g.id.split(':').first))
        g,
  ];
}

/// A plain-fetch/WebView-render mismatch worth surfacing — see
/// [diagnoseWebviewNeed].
typedef WebviewSuggestion = ({String reason});

/// Fetches [url] two ways — a plain HTTP GET and a real WebView render
/// (waits for client-side JS to settle, the exact same path
/// `SourceConfig.webview: true` sources use in production, see
/// `_HtmlEngine._fetchBody` in `config_source.dart`) — and compares them
/// for a mismatch worth flagging *before* anyone starts hand-picking
/// selectors against the wrong one. Two signals, either enough on its own:
/// the plain fetch failing outright (many JS-hydrated/Cloudflare-gated
/// sites do exactly this), or the WebView-rendered document having
/// substantially more elements than the static one — a selector-agnostic
/// proxy for "this page's real content only exists after JS runs", usable
/// before any selector has been picked at all. Null when they look
/// comparable, when the WebView side itself fails (nothing to compare
/// against), or when this platform can't drive a WebView at all
/// ([cloudflareSolveSupported]).
Future<WebviewSuggestion?> diagnoseWebviewNeed(Uri url) async {
  final fetcher = playgroundWebViewFetcher();
  if (!cloudflareSolveSupported || fetcher == null) return null;

  String? plainHtml;
  try {
    // Matches _HtmlEngine._fetchBody's own default request as closely as
    // possible without a real SourceConfig to draw from yet (this runs
    // before one exists) — a bare Dart HTTP client with no headers at all
    // gets blocked by sites that would happily serve the engine's own
    // plain-fetch path, which would otherwise read as a false "needs
    // webview" signal.
    final response = await http
        .get(
          url,
          headers: {
            'User-Agent': 'Mozilla/5.0 (Konimanga)',
            ...playgroundClearance.headersFor(url.toString()),
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      plainHtml = response.body;
    }
  } catch (_) {
    // Falls through with plainHtml still null — see doc comment above.
  }

  String webviewHtml;
  try {
    webviewHtml = await fetcher.fetchHtml(url.toString());
  } catch (_) {
    return null;
  }

  if (plainHtml == null) {
    return (
      reason:
          'The plain fetch failed, but the browser loaded the page fine — '
          'this site likely needs "webview: true".',
    );
  }

  final comparison = compareRenderedElementCounts(plainHtml, webviewHtml);
  if (!comparison.looksHydrated) return null;
  return (
    reason:
        'The browser rendered ${comparison.webviewCount} elements here; '
        'the plain fetch only saw ${comparison.plainCount} — this site '
        'likely needs "webview: true" to scrape correctly.',
  );
}

/// The element-count comparison [diagnoseWebviewNeed] flags a suggestion
/// on — pulled out as its own pure function (no network/WebView involved)
/// so this part is unit-testable directly.
typedef ElementCountComparison = ({
  int plainCount,
  int webviewCount,
  bool looksHydrated,
});

/// Does [webviewHtml] look substantially more rendered than [plainHtml]?
/// Both an absolute and a relative margin over [plainHtml]'s own count:
/// catches a mostly-empty skeleton (a very small plain count) without
/// flagging noise on pages that just vary a little between two fetches.
ElementCountComparison compareRenderedElementCounts(
  String plainHtml,
  String webviewHtml,
) {
  final plainCount = html_parser.parse(plainHtml).querySelectorAll('*').length;
  final webviewCount = html_parser
      .parse(webviewHtml)
      .querySelectorAll('*')
      .length;
  return (
    plainCount: plainCount,
    webviewCount: webviewCount,
    looksHydrated:
        webviewCount > plainCount + 30 && webviewCount > plainCount * 1.5,
  );
}

/// The outcome of (or progress through) one run: either a full probe or a
/// single stage. Plain state; owners re-render via the `onUpdate` callback.
class ProbeState {
  ProbePhase phase = ProbePhase.idle;

  /// Which run produced the current state (full chain or a single stage).
  ProbeStage ranStage = ProbeStage.full;

  /// Set when the run failed before reaching the site (bad JSON, unbuildable
  /// config, an uncleared Cloudflare wall).
  String? runError;

  /// The stage the run stopped at (`'popular'`/…), or null when everything it
  /// attempted resolved. For a single-stage run this is the stage's own name
  /// on failure.
  String? failedStage;
  Object? stageError;

  // Individual stage outputs, populated by whichever run touched them.
  List<SourceManga>? popular;
  SourceManga? details;
  List<SourceChapter>? chapters;
  List<PageRef>? pages;

  /// Set by a full-chain run when the source has a `tag` listing; see
  /// [SourceProbeResult.tagTried]/[tag]. Best-effort: [tag] staying null
  /// while [tagTried] is set means the tag browse itself failed, not that
  /// the whole run did; it never sets [failedStage].
  String? tagTried;
  List<SourceManga>? tag;

  final List<StepTrace> traces = [];

  /// Cloudflare solver/WebView-fetcher diagnostic lines emitted during this
  /// run (via `cfLog` in `cloudflare.dart`), empty for a run that never hit
  /// a challenge. Surfaces in the UI what used to be terminal-only, so a
  /// stuck/false-positive solve is diagnosable from the Extension Lab itself.
  final List<String> log = [];

  Duration? elapsed;

  /// Info + image-header resolver of the last probed source, for rendering
  /// covers/pages with the referer the engine would have sent.
  SourceInfo? sourceInfo;
  Map<String, String> Function(String url)? imageHeaders;

  /// Whether the probed source is `webview: true`. Its images are usually
  /// behind the same Cloudflare wall as its pages, so previews must be
  /// fetched through the WebView (see `SourceImage`) rather than a plain
  /// `Image.network`.
  bool webview = false;

  /// Mirrors `SourceConfig.warmImageByUrl`; see `SourceImage`/
  /// `WebViewFetcher.fetchBytes`'s `warmByUrl` param.
  bool warmImageByUrl = false;

  /// Mirrors `SourceConfig.warmImageViaImgTag`; see `SourceImage`/
  /// `WebViewFetcher.fetchBytes`'s `viaImgTag` param. Takes precedence over
  /// [warmImageByUrl] when both are true.
  bool warmImageViaImgTag = false;

  /// Whether `details`/`chapters`/`pages` have a real extraction configured
  /// (a non-empty key selector, or an explicit `steps`/`script` escape
  /// hatch) — vs. a brand-new prototype's still-blank `{}` placeholder
  /// block, the shape `_scaffoldConfigFromUrl` (table_screen.dart) writes. A
  /// full-chain run passes these into [probeSource] so it skips the stage
  /// rather than attempting a doomed (chapters/pages) or misleadingly
  /// blank-but-"successful" (details) extraction; see [probeSource]'s
  /// `detailsConfigured`/`chaptersConfigured`/`pagesConfigured` params. All
  /// three default true so a fully-authored source's behavior is unchanged.
  bool detailsConfigured = true;
  bool chaptersConfigured = true;
  bool pagesConfigured = true;

  /// The probed source's own [Source.throttle]: its `rateLimit` config,
  /// already queued/paced. `SourceImage`'s WebView cover fetches call this
  /// before each fetch so they're paced the same as the scraping requests
  /// (popular/details/chapters/pages/tag) instead of firing an unthrottled
  /// burst as soon as a stage's results render live. Safe to keep calling
  /// after the run's own `http.Client` closes: the rate limiter tracks only
  /// timestamps, independent of the client.
  Future<void> Function()? throttle;

  /// Set when this state was reconstructed from the persisted store (a prior
  /// session's run) rather than probed live this session, lets the UI mark it
  /// as history. Null for a live run.
  DateTime? recordedAt;

  bool get passed =>
      phase == ProbePhase.done && runError == null && failedStage == null;
  bool get failed =>
      phase == ProbePhase.done && (runError != null || failedStage != null);

  void _reset(ProbeStage stage) {
    phase = ProbePhase.running;
    ranStage = stage;
    runError = null;
    failedStage = null;
    stageError = null;
    popular = null;
    details = null;
    chapters = null;
    pages = null;
    detailsConfigured = true;
    chaptersConfigured = true;
    pagesConfigured = true;
    tagTried = null;
    tag = null;
    elapsed = null;
    recordedAt = null;
    traces.clear();
    log.clear();
  }

  /// One-word-ish label for table cells: '', 'probing…', 'pass', 'fail@pages',
  /// 'error'.
  String get label => switch (phase) {
    ProbePhase.idle => '',
    ProbePhase.running => 'probing…',
    ProbePhase.done when runError != null => 'error',
    ProbePhase.done when failedStage != null => 'fail@$failedStage',
    ProbePhase.done => 'pass',
  };
}

/// Whether [config]'s `popular` block has a real extraction — a non-empty
/// `itemSelector`, or an explicit `steps` escape hatch — vs. a brand-new
/// prototype's still-blank `{}` placeholder (the shape
/// `_scaffoldConfigFromUrl` in table_screen.dart writes). Unlike
/// [detailsConfigured]/[chaptersConfigured]/[pagesConfigured], nothing in
/// `probeSource` skips on this one (`popular` failing is always a real,
/// loud failure — there's nothing to probe at all without it) — this
/// exists for callers that need to know "has anyone started configuring
/// this source yet at all", e.g. `DetailScreen`'s webview-need diagnostic,
/// which only makes sense to run before that point.
bool popularConfigured(AnySourceConfig config) =>
    config is! SourceConfig ||
    config.popular.itemSelector.isNotEmpty ||
    config.popular.steps != null;

/// Whether [config]'s `details` block has a real extraction — a non-empty
/// `titleSelector`, or an explicit `rows`/`steps` escape hatch — vs. a
/// brand-new prototype's still-blank `{}` placeholder (the shape
/// `_scaffoldConfigFromUrl` in table_screen.dart writes). Unlike
/// chapters/pages, an unconfigured details block doesn't throw when
/// attempted (a blank selector just extracts ''), it just produces a
/// misleadingly "successful" all-blank/`unknown` manga — still worth
/// skipping. API-dialect sources are never scaffolded blank, so there's
/// nothing to detect there — always true.
bool detailsConfigured(AnySourceConfig config) =>
    config is! SourceConfig ||
    config.details.titleSelector.isNotEmpty ||
    config.details.rows != null ||
    config.details.steps != null;

/// Whether [config]'s `chapters` block has a real extraction — a non-empty
/// `itemSelector`, or an explicit `steps` escape hatch — vs. a brand-new
/// prototype's still-blank `{}` placeholder (the shape
/// `_scaffoldConfigFromUrl` in table_screen.dart writes). API-dialect
/// sources are never scaffolded blank (no "New source from URL" flow for
/// them today), so there's nothing to detect there — always true.
bool chaptersConfigured(AnySourceConfig config) =>
    config is! SourceConfig ||
    config.chapters.itemSelector.isNotEmpty ||
    config.chapters.steps != null;

/// [chaptersConfigured]'s counterpart for `pages` (`imageSelector`, or a
/// `script`/`steps` escape hatch).
bool pagesConfigured(AnySourceConfig config) =>
    config is! SourceConfig ||
    config.pages.imageSelector.isNotEmpty ||
    config.pages.script != null ||
    config.pages.steps != null;

/// Builds the `Source` for [configText], wiring the WebView fetcher (webview
/// sources) and the shared clearance store. Returns null after setting
/// [state.runError] when the config doesn't parse. Caller owns [client].
Source? _buildSource(ProbeState state, String configText, http.Client client) {
  try {
    final config = parseConfig(configText);
    state.webview = config is SourceConfig && config.webview;
    state.warmImageByUrl = config is SourceConfig && config.warmImageByUrl;
    state.warmImageViaImgTag =
        config is SourceConfig && config.warmImageViaImgTag;
    state.detailsConfigured = detailsConfigured(config);
    state.chaptersConfigured = chaptersConfigured(config);
    state.pagesConfigured = pagesConfigured(config);
    final source = switch (config) {
      ApiSourceConfig c => apiSource(c, client: client),
      SourceConfig c => htmlSource(
        c,
        client: client,
        webViewFetcher: playgroundWebViewFetcher(),
        jsRunner: playgroundJsRunner,
      ),
    };
    source.clearanceStore = playgroundClearance; // replay per-host clearances
    source.localStoragePreferenceStore = playgroundConsent;
    state.sourceInfo = source.info;
    state.imageHeaders = source.imageHeadersFor;
    state.throttle = source.throttle;
    return source;
  } catch (e) {
    state.runError = 'Config didn\'t parse: $e';
    return null;
  }
}

/// Runs [body] under a trace sink, a Cloudflare-diagnostic log sink, and the
/// solve-and-retry guard, timing it into [state]. [onChallenge] clears a
/// challenge and returns whether to retry (the `guardCloudflare` pattern).
Future<void> _guarded(
  ProbeState state,
  Future<void> Function() body, {
  void Function()? onUpdate,
  Future<bool> Function(Uri url)? onChallenge,
}) async {
  final started = DateTime.now();
  Future<void> traced() => runWithTrace((t) {
    state.traces.add(t);
    onUpdate?.call(); // live step feed while running
  }, body);
  // Wraps the whole guard, not just `traced()`: `onChallenge` (the solver)
  // runs *between* the two `traced()` calls and needs the same ambient sink,
  // and Zone values nest cleanly, so `runWithTrace` inside this still sees
  // both.
  await runWithCfLog(
    (line) {
      state.log.add(line);
      onUpdate?.call();
    },
    () async {
      try {
        try {
          await traced();
        } on CloudflareChallengeException catch (e) {
          cfLog(
            'CF _guarded: first attempt hit ${e.host}, calling onChallenge',
          );
          final solved = onChallenge != null && await onChallenge(e.url);
          cfLog('CF _guarded: onChallenge(${e.host}) -> $solved');
          if (solved) {
            state.traces.clear(); // the retry re-emits the whole trace
            cfLog('CF _guarded: starting retry after solve');
            await traced();
            cfLog('CF _guarded: retry after solve succeeded');
          } else {
            state.runError = _challengeMessage(e);
          }
        }
      } on CloudflareChallengeException catch (e) {
        cfLog('CF _guarded: retry after solve ALSO threw for ${e.host}');
        state.runError =
            '${e.host} re-challenged after a solve — the clearance didn\'t take '
            '(it may be IP- or fingerprint-bound). Try `"webview": true` on the '
            'source so every request goes through the WebView.';
      } catch (e) {
        state.runError = '$e';
      }
    },
  );
  state.elapsed = DateTime.now().difference(started);
}

/// Full reader chain: popular → details → chapters → pages. [onDone] fires once
/// the run reaches a probed result (a source built), the hook the caller uses
/// to persist the run.
Future<void> runProbe(
  ProbeState state,
  String configText, {
  void Function()? onUpdate,
  Future<bool> Function(Uri url)? onChallenge,
  void Function(ProbeState state)? onDone,
}) async {
  if (state.phase == ProbePhase.running) return;
  state._reset(ProbeStage.full);
  onUpdate?.call();
  await ensureClearanceLoaded();

  final client = http.Client();
  final source = _buildSource(state, configText, client);
  if (source == null) {
    client.close();
    state.phase = ProbePhase.done;
    onUpdate?.call();
    return;
  }

  await _guarded(
    state,
    () async {
      final result = await probeSource(
        source,
        detailsConfigured: state.detailsConfigured,
        chaptersConfigured: state.chaptersConfigured,
        pagesConfigured: state.pagesConfigured,
        // Render each stage's result as soon as it lands rather than only
        // once the whole chain finishes: a slow/challenged later stage
        // (chapters, pages) otherwise leaves the UI showing nothing but the
        // Cloudflare log for however long that stage takes, even though
        // popular/details already resolved minutes ago.
        onProgress: (partial) {
          state.popular = partial.popular;
          state.details = partial.details;
          state.chapters = partial.chapters;
          state.pages = partial.pages;
          state.tagTried = partial.tagTried;
          state.tag = partial.tag;
          onUpdate?.call();
        },
      );
      state.popular = result.popular;
      state.details = result.details;
      state.chapters = result.chapters;
      state.pages = result.pages;
      state.tagTried = result.tagTried;
      state.tag = result.tag;
      state.failedStage = result.failedStage;
      state.stageError = result.error;
    },
    onUpdate: onUpdate,
    onChallenge: onChallenge,
  );

  client.close();
  state.phase = ProbePhase.done;
  onUpdate?.call();
  onDone?.call(state);
}

/// Runs one [stage] in isolation against [input] (page number, search query, or
/// a manga/chapter url-or-id, per the stage). Only that stage's output field is
/// populated, so a developer can iterate on one operation without re-running
/// the whole chain.
Future<void> runStage(
  ProbeState state,
  String configText,
  ProbeStage stage, {
  String input = '',
  int page = 1,
  Set<String> excludedTags = const {},
  FilterSelection? filters,
  void Function()? onUpdate,
  Future<bool> Function(Uri url)? onChallenge,
  void Function(ProbeState state)? onDone,
}) async {
  if (stage == ProbeStage.full) {
    return runProbe(
      state,
      configText,
      onUpdate: onUpdate,
      onChallenge: onChallenge,
      onDone: onDone,
    );
  }
  if (state.phase == ProbePhase.running) return;
  state._reset(stage);
  onUpdate?.call();
  await ensureClearanceLoaded();

  final client = http.Client();
  final source = _buildSource(state, configText, client);
  if (source == null) {
    client.close();
    state.phase = ProbePhase.done;
    onUpdate?.call();
    return;
  }

  await _guarded(
    state,
    () async {
      try {
        switch (stage) {
          case ProbeStage.popular:
            state.popular = (await source.popular(page)).items;
          case ProbeStage.search:
            state.popular = (await source.search(
              input,
              page,
              filters: filters,
            )).items;
          case ProbeStage.tag:
            final included = {
              for (final t in input.split(','))
                if (t.trim().isNotEmpty) t.trim(),
            };
            state.popular = (await source.tag(
              included,
              page,
              excluded: excludedTags,
            )).items;
          case ProbeStage.details:
            state.details = await source.details(MangaRef(input));
          case ProbeStage.chapters:
            state.chapters = await source.chapters(MangaRef(input));
          case ProbeStage.pages:
            state.pages = await source.pages(ChapterRef(input));
          case ProbeStage.full:
            break; // handled above
        }
      } on CloudflareChallengeException {
        rethrow; // let the guard solve + retry
      } catch (e) {
        state.failedStage = stage.name;
        state.stageError = e;
      }
    },
    onUpdate: onUpdate,
    onChallenge: onChallenge,
  );

  client.close();
  state.phase = ProbePhase.done;
  onUpdate?.call();
  onDone?.call(state);
}

String _challengeMessage(CloudflareChallengeException e) =>
    cloudflareSolveSupported
    ? '${e.host} is behind a Cloudflare challenge and it wasn\'t cleared '
          '(cancelled, or the headless attempt timed out). Probe from the '
          'row detail screen to get the interactive solver window.'
    : '${e.host} is behind a Cloudflare challenge. The WebView solver '
          'needs WKWebView (macOS); on this platform the source can only '
          'be probed from the app\'s Extension Lab.';
