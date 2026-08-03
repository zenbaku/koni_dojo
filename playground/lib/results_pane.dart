// Right pane: the run outcome, stage by stage (popular/search grid, details,
// chapters, page previews), every item tappable to inspect the exact JSON the
// engine parsed, plus a rich pipeline step trace (per-step request, captured
// vars, and body, with a full-body viewer). Mirrors the app's Extension Lab.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:koni_dojo/koni_dojo.dart';

import 'json_view.dart';
import 'probe.dart';
import 'source_image.dart';

// ── Item → the JSON the engine actually parsed (for the inspect dialogs) ─────

String _pretty(Map<String, dynamic> data) =>
    const JsonEncoder.withIndent('  ').convert(data);

String _mangaJson(SourceManga m) => _pretty({
  'url': m.url,
  'title': m.title,
  'thumbnailUrl': m.thumbnailUrl,
  if (m.bannerUrl.isNotEmpty) 'bannerUrl': m.bannerUrl,
  if (m.backgroundUrl.isNotEmpty) 'backgroundUrl': m.backgroundUrl,
  'author': m.author,
  'status': m.status.name,
  'genres': m.genres,
  'description': m.description,
  if (m.unlistedChapterCount > 0)
    'unlistedChapterCount': m.unlistedChapterCount,
});

String _chapterJson(SourceChapter c) => _pretty({
  'url': c.url,
  'name': c.name,
  'number': c.number,
  'dateUpload': c.dateUpload?.toIso8601String(),
  'locked': c.locked,
  'official': c.official,
});

String _pageJson(PageRef p) =>
    _pretty({'url': p.url.toString(), 'headers': p.headers});

class ResultsPane extends StatelessWidget {
  const ResultsPane({
    super.key,
    required this.state,
    this.blur = false,
    this.onTargetPicked,
  });

  final ProbeState state;

  /// The NSFW screen-safety toggle; see [Workspace.blurNsfw].
  final bool blur;

  /// "Target this" on a Popular/Tag/Chapters result — see
  /// [_CoverStrip.onTargetPicked]/[_ChapterList.onTargetPicked]. Null when
  /// the caller has nothing to seed a picker with (no `SourceConfig`, or the
  /// picker isn't available on this platform).
  final void Function(String url, String label)? onTargetPicked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (state.phase) {
      case ProbePhase.idle:
        return Center(
          child: Text(
            'Pick a stage and hit Run, or Probe the full chain.\n\n'
            'The playground runs the real reader path against the live site:\n'
            'popular → details → chapters → pages.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        );
      case ProbePhase.running:
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text('Running ${state.ranStage.label.toLowerCase()}…'),
              ],
            ),
            const SizedBox(height: 16),
            // A Cloudflare wait can sit here with an empty trace (the fetch is
            // stuck in the WebView poll, not the pipeline engine): the log is
            // often the *only* live signal during that stretch.
            if (state.log.isNotEmpty) _LogCard(log: state.log),
            if (state.traces.isNotEmpty) _TraceCard(traces: state.traces),
            // Whatever's already resolved (popular, maybe details/chapters
            // too): a slow or challenged later stage no longer means
            // staring at just the log for however long that stage takes.
            const SizedBox(height: 12),
            ..._stageCards(state, blur: blur, onTargetPicked: onTargetPicked),
          ],
        );
      case ProbePhase.done:
        // A status seeded from the store (no live traces/results this session):
        // show its last-known status, not empty "not reached" stage cards.
        if (state.recordedAt != null && state.traces.isEmpty) {
          return _HistoryPlaceholder(state: state);
        }
        return _DoneView(
          state: state,
          blur: blur,
          onTargetPicked: onTargetPicked,
        );
    }
  }
}

/// Shown when the pane holds a status restored from the store rather than a
/// live run: the last-known outcome + a nudge to probe for live results.
class _HistoryPlaceholder extends StatelessWidget {
  const _HistoryPlaceholder({required this.state});

