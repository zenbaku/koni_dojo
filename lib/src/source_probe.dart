import 'cloudflare_challenge.dart';
import 'source.dart';

/// Result of running the full reader path (popular -> details -> chapters ->
/// pages, plus a best-effort tag-browse, see [tagTried]/[tag]) against a
/// live [Source], the smoke test [probeSource] drives. Populated
/// progressively: a stage that never ran stays null, so a failure partway
/// through still reports everything resolved before it.
class SourceProbeResult {
  const SourceProbeResult({
    this.popular,
    this.details,
    this.chapters,
    this.pages,
    this.tagTried,
    this.tag,
    this.failedStage,
    this.error,
  });

  final List<SourceManga>? popular;
  final SourceManga? details;
  final List<SourceChapter>? chapters;
  final List<PageRef>? pages;

  /// The tag value [probeSource] actually tried browsing by, a genre
  /// [details] carries if it has any, else the first option of the
  /// source's own first declared filter group. Null when the source has
  /// no [Source.hasTagListing], or when neither of those yielded anything
  /// to try.
  final String? tagTried;

  /// Result of browsing by [tagTried], when attempted. Best-effort: unlike
  /// every other stage, a failure here never sets [failedStage]; tag
  /// browsing is optional per source, and [tagTried] is itself a guess
  /// (particularly the filter-group fallback), not a guaranteed-valid
  /// value the way a chapter/page ref resolved earlier in the chain is.
  final List<SourceManga>? tag;

  /// Which stage stopped the probe (`'popular'`/`'details'`/`'chapters'`/
  /// `'pages'`), or null when every stage produced results.
  final String? failedStage;

  /// The failure reason, set alongside [failedStage].
  final Object? error;

  bool get passed => failedStage == null;
}

/// How many `popular` candidates the chapters stage will try before giving
/// up (see [probeSource]'s doc comment).
const maxMangaCandidates = 5;