  final ProbeState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = state.passed;
    final color = ok ? Colors.green : theme.colorScheme.error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('Last probed', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              ok ? 'passed' : (state.label),
              style: theme.textTheme.titleMedium!.copyWith(color: color),
            ),
            if (state.elapsed != null)
              Text(
                '${state.elapsed!.inMilliseconds} ms',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            const SizedBox(height: 12),
            Text.rich(
              TextSpan(
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.outline,
                ),
                children: [
                  const TextSpan(
                    text: 'Run a probe for live results, or open history (',
                  ),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Icon(
                      Icons.history,
                      size: 13,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const TextSpan(
                    text: ') for the previous run\'s captured examples.',
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// The per-stage result cards (Popular/Details/Chapters/Pages), built from
/// whatever's already resolved in [state]: every field is read null-safely,
/// so this renders sensibly whether the run just finished (every reached
/// stage populated) or is still going (only the stages that have resolved
/// *so far*, via [probeSource]'s `onProgress`). Shared by [ResultsPane]'s
/// `running` case (so results appear as they land, not only once the whole
/// chain finishes: a slow/challenged later stage otherwise leaves nothing
/// but the Cloudflare log to look at) and [_DoneView].
List<Widget> _stageCards(
  ProbeState state, {
  bool blur = false,
  void Function(String url, String label)? onTargetPicked,
}) {
  final headers = state.imageHeaders ?? (_) => const <String, String>{};
  final full = state.ranStage == ProbeStage.full;
  final ran = state.ranStage;
  final isSearch = ran == ProbeStage.search;
  final isTag = ran == ProbeStage.tag;

  Widget? popularChild() {
    final items = state.popular;
    if (items == null || items.isEmpty) return null;
    return _CoverStrip(
      covers: [
        for (final m in items.take(16))
          (
            url: m.thumbnailUrl,
            label: m.title,
            json: _mangaJson(m),
            targetUrl: m.url,
          ),
      ],
      headers: headers,
      viaWebView: state.webview,
      warmImageByUrl: state.warmImageByUrl,
      warmImageViaImgTag: state.warmImageViaImgTag,
      baseUrl: state.sourceInfo?.baseUrl,
      throttle: state.throttle,
      blur: blur,
      onTargetPicked: onTargetPicked,
    );
  }

  return [
    if (full || ran == ProbeStage.popular || isSearch || isTag)
      _StageCard(
        title: isTag
            ? 'Tag results'
            : isSearch
            ? 'Search results'
            : 'Popular',
        summary: state.popular == null
            ? null
            : '${state.popular!.length} items',
        failed: state.failedStage == ran.name || state.failedStage == 'popular',
        child: popularChild(),
      ),
    if (full || ran == ProbeStage.details)
      _StageCard(
        title: 'Details',
        summary: state.details?.title,
        failed: state.failedStage == 'details',
        notReachedLabel: full && !state.detailsConfigured
            ? 'not configured yet'
            : 'not reached',
        trailing: state.details == null
            ? null
            : _InspectButton(
                title: 'Details · parsed',
                json: _mangaJson(state.details!),
              ),
        child: state.details == null
            ? null
            : _DetailsView(
                manga: state.details!,
                headers: headers,
                viaWebView: state.webview,
                warmImageByUrl: state.warmImageByUrl,
                warmImageViaImgTag: state.warmImageViaImgTag,
                baseUrl: state.sourceInfo?.baseUrl,
                throttle: state.throttle,
                blur: blur,
              ),
      ),
    if (full || ran == ProbeStage.chapters)
      _StageCard(
        title: 'Chapters',
        summary: state.chapters == null
            ? null
            : (state.details?.unlistedChapterCount ?? 0) > 0
            ? '${state.chapters!.length} chapters '
                  '(+${state.details!.unlistedChapterCount} not listed)'
            : '${state.chapters!.length} chapters',
        failed: state.failedStage == 'chapters',
        notReachedLabel: full && !state.chaptersConfigured
            ? 'not configured yet'
            : 'not reached',
        child: state.chapters == null || state.chapters!.isEmpty
            ? null
            : _ChapterList(
                chapters: state.chapters!,
                onTargetPicked: onTargetPicked,
              ),
      ),
    if (full || ran == ProbeStage.pages)
      _StageCard(
        title: full ? 'Pages (first chapter)' : 'Pages',
        summary: state.pages == null ? null : '${state.pages!.length} pages',
        failed: state.failedStage == 'pages',
        notReachedLabel:
            full && (!state.chaptersConfigured || !state.pagesConfigured)
            ? 'not configured yet'
            : 'not reached',
        child: state.pages == null || state.pages!.isEmpty
            ? null
            : _CoverStrip(
                covers: [
                  for (final (i, p) in state.pages!.indexed)
                    (
                      url: p.url.toString(),
                      label: 'p.${i + 1}',
                      json: _pageJson(p),
                      targetUrl: null, // a page image has nothing to target
                    ),
                ],
                headers: (url) {
                  final ref = state.pages!
                      .where((p) => p.url.toString() == url)
                      .firstOrNull;
                  return ref?.headers ?? headers(url);
                },
                viaWebView: state.webview,
                warmImageByUrl: state.warmImageByUrl,
                warmImageViaImgTag: state.warmImageViaImgTag,
                baseUrl: state.sourceInfo?.baseUrl,
                throttle: state.throttle,
                blur: blur,
              ),
      ),
    // Best-effort, full-chain only: a dedicated Tag-stage run already has
    // its own "Tag results" card above (the isTag branch); this is
    // specifically what "Full probe" tried when the source has a `tag`
    // listing. Never shown as failed: see ProbeState.tagTried's doc.
    if (full && state.tagTried != null)
      _StageCard(
        title: 'Tag probe',
        summary: state.tag == null
            ? 'tried "${state.tagTried}" — no results'
            : 'tried "${state.tagTried}" — ${state.tag!.length} items',
        failed: false,
        child: state.tag == null || state.tag!.isEmpty
            ? null
            : _CoverStrip(
                covers: [
                  for (final m in state.tag!.take(16))
                    (
                      url: m.thumbnailUrl,
                      label: m.title,
                      json: _mangaJson(m),
                      targetUrl: m.url,
                    ),
                ],
                headers: headers,
                viaWebView: state.webview,
                warmImageByUrl: state.warmImageByUrl,
                warmImageViaImgTag: state.warmImageViaImgTag,
                baseUrl: state.sourceInfo?.baseUrl,
                throttle: state.throttle,
                blur: blur,
                onTargetPicked: onTargetPicked,
              ),
      ),
  ];
}

class _DoneView extends StatelessWidget {
  const _DoneView({
    required this.state,
    this.blur = false,
    this.onTargetPicked,
  });

  final ProbeState state;
  final bool blur;
  final void Function(String url, String label)? onTargetPicked;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _VerdictBanner(state: state),
        // Right under the verdict: a Cloudflare failure's error message
        // alone ("re-challenged after a solve...") doesn't say *why*; this
        // does.
        if (state.log.isNotEmpty) _LogCard(log: state.log),
        const SizedBox(height: 12),
        ..._stageCards(state, blur: blur, onTargetPicked: onTargetPicked),
        if (state.traces.isNotEmpty) ...[
          const SizedBox(height: 4),
          _TraceCard(traces: state.traces),
        ],
      ],
    );
  }
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.state});

  final ProbeState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = state.sourceInfo;
    final elapsed = state.elapsed;
    final full = state.ranStage == ProbeStage.full;

    final (color, icon, text) = switch (state) {
      final s when s.runError != null => (
        theme.colorScheme.error,
        Icons.error_outline,
        s.runError!,
      ),
      final s when s.failedStage != null => (
        theme.colorScheme.error,
        Icons.cancel_outlined,
        'Failed at ${s.failedStage}: ${s.stageError}',
      ),
      _ => (
        Colors.green,
        Icons.check_circle_outline,
        full ? _fullPassSummary(state) : '${state.ranStage.label} ran.',
      ),
    };

    return Card(
      color: color.withValues(alpha: 0.12),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (info != null)
                    Text(
                      '${info.name} <${info.baseUrl}>'
                      '${elapsed == null ? '' : ' · ${elapsed.inMilliseconds} ms'}',
                      style: theme.textTheme.titleSmall,
                    ),
                  SelectableText(text),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The green banner's text for a passed full-chain run — reflects which
/// stages actually ran when `details`/`chapters`/`pages` were skipped as
/// unconfigured (see [ProbeState.detailsConfigured]/[chaptersConfigured]/
/// [pagesConfigured]). `details` and `chapters` are independent (either can
/// be skipped without affecting the other — `probeSource` reads
/// `chapters` from the same `MangaRef` `details` does, not from `details`'
/// own output), but `pages` isn't independent of `chapters`: an
/// unconfigured `chapters` means there's no resolved chapter to fetch pages
/// for, so `pages` never actually runs regardless of its own configured
/// flag (mirrors `probeSource`'s own early-return before ever checking
/// `pagesConfigured`) — a naive ladder that checked each flag in isolation
/// would wrongly credit `pages` as skipped-independently in that case.
String _fullPassSummary(ProbeState state) {
  final detailsRan = state.detailsConfigured;
  final chaptersRan = state.chaptersConfigured;
  final pagesRan = chaptersRan && state.pagesConfigured;
  if (detailsRan && chaptersRan && pagesRan) {
    return 'All four stages passed — popular → details → chapters → pages.';
  }
  final ran = [
    'Popular', // always the sentence's first word — popular never skips
    if (detailsRan) 'details',
    if (chaptersRan) 'chapters',
    if (pagesRan) 'pages',
  ];
  final skipped = [
    if (!detailsRan) 'details',
    if (!chaptersRan) 'chapters',
    if (!pagesRan) 'pages',
  ];
  return '${ran.join(' → ')} passed — ${skipped.join('/')} '
      '${skipped.length == 1 ? 'isn\'t' : 'aren\'t'} configured yet.';
}

class _StageCard extends StatelessWidget {
  const _StageCard({
    required this.title,
    required this.summary,
    required this.failed,
    this.child,
    this.trailing,
    this.notReachedLabel = 'not reached',
  });

  final String title;

  /// One-line result, or null when the run never reached this stage.
  final String? summary;
  final bool failed;
  final Widget? child;
  final Widget? trailing;

  /// Shown instead of the generic "not reached" when [summary] is null for a
  /// more specific reason (e.g. an unconfigured block a full-chain run
  /// deliberately skipped, vs. one an earlier stage's failure never let the
  /// chain reach). Same neutral icon/color either way — this only changes
  /// the label.
  final String notReachedLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reached = summary != null;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  failed
                      ? Icons.cancel
                      : reached
                      ? Icons.check_circle
                      : Icons.remove_circle_outline,
                  size: 16,
                  color: failed
                      ? theme.colorScheme.error
                      : reached
                      ? Colors.green
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  summary ?? notReachedLabel,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 4), trailing!],
              ],
            ),
            if (child != null) ...[const SizedBox(height: 10), child!],
          ],
        ),
      ),
    );
  }
}

/// A small "inspect the parsed JSON" icon button.
class _InspectButton extends StatelessWidget {
  const _InspectButton({required this.title, required this.json});

  final String title;
  final String json;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.data_object, size: 16),
    visualDensity: VisualDensity.compact,
    tooltip: 'Inspect parsed data',
    onPressed: () => showRawDataDialog(context, title: title, text: json),
  );
}

/// Horizontal strip of remote images (covers or page previews). Each tile
/// opens a full-size, swipeable [_ImageLightbox] to inspect the image itself;
/// the JSON the engine parsed for it is still reachable from inside the
/// lightbox.
class _CoverStrip extends StatelessWidget {
  const _CoverStrip({
    required this.covers,
    required this.headers,
    required this.viaWebView,
    this.warmImageByUrl = false,
    this.warmImageViaImgTag = false,
    this.baseUrl,
    this.throttle,
    this.blur = false,
    this.onTargetPicked,
  });

  final List<({String url, String label, String? json, String? targetUrl})>
  covers;
  final Map<String, String> Function(String url) headers;
  final bool viaWebView;
  final bool warmImageByUrl;
  final bool warmImageViaImgTag;
  final String? baseUrl;
  final Future<void> Function()? throttle;
  final bool blur;

  /// "Target this" — seeds the point-and-click picker's default URL for
  /// Details/Chapters (or, from a chapters result, Pages) from a real
  /// probed item instead of a guess. Only rendered for covers whose
  /// `targetUrl` is non-null (a manga item; not a raw page image, which has
  /// nothing to target) and when this itself is non-null (the caller
  /// doesn't always have a target — e.g. no `SourceConfig` to pick into).
  final void Function(String url, String label)? onTargetPicked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: covers.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final cover = covers[i];
          final canTarget = onTargetPicked != null && cover.targetUrl != null;
          return SizedBox(
            width: 84,
            child: InkWell(
              onTap: () => showDialog<void>(
                context: context,
                barrierColor: Colors.black87,
                builder: (_) => _ImageLightbox(
                  covers: covers,
                  initialIndex: i,
                  headers: headers,
                  viaWebView: viaWebView,
                  warmImageByUrl: warmImageByUrl,
                  warmImageViaImgTag: warmImageViaImgTag,
                  baseUrl: baseUrl,
                  throttle: throttle,
                  blur: blur,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SourceImage(
                            url: cover.url,
                            viaWebView: viaWebView,
                            headers: headers(cover.url),
                            warmImageByUrl: warmImageByUrl,
                            warmImageViaImgTag: warmImageViaImgTag,
                            baseUrl: baseUrl,
                            throttle: throttle,
                            width: 84,
                            blur: blur,
                          ),
                        ),
                        if (canTarget)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: Material(
                              color: Colors.black54,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => onTargetPicked!(
                                  cover.targetUrl!,
                                  cover.label,
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.ads_click,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Tooltip(
                    message: canTarget
                        ? '${cover.label} — tap the target icon to pick '
                              'selectors from this page'
                        : cover.label,
                    child: Text(
                      cover.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Full-screen, swipeable viewer over a [_CoverStrip]'s images: pinch/drag
/// to zoom each one, swipe to move to the next/previous, close to return to
/// the results pane. The parsed JSON for the current image sits alongside it
/// in a side panel, both visible at once, no extra tap to switch views.
class _ImageLightbox extends StatefulWidget {
  const _ImageLightbox({
    required this.covers,
    required this.initialIndex,
    required this.headers,
    required this.viaWebView,
    this.warmImageByUrl = false,
    this.warmImageViaImgTag = false,
    this.baseUrl,
    this.throttle,
    this.blur = false,
  });

  final List<({String url, String label, String? json, String? targetUrl})>
  covers;
  final int initialIndex;
  final Map<String, String> Function(String url) headers;
  final bool viaWebView;
  final bool warmImageByUrl;
  final bool warmImageViaImgTag;
  final String? baseUrl;
  final Future<void> Function()? throttle;
  final bool blur;

  @override
  State<_ImageLightbox> createState() => _ImageLightboxState();
}

class _ImageLightboxState extends State<_ImageLightbox> {
  static const _minScale = 1.0;
  static const _maxScale = 5.0;
  static const _step = 1.5;

  late final _pageController = PageController(initialPage: widget.initialIndex);
  final _transform = TransformationController();
  // Without this, the json panel's SingleChildScrollView falls back to
  // PrimaryScrollController, not reliably attached inside a Dialog's
  // overlay, throwing "no ScrollPosition attached" on the warm-up frame.
  final _jsonScrollController = ScrollController();
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    _transform.dispose();
    _jsonScrollController.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  void _zoomBy(double factor, {required Offset focalPoint}) {
    final next = (_scale * factor).clamp(_minScale, _maxScale);
    if (next == _minScale) {
      _transform.value = Matrix4.identity();
      return;
    }
    _transform.value = Matrix4.identity()
      ..translateByDouble(focalPoint.dx, focalPoint.dy, 0, 1)
      ..scaleByDouble(next, next, next, 1)
      ..translateByDouble(-focalPoint.dx, -focalPoint.dy, 0, 1);
  }

  void _resetZoom() => _transform.value = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = widget.covers[_index];
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final imageArea = LayoutBuilder(
      builder: (context, constraints) {
        final center = constraints.biggest.center(Offset.zero);
        return Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.covers.length,
              onPageChanged: (i) {
                _resetZoom();
                setState(() => _index = i);
              },
              itemBuilder: (context, i) {
                final c = widget.covers[i];
                return GestureDetector(
                  onDoubleTapDown: (d) => setState(() {
                    _scale > _minScale
                        ? _resetZoom()
                        : _zoomBy(2.5, focalPoint: d.localPosition);
                  }),
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: _minScale,
                    maxScale: _maxScale,
                    onInteractionUpdate: (_) => setState(() {}),
                    child: Center(
                      child: SourceImage(
                        url: c.url,
                        viaWebView: widget.viaWebView,
                        headers: widget.headers(c.url),
                        warmImageByUrl: widget.warmImageByUrl,
                        warmImageViaImgTag: widget.warmImageViaImgTag,
                        baseUrl: widget.baseUrl,
                        throttle: widget.throttle,
                        fit: BoxFit.contain,
                        blur: widget.blur,
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              right: 12,
              bottom: 12,
              child: _ZoomControls(
                scale: _scale,
                minScale: _minScale,
                maxScale: _maxScale,
                onZoomIn: () =>
                    setState(() => _zoomBy(_step, focalPoint: center)),
                onZoomOut: () =>
                    setState(() => _zoomBy(1 / _step, focalPoint: center)),
                onReset: () => setState(_resetZoom),
              ),
            ),
          ],
        );
      },
    );
    final jsonPanel = cover.json == null
        ? null
        : ColoredBox(
            color: theme.colorScheme.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Parsed data',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: cover.json!),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _jsonScrollController,
                    padding: const EdgeInsets.all(16),
                    child: JsonText(cover.json!),
                  ),
                ),
              ],
            ),
          );
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    '${cover.label}  ·  ${_index + 1} / '
                    '${widget.covers.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: jsonPanel == null
                ? imageArea
                : narrow
                ? Column(
                    children: [
                      Expanded(flex: 2, child: imageArea),
                      SizedBox(height: 260, child: jsonPanel),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: imageArea),
                      SizedBox(width: 380, child: jsonPanel),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Zoom in/out/reset affordance overlaid on the lightbox image: explicit
/// buttons rather than relying only on pinch/scroll gestures, which give no
/// visual hint that zooming is even possible.
class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.scale,
    required this.minScale,
    required this.maxScale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final double scale;
  final double minScale;
  final double maxScale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black54,
    borderRadius: BorderRadius.circular(24),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove, color: Colors.white),
          tooltip: 'Zoom out',
          onPressed: scale > minScale ? onZoomOut : null,
        ),
        InkWell(
          onTap: onReset,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${(scale * 100).round()}%',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, color: Colors.white),
          tooltip: 'Zoom in',
          onPressed: scale < maxScale ? onZoomIn : null,
        ),
      ],
    ),
  );
}

class _DetailsView extends StatelessWidget {
  const _DetailsView({
    required this.manga,
    required this.headers,
    required this.viaWebView,
    this.warmImageByUrl = false,
    this.warmImageViaImgTag = false,
    this.baseUrl,
    this.throttle,
    this.blur = false,
  });