/// Runs the full reader pipeline of [source] against its live site: fetch
/// [page] of popular, then feed a result into details/chapters, then resolve
/// pages, the same chain a reader actually drives. The one smoke test both
/// the `live_probe` CLI tool and the Extension Lab's "Full probe" action
/// share, so a config is checked identically from a terminal or the app.
///
/// The chapters stage tries up to [maxMangaCandidates] items from `popular`,
/// in order, keeping the first whose chapter list isn't empty: "popular"
/// ranks by follows/rating, not by "has translated chapters", so the very
/// first result occasionally turns out to be an announced/licensed series
/// with nothing released yet in the requested language (seen live on a real
/// source); a single empty result there doesn't mean the chapters path is
/// broken, just that this particular pick was a dud.
///
/// The pages stage samples the first, middle, and last chapters until one
/// yields pages: a first chapter is often an image-less prologue, or otherwise
/// not served, so a single empty result doesn't prove the page path is
/// broken.
///
/// When [Source.hasTagListing], also tries browsing by one tag, a genre
/// [details] actually carries when it has any (a real, guaranteed-valid
/// value), else the source's own first declared filter option (a guess).
/// Runs right after details/chapters resolve, independent of whether
/// chapters/pages go on to succeed. Unlike every other stage this is pure
/// best-effort: a failure here never sets [SourceProbeResult.failedStage],
/// since tag browsing is optional per source and the fallback value isn't
/// proven-correct the way a resolved chapter/page ref is.
///
/// [detailsConfigured]/[chaptersConfigured]/[pagesConfigured] (all default
/// true) let a caller that already knows the config is a work-in-progress
/// skip a stage entirely instead of attempting it — a brand-new,
/// not-yet-authored block, unlike an active source's, is an expected state,
/// not a failure. Unlike chapters/pages, an unconfigured `details` never
/// *throws* (a blank selector just extracts an empty string, not a
/// `FormatException`), but attempting it anyway is still misleading: it
/// "succeeds" with an all-blank/`unknown` manga that looks like a working
/// probe result. [detailsConfigured] and [chaptersConfigured] are
/// independent — a source can have chapters wired before details, since
/// [chapters] reads the same [MangaRef] chapters/pages don't chain through
/// [details]'s output — but a false [chaptersConfigured] still implies
/// pages is skipped too (there's no chapter to fetch pages for). None of
/// the three resolves or sets [SourceProbeResult.failedStage] when skipped
/// this way.
///
/// [onProgress], when given, fires with the accumulated (partial) result
/// right after each stage resolves; a slow later stage (a Cloudflare
/// challenge, a large chapter list) then doesn't leave a caller with nothing
/// to show until the whole chain finishes; it can render what's already in
/// instead. Every call carries everything resolved so far, not just the
/// latest stage, so a caller can just overwrite its view of the result each
/// time rather than merge deltas.
///
/// A [CloudflareChallengeException] propagates uncaught so a caller wrapping
/// this in `guardCloudflare` can solve the challenge and retry; any other
/// failure is captured into the returned [SourceProbeResult] instead of
/// throwing, alongside whatever earlier stages already resolved.
///
/// Wrap the call in `runWithTrace` (see `pipeline.dart`) to also capture a
/// step trace of every request the probe makes.
Future<SourceProbeResult> probeSource(
  Source source, {
  int page = 1,
  bool detailsConfigured = true,
  bool chaptersConfigured = true,
  bool pagesConfigured = true,
  void Function(SourceProbeResult partial)? onProgress,
}) async {
  List<SourceManga>? popular;
  SourceManga? details;
  List<SourceChapter>? chapters;
  List<PageRef>? pages;
  String? tagTried;
  List<SourceManga>? tag;
  var stage = 'popular';
  try {
    popular = (await source.popular(page)).items;
    if (popular.isEmpty) {
      return SourceProbeResult(
        popular: popular,
        failedStage: stage,
        error: 'popular returned nothing',
      );
    }
    onProgress?.call(SourceProbeResult(popular: popular));

    // A request failure (bad selector, 404, …) still surfaces immediately
    // with the stage it happened in; only an *empty* chapter list moves on
    // to the next candidate, since that's the one failure mode a different
    // pick can actually fix. Swallowing real errors into "try the next one"
    // would mask a genuinely broken config behind a misleading "chapters
    // returned nothing".
    stage = 'details';
    final candidates = popular.take(maxMangaCandidates).toList();
    for (final candidate in candidates) {
      final ref = MangaRef(
        candidate.url,
        knownThumbnailUrl: candidate.thumbnailUrl,
      );
      if (detailsConfigured) {
        details = await source.details(ref);
      }
      // Nothing to pick a "best" candidate for when chapters isn't even
      // going to be attempted — the first candidate is enough either way.
      if (!chaptersConfigured) break;
      stage = 'chapters';
      chapters = await source.chapters(ref);
      if (chapters.isNotEmpty) break;
      stage = 'details';
    }
    onProgress?.call(SourceProbeResult(popular: popular, details: details));

    // Independent of chapters/pages resolving, a genre this exact manga
    // carries is a real, guaranteed-valid value to browse by; the source's
    // own first declared filter option is a fallback guess when [details]
    // has no genres at all. Best-effort: never sets [failedStage], since
    // tag browsing is optional per source and a fallback-guessed value
    // isn't a proven-correct input the way a resolved chapter/page ref is.
    if (source.hasTagListing) {
      tagTried = details?.genres.firstOrNull;
      tagTried ??=
          (await source.filters()).firstOrNull?.options.firstOrNull?.id;
      if (tagTried != null && tagTried.isNotEmpty) {
        try {
          tag = (await source.tag({tagTried}, 1)).items;
        } on CloudflareChallengeException {
          rethrow;
        } catch (_) {
          // Swallowed. See doc comment above.
        }
      } else {
        tagTried = null;
      }
    }
    onProgress?.call(
      SourceProbeResult(
        popular: popular,
        details: details,
        tagTried: tagTried,
        tag: tag,
      ),
    );

    if (!chaptersConfigured) {
      return SourceProbeResult(
        popular: popular,
        details: details,
        tagTried: tagTried,
        tag: tag,
      );
    }

    stage = 'chapters';
    if (chapters == null || chapters.isEmpty) {
      return SourceProbeResult(
        popular: popular,
        details: details,
        chapters: chapters,
        tagTried: tagTried,
        tag: tag,
        failedStage: stage,
        error:
            'chapters returned nothing (tried ${candidates.length} '
            'candidates from popular)',
      );
    }
    onProgress?.call(
      SourceProbeResult(
        popular: popular,
        details: details,
        chapters: chapters,
        tagTried: tagTried,
        tag: tag,
      ),
    );

    if (!pagesConfigured) {
      return SourceProbeResult(
        popular: popular,
        details: details,
        chapters: chapters,
        tagTried: tagTried,
        tag: tag,
      );
    }

    stage = 'pages';
    // A per-chapter error or empty result isn't fatal while other sampled
    // chapters remain, but a Cloudflare challenge still propagates so the
    // caller can solve and retry.
    Object? lastPageError;
    for (final i in {0, chapters.length ~/ 2, chapters.length - 1}) {
      try {
        pages = await source.pages(ChapterRef(chapters[i].url));
        if (pages.isNotEmpty) break;
      } on CloudflareChallengeException {
        rethrow;
      } catch (e) {
        lastPageError = e;
      }
    }
    if (pages == null || pages.isEmpty) {
      return SourceProbeResult(
        popular: popular,
        details: details,
        chapters: chapters,
        pages: pages,
        tagTried: tagTried,
        tag: tag,
        failedStage: stage,
        error:
            lastPageError ??
            'pages returned nothing (sampled first/middle/last chapters)',
      );
    }

    return SourceProbeResult(
      popular: popular,
      details: details,
      chapters: chapters,
      pages: pages,
      tagTried: tagTried,
      tag: tag,
    );
  } on CloudflareChallengeException {
    rethrow;
  } catch (e) {
    return SourceProbeResult(
      popular: popular,
      details: details,
      chapters: chapters,
      pages: pages,
      tagTried: tagTried,
      tag: tag,
      failedStage: stage,
      error: e,
    );
  }
}