  final SourceManga manga;
  final Map<String, String> Function(String url) headers;
  final bool viaWebView;
  final bool warmImageByUrl;
  final bool warmImageViaImgTag;
  final String? baseUrl;
  final Future<void> Function()? throttle;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // All three images share one lightbox (zoom, JSON panel), same
    // mechanism the Popular/Search cover strip uses, so each is tappable to
    // actually inspect, not just glance at inline.
    final images =
        <({String url, String label, String? json, String? targetUrl})>[
          if (manga.thumbnailUrl.isNotEmpty)
            (
              url: manga.thumbnailUrl,
              label: '${manga.title} · cover',
              json: _mangaJson(manga),
              targetUrl: null,
            ),
          if (manga.bannerUrl.isNotEmpty)
            (
              url: manga.bannerUrl,
              label: '${manga.title} · banner',
              json: _mangaJson(manga),
              targetUrl: null,
            ),
          if (manga.backgroundUrl.isNotEmpty)
            (
              url: manga.backgroundUrl,
              label: '${manga.title} · background',
              json: _mangaJson(manga),
              targetUrl: null,
            ),
        ];
    Widget tappableImage({
      required String url,
      double? width,
      double? height,
    }) => InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => showDialog<void>(
        context: context,
        barrierColor: Colors.black87,
        builder: (_) => _ImageLightbox(
          covers: images,
          initialIndex: images.indexWhere((i) => i.url == url),
          headers: headers,
          viaWebView: viaWebView,
          warmImageByUrl: warmImageByUrl,
          warmImageViaImgTag: warmImageViaImgTag,
          baseUrl: baseUrl,
          throttle: throttle,
          blur: blur,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SourceImage(
          url: url,
          viaWebView: viaWebView,
          headers: headers(url),
          warmImageByUrl: warmImageByUrl,
          warmImageViaImgTag: warmImageViaImgTag,
          baseUrl: baseUrl,
          throttle: throttle,
          width: width,
          height: height,
          fit: BoxFit.cover,
          blur: blur,
        ),
      ),
    );
    Widget labeledStrip(String label, IconData icon, String url) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: theme.colorScheme.outline),
              const SizedBox(width: 4),
              Text(label, style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 100,
            width: double.infinity,
            child: tappableImage(url: url, width: double.infinity, height: 100),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (manga.bannerUrl.isNotEmpty)
          labeledStrip('Banner', Icons.panorama_outlined, manga.bannerUrl),
        if (manga.backgroundUrl.isNotEmpty)
          labeledStrip(
            'Background',
            Icons.gradient_outlined,
            manga.backgroundUrl,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (manga.thumbnailUrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: tappableImage(
                  url: manga.thumbnailUrl,
                  width: 96,
                  height: 136,
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    manga.title,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (manga.author.isNotEmpty) manga.author,
                      manga.status.name,
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (manga.genres.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in manga.genres)
                          Chip(
                            label: Text(g),
                            labelStyle: theme.textTheme.bodySmall,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                  ],
                  if (manga.description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      manga.description,
                      maxLines: 6,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChapterList extends StatefulWidget {
  const _ChapterList({required this.chapters, this.onTargetPicked});

  final List<SourceChapter> chapters;

  /// "Target this" — seeds the picker's default URL for `pages` from a real
  /// probed chapter. See [_CoverStrip.onTargetPicked].
  final void Function(String url, String label)? onTargetPicked;

  @override
  State<_ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<_ChapterList> {
  static const _collapsedCount = 8;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapters = widget.chapters;
    final shown = _expanded
        ? chapters
        : chapters.take(_collapsedCount).toList();
    final lockedCount = chapters.where((c) => c.locked).length;
    final officialCount = chapters.where((c) => c.official).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lockedCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '$lockedCount of ${chapters.length} locked',
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        if (officialCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '$officialCount of ${chapters.length} official',
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        for (final c in shown)
          InkWell(
            onTap: () => showRawDataDialog(
              context,
              title: '${c.name} · parsed',
              text: _chapterJson(c),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  if (c.locked) ...[
                    Icon(
                      Icons.lock_outline,
                      size: 13,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (c.official) ...[
                    Tooltip(
                      message: 'Official (licensed) translation',
                      child: Icon(
                        Icons.verified,
                        size: 13,
                        color: Colors.deepPurple.shade300,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: c.locked
                          ? TextStyle(color: theme.colorScheme.outline)
                          : null,
                    ),
                  ),
                  Text(
                    c.dateUpload == null
                        ? ''
                        : c.dateUpload!.toIso8601String().substring(0, 10),
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  if (widget.onTargetPicked != null) ...[
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () => widget.onTargetPicked!(c.url, c.name),
                      child: Tooltip(
                        message: 'Target this chapter for the Pages picker',
                        child: Icon(
                          Icons.ads_click,
                          size: 13,
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Icon(
                    Icons.data_object,
                    size: 13,
                    color: theme.colorScheme.outlineVariant,
                  ),
                ],
              ),
            ),
          ),
        if (chapters.length > _collapsedCount)
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _expanded
                    ? 'Show fewer'
                    : '… ${chapters.length - shown.length} more '
                          '(show all ${chapters.length})',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Cloudflare solver log ────────────────────────────────────────────────────

/// Raw diagnostic lines from the Cloudflare solver / WebView fetcher (see
/// `cfLog` in `cloudflare.dart`): the console-only breadcrumbs from
/// diagnosing a stuck/false-positive solve, now surfaced here so the next one
/// doesn't need a terminal open. Empty (and hidden) for any run that never
/// hit a challenge.
class _LogCard extends StatefulWidget {
  const _LogCard({required this.log});

  final List<String> log;

  @override
  State<_LogCard> createState() => _LogCardState();
}

class _LogCardState extends State<_LogCard> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text(
                  'Cloudflare solver log · ${widget.log.length} lines',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.all(8),
              child: Scrollbar(
                controller: _scrollController,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: SelectableText(
                    widget.log.join('\n'),
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Consolas'],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

// ── Step trace ───────────────────────────────────────────────────────────────

class _TraceCard extends StatelessWidget {
  const _TraceCard({required this.traces});

  final List<StepTrace> traces;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Step trace · ${traces.length} steps',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            for (final t in traces) _TraceTile(trace: t),
          ],
        ),
      ),
    );
  }
}

class _TraceTile extends StatefulWidget {
  const _TraceTile({required this.trace});

  final StepTrace trace;

  @override
  State<_TraceTile> createState() => _TraceTileState();
}

class _TraceTileState extends State<_TraceTile> {
  // Same fix as _RawDataDialog/_ImageLightbox: an unguarded
  // SingleChildScrollView falls back to PrimaryScrollController, which a
  // widget this deeply nested (Card > ExpansionTile > Container) can't
  // reliably share with the page's own outer scrollable.
  final _bodyScrollController = ScrollController();

  @override
  void dispose() {
    _bodyScrollController.dispose();
    super.dispose();
  }

  Color _methodColor(String method) => switch (method.toUpperCase()) {
    'POST' => Colors.orange,
    'PUT' || 'PATCH' => Colors.purple,
    'DELETE' => Colors.red,
    _ => Colors.green,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = widget.trace;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        leading: CircleAvatar(
          radius: 13,
          backgroundColor: t.terminal
              ? scheme.primaryContainer
              : scheme.surfaceContainerHigh,
          child: Text(
            '${t.index}',
            style: theme.textTheme.labelSmall!.copyWith(
              color: t.terminal
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
        title: Row(
          children: [
            if (t.requestUrl != null) ...[
              _tag(t.method, _methodColor(t.method)),
              const SizedBox(width: 6),
            ],
            if (t.terminal) ...[
              _tag('yield', scheme.primary),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                t.requestUrl ?? '(reuses prior body)',
                style: kMono.copyWith(fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: t.captured.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final e in t.captured.entries)
                      _tag('${e.key}=${e.value}', scheme.tertiary),
                  ],
                ),
              ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              controller: _bodyScrollController,
              child: t.bodyPreview.isEmpty
                  ? Text(
                      '(empty)',
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    )
                  : JsonText(
                      t.bodyPreview,
                      highlight: looksJson(t.bodyPreview),
                      fontSize: 10.5,
                    ),
            ),
          ),
          if (t.body.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_full, size: 15),
                label: const Text('View full body'),
                onPressed: () => showRawDataDialog(
                  context,
                  title: 'Step ${t.index} · body',
                  text: t.body,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
    ),
  );
}
