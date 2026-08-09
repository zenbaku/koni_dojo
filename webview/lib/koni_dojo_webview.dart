/// koni_dojo_webview: the flutter_inappwebview-backed WebViewFetcher, the
/// two-stage Cloudflare solver (headless → visible), and the
/// challenge-detection heuristic for `webview: true` sources. Supported on
/// macOS, iOS, Android, and Windows; on other platforms (Linux — no
/// flutter_inappwebview backend exists there) the seams stay null/no-op and
/// challenges surface as plain errors.
///
/// The engine (`koni_dojo`) stays pure Dart deliberately: this package is
/// where the concrete, Flutter/plugin-dependent transport lives instead, so
/// every consuming app shares one implementation rather than each
/// maintaining its own copy. (That's not hypothetical: a stale-clearance
/// bug, a native cookie-deletion bug, and a false-positive
/// challenge-detection bug each shipped once, in one app's copy, and had to
/// be independently rediscovered before this package existed.)
///
/// Callers own persistence: [solveCloudflare] returns the captured
/// clearance rather than saving it anywhere, so each app's own
/// `ClearanceStore` decides how/where it's kept. [warmCookieJar] re-seeds
/// the WebView's cookie jar from whatever the app loads from its own store.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:koni_dojo/koni_dojo.dart';

import 'dom_tree_algo.dart';
import 'dom_tree_view.dart';

bool get cloudflareSolveSupported =>
    Platform.isMacOS ||
    Platform.isIOS ||
    Platform.isAndroid ||
    Platform.isWindows;

// ── Diagnostic log ──────────────────────────────────────────────────────────

const _cfLogKey = #cfSolverLog;

/// Runs [body] with [sink] receiving every Cloudflare-solver diagnostic line
/// logged during it (via [cfLog]): a Zone-based ambient sink, the same
/// pattern `runWithTrace` (`package:koni_dojo`) uses for pipeline step
/// traces, so deep call sites (the solver, the headless WebView fetcher)
/// don't need a log parameter threaded through every signature. A caller
/// that wants these diagnostics surfaced (e.g. in a probe UI) installs a
/// sink around the guarded run; composes with `runWithTrace`: nesting
/// inside/outside it, both ambient values stay reachable via `Zone.current`.
Future<T> runWithCfLog<T>(
  void Function(String) sink,
  Future<T> Function() body,
) => runZoned(body, zoneValues: {_cfLogKey: sink});

/// Logs [message] to the console (so `flutter run`'s terminal still shows it)
/// and, if [runWithCfLog] installed a sink, to that too. Every Cloudflare
/// solve/fetch diagnostic in this package goes through this instead of a
/// bare `debugPrint`.
void cfLog(String message) {
  debugPrint(message);
  final sink = Zone.current[_cfLogKey];
  if (sink is void Function(String)) sink(message);
}

// ── WebViewFetcher singleton ─────────────────────────────────────────────────

WebViewFetcher? _fetcher;

/// The WebView transport for `webview: true` (CF-hard) sources, null on
/// platforms without a supported WebView. Lazily creates one persistent
/// headless instance per process.
WebViewFetcher? createWebViewFetcher() =>
    cloudflareSolveSupported ? _fetcher ??= _InAppWebViewFetcher() : null;

// ── Cookie-jar warming ───────────────────────────────────────────────────────

/// Re-seeds the WebView's cookie jar with every (host, cookie header) in
/// [entries], typically a persisted `ClearanceStore`'s saved clearances,
/// so a challenge cleared in a previous run is reused on this launch instead
/// of hitting it cold. The value is still validated server-side by
/// Cloudflare; if it has expired there, the next navigation re-challenges
/// and the solver re-captures. No-op on platforms without WebView support,
/// and in tests where the plugin channel isn't wired (swallows the
/// failure). Returns how many hosts were confirmed re-seeded (read back
/// after writing). A caller can use this for a "N hosts already cleared"
/// indicator.
///
/// Each cookie is written with a far-future expiry so it lands in WKWebView's
/// **persistent** store (a no-expiry cookie is session-only and wouldn't
/// survive the next restart on its own), and the write is read back: some
/// WKWebView versions silently drop an `isHttpOnly` `setCookie`, so a missing
/// cookie is retried without that flag (the WebView still sends it on
/// requests; only JS-readability differs, which nothing here relies on).
Future<int> warmCookieJar(
  Iterable<({String host, String cookie})> entries,
) async {
  if (!cloudflareSolveSupported) return 0;
  var hostsSeeded = 0;
  try {
    final cookies = CookieManager.instance();
    final expiresDate = DateTime.now()
        .add(const Duration(days: 365))
        .millisecondsSinceEpoch;
    for (final entry in entries) {
      final url = WebUri('https://${entry.host}/');
      var anyLanded = false;
      for (final (name, value) in _parseCookieHeader(entry.cookie)) {
        Future<void> set({required bool httpOnly}) => cookies.setCookie(
          url: url,
          name: name,
          value: value,
          domain: entry.host,
          path: '/',
          expiresDate: expiresDate,
          isSecure: true,
          isHttpOnly: httpOnly,
        );
        await set(httpOnly: true);
        if (!await _cookiePresent(cookies, url, name)) {
          await set(httpOnly: false); // WKWebView rejected the httpOnly write
        }
        if (await _cookiePresent(cookies, url, name)) anyLanded = true;
      }
      if (anyLanded) hostsSeeded++;
    }
  } catch (_) {
    // No plugin host (tests) or the cookie store rejected a write. The
    // worst case is a cold re-solve, which already works.
  }
  return hostsSeeded;
}

/// (name, value) pairs from a `Cookie:` header value, dropping empties.
Iterable<(String, String)> _parseCookieHeader(String header) sync* {
  for (final pair in header.split(';')) {
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (name.isNotEmpty) yield (name, value);
  }
}

Future<bool> _cookiePresent(
  CookieManager cookies,
  WebUri url,
  String name,
) async => (await cookies.getCookies(
  url: url,
)).any((c) => c.name == name && '${c.value}'.isNotEmpty);

// ── Solver ──────────────────────────────────────────────────────────────────

/// What a solved challenge yields: the cookie header a browser earned by
/// passing it, plus the exact User-Agent that earned it. Cloudflare binds
/// `cf_clearance` to both, so a caller must replay them together.
typedef ClearanceCapture = ({String cookie, String userAgent});

/// Clears a Cloudflare challenge for [url]'s host. Two-stage: a hidden
/// WebView first (JS interstitials / "managed" challenges auto-solve), then,
/// only when [context] is given and still mounted, a visible window for
/// interactive Turnstile checks. Returns the captured clearance, or null if
/// the challenge needs interaction and no context was given (or the dialog
/// was cancelled). Solves are serialized process-wide: concurrent callers
/// hitting several walled hosts queue up instead of racing WebViews.
///
/// Does **not** persist the result: that's the caller's job (each app has
/// its own `ClearanceStore`). Callers should always call this in response to
/// a fresh `CloudflareChallengeException`, never speculatively: every check
/// here (`_tryHeadless`, the dialog) declares "solved" by checking whether
/// `cf_clearance` is present in the WebView's cookie jar, which a stale
/// leftover satisfies just as well as a fresh one; the eviction inside is
/// what makes that check trustworthy again.
Future<ClearanceCapture?> solveCloudflare(Uri url, {BuildContext? context}) {
  // Safe across the queue's async gap: _solveOne re-checks context.mounted
  // after every await before touching it.
  // ignore: use_build_context_synchronously
  final result = _solveChain.then((_) => _solveOne(url, context: context));
  _solveChain = result.then((_) {}, onError: (_) {});
  return result;
}

Future<void> _solveChain = Future<void>.value();

Future<ClearanceCapture?> _solveOne(Uri url, {BuildContext? context}) async {
  if (!cloudflareSolveSupported) return null;
  // Every caller only reaches this via a just-thrown
  // CloudflareChallengeException for this exact host, so whatever's
  // currently in the cookie jar has already, empirically, failed to clear
  // this request. `_tryHeadless` and the visible dialog both declare
  // "solved" purely by checking whether a `cf_clearance` cookie is
  // *present*, so a leftover from a previous (possibly long-expired,
  // possibly persisted-then-reloaded) session would satisfy that check
  // without anything actually being re-solved: no navigation past the
  // challenge, no dialog, nothing real. Evicting first forces both paths to
  // require Cloudflare to genuinely reissue one now.
  //
  // Deliberately NOT `CookieManager.deleteCookies(url: ...)`: its native
  // macOS implementation (flutter_inappwebview_macos' MyCookieManager.swift)
  // silently no-ops for a domain-scoped cookie (e.g. `.example.com`, the
  // common form): it re-derives a bare host from the URL and compares with
  // `cookie.domain == domain` (exact string equality), which a leading-dot
  // domain never satisfies, then reports `result(true)` unconditionally
  // regardless of whether anything matched. The per-cookie `deleteCookie`
  // workaround (feeding each cookie's own reported domain back) is also
  // empirically unreliable: live-logged evicting only 2 of 4 cookies for
  // one host, a platform-channel string-marshaling wrinkle on the dotted
  // variant. `deleteAllCookies()` sidesteps the whole domain-matching layer:
  // no comparison to get wrong, just a `WKWebsiteDataStore` bulk wipe.
  // Broader than "just this host": every other host's live in-memory
  // clearance goes with it, until the next `warmCookieJar` re-seeds them;
  // acceptable because reliability here matters more than not disturbing an
  // unrelated host's clearance mid-session.
  final beforeCount = (await CookieManager.instance().getCookies(
    url: WebUri('https://${url.host}/'),
  )).length;
  await CookieManager.instance().deleteAllCookies();
  final afterDelete = await CookieManager.instance().getCookies(
    url: WebUri('https://${url.host}/'),
  );
  cfLog(
    'CF _solveOne(${url.host}): deleteAllCookies (had $beforeCount for this '
    'host), remaining after: ${afterDelete.map((c) => c.name).toList()}',
  );
  var capture = await _tryHeadless(url);
  cfLog(
    'CF _solveOne(${url.host}): _tryHeadless -> '
    '${capture == null ? 'null (needs interactive)' : 'CAPTURED'}',
  );
  if (capture == null) {
    cfLog(
      'CF _solveOne(${url.host}): context=${context == null ? 'null' : (context.mounted ? 'mounted' : 'unmounted')}',
    );
    if (context != null && context.mounted) {
      cfLog('CF _solveOne(${url.host}): showing visible solver dialog');
      capture = await showDialog<ClearanceCapture>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SolverDialog(url: url),
      );
      cfLog(
        'CF _solveOne(${url.host}): dialog closed -> '
        '${capture == null ? 'cancelled/null' : 'CAPTURED'}',
      );
    }
  }
  if (capture == null) {
    cfLog('CF _solveOne(${url.host}): giving up, returning null');
    return null;
  }
  cfLog('CF _solveOne(${url.host}): solved, returning capture');
  return capture;
}

const _headlessTimeout = Duration(seconds: 12);

/// Hidden-WebView attempt: navigate and poll the cookie jar for
/// `cf_clearance` until [_headlessTimeout]. Null when the challenge needs a
/// human (Turnstile), so the caller falls back to the visible solver.
Future<ClearanceCapture?> _tryHeadless(Uri url) async {
  final webUri = WebUri(url.toString());
  final completer = Completer<ClearanceCapture?>();
  HeadlessInAppWebView? headless;
  var checkCount = 0;

  Future<void> check() async {
    if (completer.isCompleted) return;
    checkCount++;
    final controller = headless?.webViewController;
    if (controller == null) return;
    final cookies = await CookieManager.instance().getCookies(url: webUri);
    cfLog(
      'CF _tryHeadless(${url.host}): check #$checkCount, '
      'cookies=${cookies.map((c) => c.name).toList()}',
    );
    if (!_hasClearance(cookies)) return;
    final ua = await _userAgent(controller);
    if (ua.isEmpty) return;
    if (!completer.isCompleted) {
      cfLog(
        'CF _tryHeadless(${url.host}): cf_clearance found on check #$checkCount, completing',
      );
      completer.complete((cookie: _cookieHeader(cookies), userAgent: ua));
    }
  }

  headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(
      url: webUri,
      cachePolicy: URLRequestCachePolicy.RELOAD_IGNORING_LOCAL_CACHE_DATA,
    ),
    // cf_clearance can land a beat after the final load event; the poll below
    // backs this up rather than relying on onLoadStop alone.
    onLoadStop: (_, _) => check(),
  );
  try {
    await headless.run();
  } catch (e) {
    cfLog('CF _tryHeadless(${url.host}): headless.run() failed: $e');
    await headless.dispose();
    return null;
  }
  final poll = Timer.periodic(
    const Duration(milliseconds: 700),
    (_) => check(),
  );
  final deadline = Timer(_headlessTimeout, () {
    if (!completer.isCompleted) {
      cfLog(
        'CF _tryHeadless(${url.host}): ${_headlessTimeout.inSeconds}s '
        'deadline hit after $checkCount checks, giving up',
      );
      completer.complete(null);
    }
  });

  final result = await completer.future;
  poll.cancel();
  deadline.cancel();
  await headless.dispose();
  return result;
}

bool _hasClearance(List<Cookie> cookies) =>
    cookies.any((c) => c.name == 'cf_clearance' && '${c.value}'.isNotEmpty);

String _cookieHeader(List<Cookie> cookies) =>
    cookies.map((c) => '${c.name}=${c.value}').join('; ');

Future<String> _userAgent(InAppWebViewController controller) async {
  final ua = await controller.evaluateJavascript(source: 'navigator.userAgent');
  return ua?.toString() ?? '';
}

/// The visible fallback: a WebView the user solves by hand. Polls the cookie
/// jar (on navigation and once a second) and pops with the capture the
/// instant `cf_clearance` appears; popping with null means cancelled.
class _SolverDialog extends StatefulWidget {
  const _SolverDialog({required this.url});

  final Uri url;

  @override
  State<_SolverDialog> createState() => _SolverDialogState();
}

class _SolverDialogState extends State<_SolverDialog> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Turnstile can pass in place without firing a navigation event; poll too.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final controller = _controller;
    if (_done || controller == null) return;
    final webUri = WebUri(widget.url.toString());
    final cookies = await CookieManager.instance().getCookies(url: webUri);
    if (!_hasClearance(cookies)) return;
    final ua = await _userAgent(controller);
    if (ua.isEmpty) return;
    _done = true;
    _poll?.cancel();
    if (mounted) {
      Navigator.of(
        context,
      ).pop<ClearanceCapture>((cookie: _cookieHeader(cookies), userAgent: ua));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(
          children: [
            AppBar(
              title: const Text('Verify you’re human'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                '${widget.url.host} is protected by Cloudflare. Complete the '
                'check below — this window closes itself once it passes.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(widget.url.toString()),
                  cachePolicy:
                      URLRequestCachePolicy.RELOAD_IGNORING_LOCAL_CACHE_DATA,
                ),
                onWebViewCreated: (controller) => _controller = controller,
                onLoadStop: (_, _) => _check(),
                onUpdateVisitedHistory: (_, _, _) => _check(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Login ────────────────────────────────────────────────────────────────────

/// Opens a visible WebView on [url] and waits for the user to complete a
/// site's own login flow by hand: there's no universal "logged in" cookie
/// name to poll for the way [solveCloudflare] polls for `cf_clearance`, so
/// the dialog instead waits for an explicit "Done" tap. Returns the captured
/// session (every cookie for [url]'s host, plus the WebView's User-Agent) on
/// Done, or null if the dialog is cancelled or [context] is unmounted.
///
/// Does **not** persist the result. Same convention as [solveCloudflare]:
/// each app's own store decides where a captured session lives and how it's
/// replayed. Because the WebView's cookie jar is the platform's real,
/// persistent cookie store, a login captured here already lands in every
/// other WebView-mediated fetch for this host without further plumbing; the
/// persistence only matters for surviving a [solveCloudflare]-triggered
/// `deleteAllCookies()` elsewhere or an app relaunch, see [warmCookieJar].
///
/// Solves are serialized process-wide with [solveCloudflare] (one shared
/// chain): both drive the same singleton WebView machinery, so two callers
/// racing would otherwise show two dialogs over one WebView.
Future<ClearanceCapture?> openLoginSession(Uri url, {BuildContext? context}) {
  // Safe across the queue's async gap: the dialog re-checks context.mounted
  // after every await before touching it.
  // ignore: use_build_context_synchronously
  final result = _solveChain.then((_) => _openLoginSessionOne(url, context));
  _solveChain = result.then((_) {}, onError: (_) {});
  return result;
}

Future<ClearanceCapture?> _openLoginSessionOne(
  Uri url,
  BuildContext? context,
) async {
  if (!cloudflareSolveSupported) return null;
  if (context == null || !context.mounted) return null;
  cfLog('Login _openLoginSessionOne(${url.host}): showing login dialog');
  final capture = await showDialog<ClearanceCapture>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LoginDialog(url: url),
  );
  cfLog(
    'Login _openLoginSessionOne(${url.host}): dialog closed -> '
    '${capture == null ? 'cancelled/null' : 'CAPTURED'}',
  );
  return capture;
}

/// The visible login WebView: the user signs in by hand (email/password,
/// a captcha, whatever the site needs), then taps "Done"; unlike
/// [_SolverDialog] there's nothing to poll for, so completion is entirely
/// user-driven. Popping with null means cancelled.
class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.url});

  final Uri url;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  InAppWebViewController? _controller;
  bool _finishing = false;

  Future<void> _finish() async {
    final controller = _controller;
    if (_finishing || controller == null) return;
    setState(() => _finishing = true);
    final webUri = WebUri(widget.url.toString());
    final cookies = await CookieManager.instance().getCookies(url: webUri);
    final ua = await _userAgent(controller);
    if (!mounted) return;
    if (cookies.isEmpty || ua.isEmpty) {
      Navigator.of(context).pop<ClearanceCapture>(null);
      return;
    }
    Navigator.of(
      context,
    ).pop<ClearanceCapture>((cookie: _cookieHeader(cookies), userAgent: ua));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(
          children: [
            AppBar(
              title: Text('Log in to ${widget.url.host}'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                'Log in below, then tap "Done" — this window stays open '
                'until you close it.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(widget.url.toString()),
                ),
                onWebViewCreated: (controller) => _controller = controller,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _finishing ? null : _finish,
                  child: Text(_finishing ? 'Checking…' : 'Done'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Element picker ───────────────────────────────────────────────────────────

/// See [FieldStep.mode].
enum StepMode { item, relative }

/// One step of a linear point-and-click wizard, in order. An `item` step
/// detects a repeating group — always the wizard's *first* step when one is
/// present, since every relative step needs a confirmed set of item roots to
/// pick inside. It can also be a wizard's *only* step, when the block has no
/// per-item sub-field to pick relative to it (`pages`' `imageSelector`: the
/// detected group selector *is* the whole record, there's nothing further to
/// click). A `relative` step picks one field inside the confirmed item
/// roots.
class FieldStep {
  const FieldStep({
    required this.key,
    required this.instruction,
    required this.fieldLabel,
    required this.mode,
    this.attr = '',
    this.preferAnchorTag = false,
    this.optional = false,
    this.previewIsImage = false,
  });

  /// The config field this step fills, e.g. `'itemSelector'`,
  /// `'nameSelector'`, `'urlSelector'`. [PickedFields] is keyed by this;
  /// when [attr] is non-empty the result also carries [attrKey].
  final String key;

  /// Shown above the WebView while this step is active.
  final String instruction;

  /// Short label for button/title text, e.g. `'item'`, `'name'`, `'link'`.
  final String fieldLabel;

  final StepMode mode;

  /// Attribute to capture (`'src'`/`'href'`/…), or `''` for the element's
  /// own text.
  final String attr;

  /// True to prefer the nearest ancestor `<a>` over the exact clicked
  /// element (a url-style step: clicking the title text or the cover image
  /// inside a link should still select the link, not just the text/image).
  final bool preferAnchorTag;

  /// True if this step can be skipped without a selection — not every site
  /// exposes every field inline (e.g. a chapter's upload date).
  final bool optional;

  /// True when this step's preview value is an image URL — the pending-
  /// summary widgets render it as a thumbnail instead of plain text. Only
  /// set on `detailsFields`' `coverSelector` today; `popularSteps`' own
  /// structurally-identical cover step doesn't set it, matching this
  /// round's Details-palette-only scope for the picker's live-sync/preview
  /// work (see the picker UX fixes plan) — flipping it there too is a
  /// one-word follow-up if wanted later.
  final bool previewIsImage;

  /// The config field [attr] itself belongs under, e.g. `coverSelector` →
  /// `coverAttr`, `imageSelector` → `imageAttr` — the same
  /// `Selector`→`Attr` convention `ConfigForm._attrValue` (`config_form.dart`)
  /// already uses for hand-typed fields, so a picked config reads exactly
  /// like a hand-edited one. **Not** `'${key}Attr'` (`coverSelectorAttr`) —
  /// that was a real bug here for the entire session: it silently never
  /// matched any schema field, so every picked `coverAttr`/`urlAttr`/
  /// `imageAttr` stayed at the engine's own default and any pick needing a
  /// non-default attribute (e.g. `data-src` for a lazy-loaded cover) would
  /// have silently done nothing.
  String get attrKey => key.replaceAll('Selector', 'Attr');
}

/// Selector (and, for an attribute-capturing field, [FieldStep.attrKey])
/// per [FieldStep.key] produced by [pickFields] — e.g. `{'itemSelector':
/// '...', 'titleSelector': '...', 'coverSelector': '...', 'coverAttr':
/// 'src', ...}` for [popularSteps]. Generalizes the old fixed-shape
/// `PickedListing` now that the wizard covers more than one block shape; a
/// skipped optional step simply has no entry.
typedef PickedFields = Map<String, String>;

/// A wizard/palette's result: the selector/attr fields to write into the
/// config ([fields], unchanged shape), plus a human preview string per
/// *base* field key ([previews]) captured at confirm-time from what was
/// actually seen on the page — the matched-item count for an item-mode step
/// (an image count for `pages`, a repeating card count for `popular`'s
/// `itemSelector`), or the extracted text/attribute value for a relative
/// one (a title's actual text, a cover's actual `src`). Never includes an
/// entry for a `*Attr` companion key (see `FieldStep.attrKey`) — there's
/// nothing extra to preview for an attribute *name*. Shown in the confirm
/// dialog so a pick can be sanity-checked without re-opening the picker.
typedef PickResult = ({PickedFields fields, Map<String, String> previews});

/// [pickDetailsFields]'s result — [PickResult]'s shape plus an optional
/// [rows] block. Kept as its own typedef rather than widening [PickResult]
/// itself: only the details palette can ever produce a `rows` block (the
/// linear wizard has no notion of it), so folding it into the shared type
/// would force every wizard call site to thread a permanently-null field.
typedef DetailsPickResult = ({
  PickedFields fields,
  Map<String, String> previews,
  RowsConfig? rows,
});

/// `popular`/`search`/`tag`-shaped listing blocks: item container, then
/// title/cover/url relative to it.
const popularSteps = <FieldStep>[
  FieldStep(
    key: 'itemSelector',
    instruction: 'Click one manga card in the list.',
    fieldLabel: 'item',
    mode: StepMode.item,
  ),
  FieldStep(
    key: 'titleSelector',
    instruction: 'Now click the title text inside that card.',
    fieldLabel: 'title',
    mode: StepMode.relative,
  ),
  FieldStep(
    key: 'coverSelector',
    instruction: 'Now click the cover image inside that card.',
    fieldLabel: 'cover',
    mode: StepMode.relative,
    attr: 'src',
  ),
  FieldStep(
    key: 'urlSelector',
    instruction:
        'Now click the link (the title or the cover) inside that card.',
    fieldLabel: 'link',
    mode: StepMode.relative,
    attr: 'href',
    preferAnchorTag: true,
  ),
];

/// `chapters`: item container, then name/link/date relative to it. `date` is
/// optional and skippable — not every theme shows an inline upload date.
const chaptersSteps = <FieldStep>[
  FieldStep(
    key: 'itemSelector',
    instruction: 'Click one chapter row in the list.',
    fieldLabel: 'item',
    mode: StepMode.item,
  ),
  FieldStep(
    key: 'nameSelector',
    instruction: 'Now click the chapter name/number text.',
    fieldLabel: 'name',
    mode: StepMode.relative,
  ),
  FieldStep(
    key: 'urlSelector',
    instruction: 'Now click the link to the chapter.',
    fieldLabel: 'link',
    mode: StepMode.relative,
    attr: 'href',
    preferAnchorTag: true,
  ),
  FieldStep(
    key: 'dateSelector',
    instruction:
        'Now click the upload date, if this theme shows one — or skip.',
    fieldLabel: 'date',
    mode: StepMode.relative,
    optional: true,
  ),
];

/// `pages`: a single item-detection step. Unlike popular/chapters, an image
/// tag *is* the whole record — there's no per-item sub-field to pick
/// relative to it, so the wizard finishes as soon as this one step confirms.
///
/// Known heuristic gap: [computeItemCandidate] (below) promotes the clicked
/// element to its nearest *repeating* ancestor — correct for popular/
/// chapters, where the item is a card and title/cover/link are picked
/// relative to it. `pages` has no such relative step: `imageSelector`'s
/// matched elements are read directly for `imageAttr` (default `src`), so
/// the item must stay the `<img>` itself. A reader that wraps each page
/// image in its own `<div>` (the `<img>` has no sibling `<img>`s, but the
/// wrapping `<div>`s repeat) promotes past the image to that div — the
/// resulting selector matches elements with no `src` at all, and pages
/// comes back empty with no obvious cause. Not yet special-cased; if it
/// bites a real source, the fix is either to stop `computeItemCandidate`
/// from promoting past an element that already carries the requested attr
/// in `pages` mode, or a dedicated `pages`-only item search.
const pagesSteps = <FieldStep>[
  FieldStep(
    key: 'imageSelector',
    instruction: 'Click one page image in the reader.',
    fieldLabel: 'image',
    mode: StepMode.item,
    attr: 'src',
  ),
];

/// Opens a visible WebView on [url] and walks the user through [steps] —
/// see [popularSteps]/[chaptersSteps]/[pagesSteps] — by clicking the
/// rendered page: the point-and-click alternative to hand-writing a
/// listing block's selectors.
///
/// [engineHtml] should be the same already-probed HTML `ConfigForm.testHtml`
/// uses (from a prior stage run against this exact source). Every candidate
/// the user clicks in the WebView — which renders JS, unlike the production
/// engine's plain static fetch — is cross-checked by re-parsing [engineHtml]
/// with `package:html`, the same parser the engine uses, so the match count
/// shown for confirmation is the engine's reality, not the browser DOM's
/// (the two can diverge on JS-hydrated pages). Pass an empty string if no
/// probe has run yet; the dialog still works, just without that check, and
/// says so.
///
/// Returns null if the dialog is cancelled or [context] is unmounted.
/// Serialized with [solveCloudflare]/[openLoginSession] (one shared chain):
/// all three drive the same singleton WebView machinery, so two callers
/// racing would otherwise show two dialogs over one WebView.
///
/// [sourceUsesWebview] and [onRequestEnableWebview] drive the "this site
/// might need `webview: true`" callout: when an item candidate's live
/// count is healthy but its engineHtml cross-check comes up empty (or far
/// lower) *and* [sourceUsesWebview] is false, that specific pattern means
/// the fetch mode this source is using doesn't see what the browser sees —
/// not a bad selector. Never shown when [sourceUsesWebview] is already
/// true (a mismatch there means something else). [onRequestEnableWebview],
/// when given, is called (and the dialog closes, as if cancelled) if the
/// user taps the callout's action — the caller owns flipping the config
/// flag and retrying, this dialog only ever reports the intent.
Future<PickResult?> pickFields(
  Uri url, {
  required List<FieldStep> steps,
  required String engineHtml,
  required bool sourceUsesWebview,
  VoidCallback? onRequestEnableWebview,
  BuildContext? context,
  PickResult? seed,
}) {
  // Safe across the queue's async gap: _pickFieldsOne re-checks
  // context.mounted after every await before touching it.
  final result = _solveChain.then(
    (_) => _pickFieldsOne(
      url,
      steps,
      engineHtml,
      sourceUsesWebview,
      onRequestEnableWebview,
      // ignore: use_build_context_synchronously
      context,
      seed,
    ),
  );
  _solveChain = result.then((_) {}, onError: (_) {});
  return result;
}

Future<PickResult?> _pickFieldsOne(
  Uri url,
  List<FieldStep> steps,
  String engineHtml,
  bool sourceUsesWebview,
  VoidCallback? onRequestEnableWebview,
  BuildContext? context,
  PickResult? seed,
) async {
  if (!cloudflareSolveSupported) return null;
  if (context == null || !context.mounted) return null;
  return showDialog<PickResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PickerDialog(
      url: url,
      steps: steps,
      engineHtml: engineHtml,
      sourceUsesWebview: sourceUsesWebview,
      onRequestEnableWebview: onRequestEnableWebview,
      seed: seed,
    ),
  );
}

/// One just-clicked, not-yet-confirmed item-container candidate: the
/// browser-side guess plus the [engineCount] re-derived from `engineHtml`
/// (-1 when there's no probed HTML to check against).
typedef _PendingItem = ({String selector, int engineCount, int browserCount});

/// One just-clicked, not-yet-confirmed sub-field candidate, already
/// re-verified against every item root found in `engineHtml` (`totalItems`
/// is -1 when there's no probed HTML to check against).
typedef _PendingRelative = ({
  String selector,
  int engineHits,
  int totalItems,
  String preview,
});

/// The guided linear picker, driven by [FieldStep]s (see [popularSteps]/
/// [chaptersSteps]/[pagesSteps]). One WebView, loaded once; clicking never
/// navigates (every click is captured and cancelled by the injected picker
/// script, see [_pickerScript]) — only the Dart-side step index advances,
/// driven by the Confirm buttons below the WebView.
/// Pause/tree/level-adjust state machinery shared by [_PickerDialogState]
/// (the linear item→relative wizard) and [_DetailsPickerDialogState] (the
/// field palette) — pulled out after Fable's session review flagged the two
/// classes as ~250 lines of near-duplicate state machinery. Deliberately
/// narrow: only what was byte-for-byte identical between the two moved
/// here. `_onTreeNodeTap`, `_highlightedGroup`, and `_resyncPickerState`
/// each differ in real, non-mechanical ways (single- vs. multi-root
/// relative candidates, different JS state to push) and stay separate by
/// design rather than being forced through an abstraction that would just
/// paper over the difference.
/// Prompts for a hand-typed CSS selector, pre-filled with [current]. Shared
/// by [_PickerTreeAndPauseMixin._editSelectorManually] (the flat/item
/// pending-pick escape hatch) and the Details palette's rows Adjust panel
/// (`_DetailsPickerDialogState._rowsAdjustPanel`) — same dialog either
/// way, just a different place the result gets applied. `null` for Cancel
/// or a blank submit — the caller decides what, if anything, blank should
/// mean explicitly (e.g. rows' dedicated "Whole row text" button, not
/// this dialog).
Future<String?> _promptSelectorDialog(BuildContext context, String current) async {
  final controller = TextEditingController(text: current);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit selector'),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(fontFamily: 'monospace'),
        decoration: const InputDecoration(labelText: 'CSS selector'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  return (result == null || result.isEmpty) ? null : result;
}

mixin _PickerTreeAndPauseMixin<T extends StatefulWidget> on State<T> {
  InAppWebViewController? _controller;
  dom.Document? _engineDoc;

  /// True while clicks pass through to the page untouched instead of being
  /// captured for picking — the escape hatch for anything that needs a real
  /// click to get past (an ad overlay's own Cancel button, a cookie banner,
  /// an age gate). Confirmed live: without this, an interstitial ad is an
  /// inescapable click-trap, since capturing *every* click to detect picks
  /// also captures the click meant to dismiss the ad itself.
  bool _paused = false;

  int _minLevel = 0;

  /// Guards [_adjustLevel] against overlapping taps: two concurrent
  /// `evaluateJavascript` calls can resolve out of order, so a fast
  /// narrower-then-wider tap could otherwise leave the state as if only one
  /// had happened — confirmed exactly this kind of "sometimes doesn't do
  /// anything" symptom in real use. Also disables both level buttons while
  /// in flight, not just re-entrant calls to this method, so there's visible
  /// feedback that a request is outstanding.
  bool _adjustingLevel = false;

  /// True whenever there's a static, already-parsed document to browse — the
  /// DOM-tree sidebar shows nothing without one (see [DomTreePanel]'s doc).
  bool _showTree = true;

  /// The element a tree tap last picked, if the *most recent* pick came
  /// from the tree rather than the WebView — cleared by [_onPickerMessage]
  /// whenever a fresh WebView click supersedes it, so [_adjustLevel] always
  /// re-derives from whichever input actually produced the current pending
  /// candidate. **Not** what drives the tree's own selection highlight —
  /// see [_treeSelected] — since reusing this field for that would make
  /// [_adjustLevel] wrongly take its tree-derived branch after a WebView
  /// click, re-deriving from a merely-representative engineDoc element
  /// instead of asking the live browser to recompute from the element it
  /// actually clicked.
  dom.Element? _lastTreeClick;

  /// The DOM-tree sidebar's counterpart to [_lastTreeClick] for a WebView
  /// click instead of a tree tap: the first element in [_highlightedGroup]
  /// that the click's resulting selector matches in `engineDoc`, purely for
  /// display (see [_treeSelected]) — a real element from the live click,
  /// but not necessarily *the* element the browser click landed on (there's
  /// no shared identity between a live DOM node and engineDoc's parsed
  /// tree, only selector-matching), which is exactly why [_adjustLevel]
  /// must never treat this as a tree-originated pick.
  dom.Element? _liveTreeMatch;

  /// What the DOM-tree sidebar should show as selected — a tree tap always
  /// wins (it's an exact match, not a representative one); otherwise the
  /// last WebView click's [_liveTreeMatch], so clicking the live page keeps
  /// the tree in sync too, not just the reverse direction.
  dom.Element? get _treeSelected => _lastTreeClick ?? _liveTreeMatch;

  /// Every element the DOM tree should tint as "currently matched" for
  /// whatever's pending — [_PickerDialogState]/[_DetailsPickerDialogState]
  /// each compute this differently (single global document vs. per-
  /// confirmed-item-root), so it stays abstract; [_onPickerMessage] uses it
  /// to derive [_liveTreeMatch] without duplicating that per-class logic.
  Set<dom.Element>? get _highlightedGroup;

  _PendingItem? _pendingItem;
  _PendingRelative? _pendingRelative;

  /// A human preview string per confirmed *base* field key, built up
  /// alongside `_picked` (see [_itemPreview]) — the counterpart the confirm
  /// dialog shows next to each selector so a pick can be sanity-checked
  /// without re-opening the picker. Returned as part of [PickResult],
  /// separate from the config-bound `PickedFields` map itself (a preview
  /// string is never something the engine should read back as config).
  final Map<String, String> _previews = {};

  /// An item-mode step's preview: how many elements it actually matched
  /// (there's no single value to show — an item selector defines a
  /// *repeating group*, not a field). When [step] also reads an attribute
  /// directly off its matched elements (`pages`' `imageSelector` is the one
  /// case today — see its doc), the first match's attribute value is
  /// appended too, since that's cheap to compute from [_engineDoc] and
  /// meaningfully richer than a bare count.
  String _itemPreview(_PendingItem pending, FieldStep step) {
    final count = pending.engineCount >= 0
        ? pending.engineCount
        : pending.browserCount;
    final noun = count == 1 ? 'match' : 'matches';
    final base = '$count $noun';
    if (step.attr.isEmpty) return base;
    final doc = _engineDoc;
    if (doc == null) return base;
    final matches = doc.querySelectorAll(pending.selector);
    if (matches.isEmpty) return base;
    final value = matches.first.attributes[step.attr];
    return value == null || value.isEmpty ? base : '$base — first: $value';
  }

  /// [_PickerDialogState._evaluateRelative]/
  /// [_DetailsPickerDialogState._evaluateRelative]: re-verifies a relative
  /// selector against `engineHtml`. Each implementer's notion of "the item
  /// roots to check against" differs (N confirmed item roots vs. a single
  /// global document), so this stays abstract rather than shared.
  _PendingRelative _evaluateRelative(
    String selector, {
    required String browserPreview,
  });

  /// Pushes [selector]'s matches into the live WebView's dashed-outline
  /// highlight (`__koniHighlightGroup`/`__koniClearHighlight` in
  /// `_pickerScript`) and scrolls the first match into view — each
  /// `_onTreeNodeTap`'s counterpart to the live page's own click handler,
  /// which already highlights on every item-mode click. `null` (or an
  /// empty string — `document.querySelectorAll('')` throws in the browser;
  /// a rows field's "use the row's own text" mode sends `''` as a real,
  /// valid `valueSelector`, not a missing one) clears the highlight
  /// instead.
  void _highlightInPage(String? selector) {
    final js = (selector == null || selector.isEmpty)
        ? "if (window.__koniClearHighlight) window.__koniClearHighlight();"
        : '''
      var els = document.querySelectorAll(${jsonEncode(selector)});
      if (window.__koniHighlightGroup) window.__koniHighlightGroup(els);
      if (els.length) els[0].scrollIntoView({block: 'center'});
      ''';
    _controller?.evaluateJavascript(source: js);
  }

  /// Recomputes [_pendingItem]/[_pendingRelative] for a hand-typed
  /// [selector] (see [_editSelectorManually]) — the escape hatch for when
  /// the auto-generated candidate is right in spirit but wrong in
  /// specificity (e.g. a bare `span` matching every tag on a details page,
  /// not just the intended group), with no interactive way to steer the
  /// generation algorithm itself. [mode] can't be read off a shared field
  /// (each dialog derives "the current step" differently), so it's passed
  /// in by the caller. Flows through the exact same `_pendingItem`/
  /// `_pendingRelative` + [_pendingCandidateChanged] path a real click
  /// does, so in the Details palette a valid hand-edited selector
  /// live-syncs the same as a click would — no separate plumbing needed,
  /// and a selector matching nothing simply doesn't sync, same as any
  /// other candidate.
  Future<void> _applyManualSelector(String selector, StepMode mode) async {
    _lastTreeClick = null;
    _liveTreeMatch = null;
    if (mode == StepMode.item) {
      final doc = _engineDoc;
      final engineCount = doc?.querySelectorAll(selector).length ?? -1;
      var browserCount = engineCount < 0 ? 0 : engineCount;
      final controller = _controller;
      if (controller != null) {
        final raw = await controller.evaluateJavascript(
          source:
              '''
          (function() {
            var els = document.querySelectorAll(${jsonEncode(selector)});
            if (window.__koniHighlightGroup) window.__koniHighlightGroup(els);
            else if (window.__koniClearHighlight) window.__koniClearHighlight();
            return els.length;
          })();
          ''',
        );
        final live = (raw as num?)?.toInt();
        if (live != null) browserCount = live;
      }
      setState(() {
        _pendingItem = (
          selector: selector,
          engineCount: engineCount,
          browserCount: browserCount,
        );
        _liveTreeMatch = _firstMatch(_highlightedGroup);
      });
    } else {
      setState(() {
        _pendingRelative = _evaluateRelative(selector, browserPreview: '');
        _liveTreeMatch = _firstMatch(_highlightedGroup);
      });
      _highlightInPage(selector);
    }
    _pendingCandidateChanged();
  }

  /// The manual-edit escape hatch shown next to the pending-summary
  /// widgets for when the auto-generated candidate needs narrowing (or
  /// widening) the algorithm alone can't do — prompts via
  /// [_promptSelectorDialog], then flows the result through
  /// [_applyManualSelector] (live-syncs like a real click would).
  Future<void> _editSelectorManually(
    String currentSelector,
    StepMode mode,
  ) async {
    final result = await _promptSelectorDialog(context, currentSelector);
    if (result == null) return;
    await _applyManualSelector(result, mode);
  }

  /// Parses [html] into [_engineDoc] (or leaves it null if there's nothing
  /// probed yet) — called from each implementer's `initState`.
  void _initEngineDoc(String html) {
    _engineDoc = html.isEmpty ? null : html_parser.parse(html);
  }

  /// Called after every direct `_pendingItem`/`_pendingRelative` mutation
  /// this mixin performs ([_onPickerMessage], [_adjustLevel]'s
  /// tree-derived branch). No-op here; [_DetailsPickerDialogState]
  /// overrides it to live-sync a valid candidate straight into
  /// `_picked`/`_previews` without waiting for an explicit Confirm click.
  /// [_PickerDialogState] (the linear wizard) doesn't override it — its
  /// per-step Confirm button model is unchanged.
  void _pendingCandidateChanged() {}

  /// Whether the currently-armed item-mode step should use
  /// [domItemCandidateLoose] instead of [domItemCandidate] (and the JS
  /// twin's `loose` opt) — true only for rows' "row container" step (see
  /// its own doc comment for why). False here; [_PickerDialogState] (the
  /// linear wizard) has no rows concept and never overrides it.
  /// [_DetailsPickerDialogState] overrides it to `_armed is _ArmedRowsItem`.
  bool get _looseItemMode => false;

  void _onPickerMessage(Map message) {
    final phase = message['phase'];
    final result = message['result'];
    // A WebView click supersedes whatever the tree last picked -- the
    // pending candidate about to be set below came from the live DOM, not
    // engineDoc, so _adjustLevel must go back through the JS round-trip
    // for it, not re-derive from a stale tree node. _liveTreeMatch is
    // re-derived fresh below (from the new candidate, if any) rather than
    // staying cleared, so the tree stays in sync with live clicks too.
    _lastTreeClick = null;
    _liveTreeMatch = null;
    if (phase == 'item') {
      setState(() {
        if (result is! Map) {
          _pendingItem = null;
          return;
        }
        final selector = '${result['selector']}';
        final engineDoc = _engineDoc;
        _pendingItem = (
          selector: selector,
          engineCount: engineDoc == null
              ? -1
              : engineDoc.querySelectorAll(selector).length,
          browserCount: (result['groupSize'] as num?)?.toInt() ?? 0,
        );
        _liveTreeMatch = _firstMatch(_highlightedGroup);
      });
      _pendingCandidateChanged();
    } else if (phase == 'relative') {
      setState(() {
        if (result is! Map) {
          _pendingRelative = null;
          return;
        }
        _pendingRelative = _evaluateRelative(
          '${result['selector']}',
          browserPreview: '${result['preview'] ?? ''}',
        );
        _liveTreeMatch = _firstMatch(_highlightedGroup);
      });
      _pendingCandidateChanged();
    }
  }

  dom.Element? _firstMatch(Set<dom.Element>? group) =>
      group == null || group.isEmpty ? null : group.first;

  Future<void> _setPaused(bool value) async {
    setState(() {
      _paused = value;
      // Whatever was pending was resolved from a click made before the
      // page potentially changed underneath it (a dismissed ad, a
      // navigation) — stale either way once picking resumes.
      _pendingItem = null;
      _pendingRelative = null;
    });
    await _controller?.evaluateJavascript(
      source: 'if (window.__koniPicker) window.__koniPicker.paused = $value;',
    );
  }

  Future<void> _adjustLevel(int delta) async {
    final newLevel = (_minLevel + delta).clamp(0, 6);
    if (newLevel == _minLevel) return;
    // A tree-originated pick re-derives synchronously straight from
    // engineDoc — no WebView round-trip exists to race, so none of the
    // busy-guard machinery below applies.
    final treeNode = _lastTreeClick;
    final doc = _engineDoc;
    if (treeNode != null && doc != null) {
      final item = _looseItemMode
          ? domItemCandidateLoose(doc, treeNode, minLevel: newLevel)
          : domItemCandidate(doc, treeNode, minLevel: newLevel);
      setState(() {
        _minLevel = newLevel;
        _pendingItem = item == null
            ? null
            : (
                selector: item.selector,
                engineCount: item.globalMatchCount,
                browserCount: item.globalMatchCount,
              );
      });
      _pendingCandidateChanged();
      return;
    }
    final controller = _controller;
    if (controller == null || _adjustingLevel) return;
    // _minLevel drives the "narrower" button's enabled state (disabled at
    // 0) — it must go through setState or that button silently stops
    // reflecting reality: still shown enabled, tap does nothing, with no
    // visible cause. This was the actual bug behind "sometimes the arrows
    // don't work".
    setState(() {
      _minLevel = newLevel;
      _adjustingLevel = true;
    });
    try {
      await controller.evaluateJavascript(
        source:
            '''
        (function() {
          var state = window.__koniPicker;
          if (!state || !state.lastClicked) return;
          state.minLevel = $newLevel;
          var item = state.computeItemCandidate(state.lastClicked, { minLevel: $newLevel, loose: state.looseItemMode });
          if (item) { window.__koniHighlightGroup(document.querySelectorAll(item.selector)); }
          else if (window.__koniClearHighlight) { window.__koniClearHighlight(); }
          window.flutter_inappwebview.callHandler('koniPicker', { phase: 'item', result: item });
        })();
        ''',
      );
    } finally {
      if (mounted) setState(() => _adjustingLevel = false);
    }
  }
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({
    required this.url,
    required this.steps,
    required this.engineHtml,
    required this.sourceUsesWebview,
    this.onRequestEnableWebview,
    this.seed,
  });

  final Uri url;
  final List<FieldStep> steps;
  final String engineHtml;
  final bool sourceUsesWebview;
  final VoidCallback? onRequestEnableWebview;

  /// Already-known fields/previews to pre-populate on open — either the
  /// current config's already-picked selectors, or (from "Back to picker")
  /// the in-progress result of the session that was just backed out of.
  /// Doesn't jump [_PickerDialogState._stepIndex] past seeded steps: the
  /// wizard's per-step confirm gate stays exactly as it is, so this mostly
  /// just avoids re-showing a blank optional step (e.g. chapters' date)
  /// that was already skipped/filled before.
  final PickResult? seed;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog>
    with _PickerTreeAndPauseMixin<_PickerDialog> {
  int _stepIndex = 0;

  /// Confirmed selector for the (always-first, when present) item-mode
  /// step, kept separately from [_picked] purely so [_evaluateRelative] has
  /// something to re-verify subsequent relative steps against regardless of
  /// that step's field key.
  String? _itemSelector;
  final Map<String, String> _picked = {};

  FieldStep get _currentStep => widget.steps[_stepIndex];

  /// Every element the DOM tree should tint as "currently matched" — the
  /// tree's counterpart to the WebView's dashed-border group highlight, and
  /// the actual payoff of having a tree at all: confirm an item guess, or a
  /// relative field's pick, by seeing every match at a glance rather than
  /// trusting a bare count. Regenerated from `engineDoc` fresh each build
  /// (cheap: a handful of `querySelectorAll` calls, not held as state that
  /// could go stale).
  @override
  Set<dom.Element>? get _highlightedGroup {
    final doc = _engineDoc;
    if (doc == null) return null;
    if (_currentStep.mode == StepMode.item) {
      final pending = _pendingItem;
      if (pending == null) return null;
      return doc.querySelectorAll(pending.selector).toSet();
    }
    final pending = _pendingRelative;
    final itemSel = _itemSelector;
    if (pending == null || itemSel == null) return null;
    return doc
        .querySelectorAll(itemSel)
        .map((root) => root.querySelector(pending.selector))
        .whereType<dom.Element>()
        .toSet();
  }

  /// A tree-node tap's counterpart to the WebView click handler — computes
  /// the exact same [_PendingItem]/[_PendingRelative] shapes directly from
  /// `engineDoc` via [domItemCandidate]/[domRelativeCandidate] (the Dart
  /// port), so everything downstream (the confirm bar, apply-to-config) is
  /// completely unaware of which input produced the candidate.
  void _onTreeNodeTap(dom.Element el) {
    final doc = _engineDoc;
    if (doc == null) return;
    final step = _currentStep;
    if (step.mode == StepMode.item) {
      final item = domItemCandidate(doc, el, minLevel: _minLevel);
      setState(() {
        _lastTreeClick = el;
        _pendingItem = item == null
            ? null
            : (
                selector: item.selector,
                engineCount: item.globalMatchCount,
                browserCount: item.globalMatchCount,
              );
      });
      _highlightInPage(item?.selector);
      return;
    }
    final itemSel = _itemSelector;
    if (itemSel == null) return;
    final itemRoots = doc.querySelectorAll(itemSel);
    final rel = domRelativeCandidate(
      itemRoots,
      el,
      preferAncestorTag: step.preferAnchorTag ? 'a' : null,
      previewAttr: step.attr,
    );
    setState(() {
      _lastTreeClick = el;
      _pendingRelative = rel == null
          ? null
          : (
              selector: rel.selector,
              engineHits: rel.matchCount,
              totalItems: rel.totalItems,
              preview: rel.preview,
            );
    });
    _highlightInPage(rel?.selector);
  }

  @override
  void initState() {
    super.initState();
    _initEngineDoc(widget.engineHtml);
    final seed = widget.seed;
    if (seed != null) {
      _picked.addAll(seed.fields);
      _previews.addAll(seed.previews);
    }
  }

  /// Re-verifies [selector] against every item root in `engineHtml` (the
  /// engine's own parse), the way `ConfigForm`'s `_SelectorMatch` validates
  /// a hand-typed selector — the picker just does it one step earlier, and
  /// scores every item root instead of only the first. [browserPreview] is
  /// what the picker script itself already extracted client-side (see
  /// `previewOf` in `_pickerScript`); used whenever there's no probed HTML
  /// to check against yet, or the engine-side pass matched but couldn't
  /// extract anything (e.g. a lazy-loaded attribute the static fetch never
  /// populates) — always something to show rather than a blank preview.
  @override
  _PendingRelative _evaluateRelative(
    String selector, {
    required String browserPreview,
  }) {
    final engineDoc = _engineDoc;
    final itemSel = _itemSelector;
    if (engineDoc == null || itemSel == null) {
      return (
        selector: selector,
        engineHits: -1,
        totalItems: -1,
        preview: browserPreview,
      );
    }
    final items = engineDoc.querySelectorAll(itemSel);
    final attr = _currentStep.attr;
    var hits = 0;
    var preview = '';
    for (final item in items) {
      final matches = item.querySelectorAll(selector);
      if (matches.isEmpty) continue;
      hits++;
      if (preview.isEmpty) {
        final first = matches.first;
        preview = attr.isEmpty
            ? first.text.trim().replaceAll(RegExp(r'\s+'), ' ')
            : (first.attributes[attr] ?? '');
      }
    }
    if (preview.isEmpty) preview = browserPreview;
    return (
      selector: selector,
      engineHits: hits,
      totalItems: items.length,
      preview: preview,
    );
  }

  /// Pushes the current step's capture attribute + link-preference into the
  /// page's picker state on every step transition, so a click's preview
  /// always matches what this step is actually capturing, not a stale value
  /// left over from the previous one.
  Future<void> _pushStepState() async {
    final step = _currentStep;
    final tag = step.preferAnchorTag ? 'a' : null;
    await _controller?.evaluateJavascript(
      source:
          '''
      if (window.__koniPicker) {
        window.__koniPicker.preferAncestorTag = ${tag == null ? 'null' : jsonEncode(tag)};
        window.__koniPicker.previewAttr = ${jsonEncode(step.attr)};
      }
      ''',
    );
  }

  /// Re-establishes the picker's JS-side state after every `onLoadStop` —
  /// including the very first one, where it's a harmless no-op against
  /// fresh defaults. Necessary because a navigation *inside* the picker
  /// WebView (confirmed reachable: an ad's own dismiss link, or any other
  /// in-page link a paused click let through) starts a fresh JS realm —
  /// `_pickerScript`'s `__koniPickerInstalled` guard only prevents a
  /// *second* injection on the *same* load, it does nothing to carry state
  /// over from before the navigation. Without this, `paused` silently
  /// resets to `false` (resurrecting the exact click-trap the pause toggle
  /// exists to escape, mid-navigation, with the toggle still showing
  /// "resume") and a confirmed item step's `itemRoots` disappears (every
  /// further relative click reports back as an unmatched item-phase click,
  /// with the Confirm bar just sitting dead). Any pending candidate is
  /// cleared too — it was resolved from a click on a page that may no
  /// longer be the one now loaded.
  Future<void> _resyncPickerState() async {
    // Called from onLoadStop, which can fire after the dialog closes
    // (a slow navigation completing post-Cancel) — guard before touching
    // State the same way _advance does.
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    if (_pendingItem != null || _pendingRelative != null) {
      setState(() {
        _pendingItem = null;
        _pendingRelative = null;
      });
    }
    final itemSel = _itemSelector;
    await controller.evaluateJavascript(
      source:
          '''
      if (window.__koniPicker) {
        window.__koniPicker.paused = $_paused;
        window.__koniPicker.minLevel = $_minLevel;
        ${itemSel == null ? '' : 'window.__koniPicker.itemRoots = Array.prototype.slice.call(document.querySelectorAll(${jsonEncode(itemSel)}));'}
      }
      ''',
    );
    await _pushStepState();
  }

  Future<void> _confirmCurrentStep() async {
    final step = _currentStep;
    if (step.mode == StepMode.item) {
      final pending = _pendingItem;
      final controller = _controller;
      if (pending == null || controller == null) return;
      _picked[step.key] = pending.selector;
      if (step.attr.isNotEmpty) _picked[step.attrKey] = step.attr;
      _previews[step.key] = _itemPreview(pending, step);
      setState(() {
        _itemSelector = pending.selector;
        _pendingItem = null;
        _pendingRelative = null;
      });
      await controller.evaluateJavascript(
        source:
            '''
        window.__koniPicker.itemRoots = Array.prototype.slice.call(document.querySelectorAll(${jsonEncode(pending.selector)}));
        if (window.__koniClearHighlight) window.__koniClearHighlight();
        ''',
      );
    } else {
      final pending = _pendingRelative;
      if (pending == null) return;
      _picked[step.key] = pending.selector;
      if (step.attr.isNotEmpty) _picked[step.attrKey] = step.attr;
      _previews[step.key] = pending.preview;
      setState(() => _pendingRelative = null);
    }
    await _advance();
  }

  /// Skips the current step without recording a value — only ever offered
  /// for [FieldStep.optional] relative steps (see [_confirmBar]).
  Future<void> _skipCurrentStep() async {
    setState(() => _pendingRelative = null);
    await _advance();
  }

  Future<void> _advance() async {
    // Every caller reaches this after its own await (a JS round-trip) —
    // the dialog can close (Cancel, or the whole screen navigating away)
    // during that gap, and touching setState/Navigator on a disposed
    // State throws in debug. One guard here covers every caller instead
    // of scattering the same check after each of their awaits.
    if (!mounted) return;
    final next = _stepIndex + 1;
    if (next >= widget.steps.length) {
      Navigator.of(
        context,
      ).pop<PickResult>((fields: Map.of(_picked), previews: Map.of(_previews)));
      return;
    }
    setState(() => _stepIndex = next);
    await _pushStepState();
  }

  Future<void> _startOver() async {
    setState(() {
      _stepIndex = 0;
      _minLevel = 0;
      _itemSelector = null;
      _picked.clear();
      _previews.clear();
      _pendingItem = null;
      _pendingRelative = null;
      _lastTreeClick = null;
      _liveTreeMatch = null;
    });
    await _controller?.evaluateJavascript(
      source: '''
      if (window.__koniPicker) {
        window.__koniPicker.itemRoots = null;
        window.__koniPicker.minLevel = 0;
        window.__koniPicker.lastClicked = null;
      }
      if (window.__koniClearHighlight) window.__koniClearHighlight();
      ''',
    );
    await _pushStepState();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = _currentStep;
    final doc = _engineDoc;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: doc != null && _showTree ? 1400 : 900,
          maxHeight: 760,
        ),
        child: Column(
          children: [
            AppBar(
              title: Text('Pick the ${step.fieldLabel} — ${widget.url.host}'),
              automaticallyImplyLeading: false,
              actions: [
                if (doc != null)
                  IconButton(
                    icon: Icon(
                      _showTree
                          ? Icons.account_tree
                          : Icons.account_tree_outlined,
                    ),
                    tooltip: _showTree
                        ? 'Hide the parsed DOM tree'
                        : 'Show the parsed DOM tree — click a node to pick '
                              'it directly, works even where the live page '
                              'and the engine\'s parse disagree',
                    onPressed: () => setState(() => _showTree = !_showTree),
                  ),
                _pausePickingAction(paused: _paused, onChanged: _setPaused),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_paused)
                    _pausedNotice(theme)
                  else
                    Text(step.instruction, style: theme.textTheme.bodySmall),
                  if (widget.engineHtml.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'No probed HTML yet — match counts below aren\'t '
                        'verified against a real probe, only the browser.',
                        style: theme.textTheme.bodySmall!.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(widget.url.toString()),
                        cachePolicy: URLRequestCachePolicy
                            .RELOAD_IGNORING_LOCAL_CACHE_DATA,
                      ),
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        controller.addJavaScriptHandler(
                          handlerName: 'koniPicker',
                          callback: (args) {
                            if (args.isNotEmpty && args[0] is Map) {
                              _onPickerMessage(args[0] as Map);
                            }
                            return null;
                          },
                        );
                      },
                      onLoadStop: (controller, _) async {
                        await controller.evaluateJavascript(
                          source: _pickerScript,
                        );
                        await _resyncPickerState();
                      },
                    ),
                  ),
                  if (doc != null && _showTree) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 360,
                      child: DomTreePanel(
                        root: doc.body ?? doc.documentElement!,
                        onTap: _onTreeNodeTap,
                        selected: _treeSelected,
                        highlightedGroup: _highlightedGroup,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _confirmBar(theme),
          ],
        ),
      ),
    );
  }

  Widget _confirmBar(ThemeData theme) {
    final step = _currentStep;
    final nextLabel = _stepIndex + 1 < widget.steps.length
        ? widget.steps[_stepIndex + 1].fieldLabel
        : null;
    final confirmLabel = nextLabel == null
        ? 'Confirm ${step.fieldLabel} → finish'
        : 'Confirm ${step.fieldLabel} → next: $nextLabel';
    if (step.mode == StepMode.item) {
      final pending = _pendingItem;
      final verified = widget.engineHtml.isNotEmpty;
      final canConfirm =
          pending != null && (verified ? pending.engineCount > 0 : true);
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pending != null)
              _itemSummary(theme, pending)
            else
              Text(
                'No repeating group found at this level. Click a card '
                'directly, or try ▲ for a wider ancestor.',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: 'Try a narrower ancestor',
                  icon: _adjustingLevel
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.unfold_less),
                  onPressed: (_minLevel > 0 && !_adjustingLevel)
                      ? () => _adjustLevel(-1)
                      : null,
                ),
                IconButton(
                  tooltip: 'Try a wider ancestor',
                  icon: const Icon(Icons.unfold_more),
                  onPressed: (_minLevel < 6 && !_adjustingLevel)
                      ? () => _adjustLevel(1)
                      : null,
                ),
                IconButton(
                  tooltip: 'Edit the selector by hand',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: pending == null
                      ? null
                      : () =>
                            _editSelectorManually(pending.selector, step.mode),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: canConfirm ? _confirmCurrentStep : null,
                  child: Text(confirmLabel),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final pending = _pendingRelative;
    final verified = widget.engineHtml.isNotEmpty;
    final canConfirm =
        pending != null && (verified ? pending.engineHits > 0 : true);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending != null) _relativeSummary(theme, pending, step),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: _startOver,
                child: const Text('Start over'),
              ),
              if (step.optional)
                TextButton(
                  onPressed: _skipCurrentStep,
                  child: const Text('Skip'),
                ),
              IconButton(
                tooltip: 'Edit the selector by hand',
                icon: const Icon(Icons.edit_outlined),
                onPressed: pending == null
                    ? null
                    : () => _editSelectorManually(pending.selector, step.mode),
              ),
              const Spacer(),
              FilledButton(
                onPressed: canConfirm ? _confirmCurrentStep : null,
                child: Text(confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemSummary(ThemeData theme, _PendingItem pending) =>
      _pendingItemSummary(
        theme,
        pending,
        verified: widget.engineHtml.isNotEmpty,
        sourceUsesWebview: widget.sourceUsesWebview,
        onRequestEnableWebview: widget.onRequestEnableWebview == null
            ? null
            : _requestEnableWebview,
      );

  Widget _relativeSummary(
    ThemeData theme,
    _PendingRelative pending,
    FieldStep step,
  ) => _pendingRelativeSummary(
    theme,
    pending,
    verified: widget.engineHtml.isNotEmpty,
    sourceUsesWebview: widget.sourceUsesWebview,
    onRequestEnableWebview: widget.onRequestEnableWebview == null
        ? null
        : _requestEnableWebview,
    previewIsImage: step.previewIsImage,
    pageUrl: widget.url,
  );

  /// The webview-mismatch callout's action: reports the request up to
  /// whoever opened this dialog (owns flipping the config flag and
  /// retrying — this dialog only ever surfaces the suggestion) and closes,
  /// same as a cancel.
  void _requestEnableWebview() {
    widget.onRequestEnableWebview?.call();
    Navigator.of(context).pop<PickResult>(null);
  }
}

/// Shared between [_PickerDialog] and [_DetailsPickerDialog]: the AppBar
/// toggle that lets clicks through to the page untouched (see `paused` in
/// [_pickerScript]) instead of being captured for picking — for anything
/// that needs a real click to get past (an ad overlay, a cookie banner).
Widget _pausePickingAction({
  required bool paused,
  required ValueChanged<bool> onChanged,
}) => IconButton(
  icon: Icon(paused ? Icons.play_circle_outline : Icons.pause_circle_outline),
  tooltip: paused
      ? 'Resume picking (clicks are currently going straight to the page)'
      : 'Pause picking to interact with the page normally — e.g. to '
            'dismiss a popup ad or cookie banner blocking the content',
  onPressed: () => onChanged(!paused),
);

/// One line summarizing why picking is paused, shown instead of the current
/// step's own instruction — shared between [_PickerDialog] and
/// [_DetailsPickerDialog].
Widget _pausedNotice(ThemeData theme) => Text(
  'Picking is paused — clicks go straight to the page. Resume (▶ above) '
  'when you\'re ready to pick again.',
  style: theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.error),
);

/// Shared between [_PickerDialog] and [_DetailsPickerDialog]: one line
/// summarizing a not-yet-confirmed item-container candidate — or, when
/// [sourceUsesWebview] is false and the browser clearly sees items the
/// last probe's `engineHtml` doesn't at all, [_webviewMismatchCallout]
/// instead: that specific pattern means the fetch mode this source is
/// using doesn't see what the browser sees, not a bad selector.
Widget _pendingItemSummary(
  ThemeData theme,
  _PendingItem pending, {
  required bool verified,
  bool sourceUsesWebview = true,
  VoidCallback? onRequestEnableWebview,
}) {
  if (verified &&
      !sourceUsesWebview &&
      onRequestEnableWebview != null &&
      pending.browserCount > 0 &&
      pending.engineCount == 0) {
    return _webviewMismatchCallout(
      theme,
      message:
          'The browser found ${pending.browserCount} item'
          '${pending.browserCount == 1 ? '' : 's'} here, but the last '
          'plain-fetch probe found none — this site likely needs '
          '"webview: true".',
      onRequestEnableWebview: onRequestEnableWebview,
    );
  }
  final ok = verified ? pending.engineCount > 0 : pending.browserCount > 0;
  final text = verified
      ? '${pending.selector}  ·  ${pending.engineCount} match'
            '${pending.engineCount == 1 ? '' : 'es'} in last probe'
      : '${pending.selector}  ·  ${pending.browserCount} on page '
            '(unverified)';
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        ok ? Icons.check_circle_outline : Icons.error_outline,
        size: 15,
        color: ok ? Colors.green : theme.colorScheme.error,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: theme.textTheme.bodySmall!.copyWith(
            fontFamily: 'monospace',
            color: ok ? null : theme.colorScheme.error,
          ),
        ),
      ),
    ],
  );
}

/// The "this site might need webview: true" callout — see
/// [_pendingItemSummary]'s doc for the condition that triggers it.
Widget _webviewMismatchCallout(
  ThemeData theme, {
  required String message,
  required VoidCallback onRequestEnableWebview,
}) {
  return Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.travel_explore, size: 16, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onRequestEnableWebview,
                child: const Text('Enable webview & retry'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Shared between [_PickerDialog] and [_DetailsPickerDialog]: one line
/// summarizing a not-yet-confirmed relative-field candidate — or, same
/// condition as [_pendingItemSummary], [_webviewMismatchCallout] instead
/// when the browser clearly computed a real value (a non-empty preview —
/// see `previewOf` in [_pickerScript], populated client-side regardless of
/// any engine cross-check) that the last probe's `engineHtml` doesn't
/// contain at all.
Widget _pendingRelativeSummary(
  ThemeData theme,
  _PendingRelative pending, {
  required bool verified,
  bool sourceUsesWebview = true,
  VoidCallback? onRequestEnableWebview,
  bool previewIsImage = false,
  Uri? pageUrl,
}) {
  if (verified &&
      !sourceUsesWebview &&
      onRequestEnableWebview != null &&
      pending.engineHits == 0 &&
      pending.preview.isNotEmpty) {
    return _webviewMismatchCallout(
      theme,
      message:
          'The browser sees a real value here ("${pending.preview}"), but '
          'the last plain-fetch probe found nothing at all — this site '
          'likely needs "webview: true".',
      onRequestEnableWebview: onRequestEnableWebview,
    );
  }
  final ok = verified
      ? (pending.engineHits == pending.totalItems && pending.totalItems > 0)
      : true;
  final text = verified
      ? '${pending.selector}  ·  ${pending.engineHits}/${pending.totalItems}'
            ' items matched'
      : '${pending.selector}  (unverified — no probe yet)';
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
            size: 15,
            color: ok ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall!.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
      if (pending.preview.isNotEmpty) ...[
        const SizedBox(height: 6),
        _previewValue(
          theme,
          pending.preview,
          previewIsImage: previewIsImage,
          pageUrl: pageUrl,
        ),
      ],
    ],
  );
}

/// The picked/pending preview value, pulled out into its own visually
/// distinct block — previously crammed into `_pendingRelativeSummary`'s
/// single monospace status line (`selector · N/M items matched · preview`),
/// small and easy to miss next to the selector and match count. For an
/// image-flavored field ([FieldStep.previewIsImage]) with a URL that
/// resolves against [pageUrl], renders an actual thumbnail instead of a
/// bare URL string — `errorBuilder` covers a broken/expired cover URL so it
/// can't break the dialog.
Widget _previewValue(
  ThemeData theme,
  String preview, {
  required bool previewIsImage,
  Uri? pageUrl,
}) {
  if (previewIsImage) {
    final resolved = _resolveImageUrl(preview, pageUrl);
    if (resolved != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.network(
              resolved.toString(),
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                child: Icon(
                  Icons.broken_image_outlined,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(preview, style: theme.textTheme.bodySmall)),
        ],
      );
    }
  }
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      preview,
      style: theme.textTheme.bodyMedium,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

/// Resolves a possibly-relative preview value (e.g. a `src` attribute)
/// against [pageUrl] — the page being picked from — into something
/// `Image.network` could plausibly fetch. Null when that's not possible
/// (no scheme and no [pageUrl] to resolve against).
Uri? _resolveImageUrl(String preview, Uri? pageUrl) {
  final ref = Uri.tryParse(preview);
  if (ref == null) return null;
  if (ref.hasScheme) return ref;
  return pageUrl?.resolveUri(ref);
}

// ── Details field-palette picker ────────────────────────────────────────────

/// `details`: independent single-element fields, picked in any order and
/// individually skippable — unlike popular/chapters/pages there's no
/// repeating item to detect first, so [_DetailsPickerDialog] presents a
/// palette instead of a linear wizard. `genreSelector` is the one field
/// that's still `item`-mode: the engine reads it as an unlabeled *list*
/// (every matching element, not just one), the same repeating-group shape
/// as `pages`' `imageSelector` — genre tags are a group, not a single value.
/// The rarer `banner`/`background`/`unlistedChapters`/`statusMap` fields
/// stay hand-edited in the form; not every source needs them, and they
/// don't fit this shape as cleanly. `rows` — a label/value extraction for
/// sites where different fields' rows are structurally identical (see
/// [RowsFieldKey]) — has its own picking mode inside the same dialog,
/// below.
const detailsFields = <FieldStep>[
  FieldStep(
    key: 'titleSelector',
    instruction: 'Click the manga\'s title.',
    fieldLabel: 'Title',
    mode: StepMode.relative,
  ),
  FieldStep(
    key: 'authorSelector',
    instruction: 'Click the author/artist credit.',
    fieldLabel: 'Author',
    mode: StepMode.relative,
  ),
  FieldStep(
    key: 'descriptionSelector',
    instruction: 'Click the description/summary text.',
    fieldLabel: 'Description',
    mode: StepMode.relative,
  ),
  FieldStep(
    key: 'coverSelector',
    instruction: 'Click the cover image.',
    fieldLabel: 'Cover',
    mode: StepMode.relative,
    attr: 'src',
    previewIsImage: true,
  ),
  FieldStep(
    key: 'genreSelector',
    instruction: 'Click one genre/tag — its whole repeating group is captured.',
    fieldLabel: 'Genre',
    mode: StepMode.item,
  ),
];

/// The four `RowsConfig.fields` keys `_applyRows` (`lib/src/
/// config_source.dart`) actually recognizes in its `switch (field)` — any
/// other key would be silently collected into that function's local
/// `values` map and then matched by no case at all, dead weight. Not every
/// value of [RowsFieldKey] is necessarily configured in a given pick
/// session — each is independently optional, mirroring [detailsFields]'
/// own per-field skippability.
enum RowsFieldKey { author, status, genres, description }

extension on RowsFieldKey {
  /// The literal JSON key under `RowsConfig.fields`.
  String get configKey => name;

  String get label => switch (this) {
    RowsFieldKey.author => 'Author',
    RowsFieldKey.status => 'Status',
    RowsFieldKey.genres => 'Genres',
    RowsFieldKey.description => 'Description',
  };

  /// Whether `RowField.join` has any effect on this field at scrape time
  /// (`_applyRows`): author/description join their found values into one
  /// string; genres stays a list (join ignored); status only ever reads
  /// `found.first` (join ignored). Showing a join control for the latter
  /// two would be misleading — it'd do nothing.
  bool get usesJoin =>
      this == RowsFieldKey.author || this == RowsFieldKey.description;
}

/// One field's in-progress `rows` configuration — a mutable working copy
/// of [RowField], built up chip-by-chip (see [RowsFieldKey]) before
/// [_RowsDraft.build] finalizes it. Empty [labels] means the user hasn't
/// associated this field with any row label yet, equivalent to not
/// configuring it via rows at all.
class _RowFieldDraft {
  _RowFieldDraft({
    Set<String>? labels,
    this.valueSelector = '',
    this.join = ', ',
  }) : labels = labels ?? {};

  final Set<String> labels;
  String valueSelector;
  String join;

  RowField? build() => labels.isEmpty
      ? null
      : RowField(
          labels: labels.toList()..sort(),
          valueSelector: valueSelector,
          join: join,
        );
}

/// The whole in-progress `rows` block. [itemSelector] null means the row
/// container hasn't been picked yet — nothing else in here is usable
/// until it is. [labelSelector] always has a workable value (`RowsConfig`'s
/// own schema default, `'strong'`), so the label step needs no click to
/// produce a valid candidate — see the arm-time auto-evaluate in
/// [_DetailsPickerDialogState._armWith].
class _RowsDraft {
  _RowsDraft({
    this.itemSelector,
    this.labelSelector = 'strong',
    Map<RowsFieldKey, _RowFieldDraft>? fields,
  }) : fields = fields ?? {};

  String? itemSelector;
  String labelSelector;
  final Map<RowsFieldKey, _RowFieldDraft> fields;

  int get configuredFieldCount =>
      fields.values.where((f) => f.labels.isNotEmpty).length;

  /// Null when there's no [itemSelector] yet, or no field has ever been
  /// given at least one label — an itemSelector-only block with nothing to
  /// route to it would extract nothing at scrape time.
  RowsConfig? build() {
    final item = itemSelector;
    if (item == null || item.isEmpty) return null;
    final builtFields = <String, RowField>{};
    for (final entry in fields.entries) {
      final field = entry.value.build();
      if (field != null) builtFields[entry.key.configKey] = field;
    }
    if (builtFields.isEmpty) return null;
    return RowsConfig(
      itemSelector: item,
      labelSelector: labelSelector,
      fields: builtFields,
    );
  }

  factory _RowsDraft.fromConfig(RowsConfig? config) {
    if (config == null) return _RowsDraft();
    final fields = <RowsFieldKey, _RowFieldDraft>{};
    for (final key in RowsFieldKey.values) {
      final field = config.fields[key.configKey];
      if (field == null) continue;
      fields[key] = _RowFieldDraft(
        labels: field.labels.toSet(),
        valueSelector: field.valueSelector,
        join: field.join,
      );
    }
    return _RowsDraft(
      itemSelector: config.itemSelector,
      labelSelector: config.labelSelector,
      fields: fields,
    );
  }
}

/// A row-structure candidate proposed by the most recent click while a
/// rows-eligible field is armed (see `_runRowsDetection`) — surfaced as
/// the confirm bar's "Found N values via a nearby label" card instead of
/// the plain flat-pick summary. Nothing here is committed into `_rows`
/// until the user answers Yes/Add/Replace (or Cancel/re-arming discards
/// it) — this is a proposal, not a mutation.
class _RowsDetection {
  const _RowsDetection({
    required this.rowsField,
    required this.containerSelector,
    required this.labelText,
    required this.valueSelector,
    required this.previewIfAdded,
    required this.previewIfReplaced,
    required this.conflictsWithContainer,
  });

  final RowsFieldKey rowsField;
  final String containerSelector;
  final String labelText;
  final String? valueSelector;

  /// What this field would capture if [labelText] were added *alongside*
  /// its already-configured labels (identical to [previewIfReplaced] when
  /// there are no prior labels yet).
  final RowsFieldSimulation previewIfAdded;

  /// What this field would capture if [labelText] *replaced* its
  /// already-configured labels.
  final RowsFieldSimulation previewIfReplaced;

  /// True when [containerSelector] disagrees with the already-established
  /// `rows.itemSelector` (only possible via the live-click detection path,
  /// which always re-guesses from scratch — see `_runRowsDetection`'s doc
  /// comment). The label/value here were computed against the *wrong*
  /// row grouping in this case and must never be trusted/synced.
  final bool conflictsWithContainer;
}

/// What's currently armed for picking — unifies the five flat
/// [detailsFields] chips with the one rows-only field (`Status`, which has
/// no flat `DetailsConfig` selector of its own) behind one shape, so
/// [_DetailsPickerDialogState]'s per-click/per-confirm methods each need
/// one dispatch instead of a parallel branch apiece — the exact "one call
/// site missed the pattern" bug shape this file has hit more than once
/// already (see `FieldStep.attrKey`'s doc comment).
///
/// There is no longer a separate "rows mode" to arm: every click made
/// while a rows-eligible field ([_DetailsPickerDialogState._rowsFieldFor]/
/// `Status`) is armed automatically attempts row-structure detection in
/// the background (see `_runRowsDetection`) — the row container/label
/// steps that used to be their own arm-able variants are proposed and
/// applied as a side effect of an ordinary field arm now, never armed on
/// their own.
sealed class _Armed {
  const _Armed();
}

class _ArmedFlatField extends _Armed {
  const _ArmedFlatField(this.field);
  final FieldStep field;
}

/// Arming the `Status` chip — the one details field with no flat
/// `DetailsConfig` selector at all (`_applyRows`/`RowsConfig` is its only
/// path). Every click here is interpreted purely as a row-detection
/// attempt against [RowsFieldKey.status] and is never written to
/// `_picked` — kept as its own leaf (not `_ArmedFlatField` with a
/// synthetic [FieldStep]) so `_syncPendingIfValid`'s flat-write branch can
/// never accidentally create a dead `_picked['statusSelector']` entry the
/// engine has no field to read back into.
class _ArmedStatus extends _Armed {
  const _ArmedStatus();
}

/// [_DetailsPickerDialogState._armSnapshot] — what Cancel restores.
/// Captures every field one arm session could plausibly mutate: a flat
/// field's selector/attr/preview, plus — since a rows-eligible field's arm
/// session can also seed/extend `_rows` as a side effect of detection now
/// — the shared row container/label selectors and this field's own
/// [_RowFieldDraft], all as they stood the moment the arm started.
class _ArmSnapshot {
  const _ArmSnapshot({
    this.flatSelector,
    this.flatAttr,
    this.flatPreview,
    this.rowsItemSelector,
    this.rowsLabelSelector,
    this.rowsFieldDraft,
    this.rowsFieldPreview,
  });
  final String? flatSelector;
  final String? flatAttr;
  final String? flatPreview;
  final String? rowsItemSelector;
  final String? rowsLabelSelector;
  final _RowFieldDraft? rowsFieldDraft;
  final String? rowsFieldPreview;
}

/// Opens a visible WebView on [url] and lets the user pick as many of
/// [detailsFields] as apply to this site, in any order, plus optionally a
/// `rows` block (see [RowsFieldKey]) — see [_DetailsPickerDialog]. Returns
/// null if cancelled or [context] is unmounted; otherwise a
/// [DetailsPickResult] with an entry for every field that was picked (a
/// skipped field simply has none). Same [engineHtml] cross-check and
/// [_solveChain] serialization as [pickFields].
Future<DetailsPickResult?> pickDetailsFields(
  Uri url, {
  required String engineHtml,
  required bool sourceUsesWebview,
  VoidCallback? onRequestEnableWebview,
  BuildContext? context,
  PickResult? seed,
  RowsConfig? seedRows,
}) {
  final result = _solveChain.then(
    (_) => _pickDetailsFieldsOne(
      url,
      engineHtml,
      sourceUsesWebview,
      onRequestEnableWebview,
      // ignore: use_build_context_synchronously
      context,
      seed,
      seedRows,
    ),
  );
  _solveChain = result.then((_) {}, onError: (_) {});
  return result;
}

Future<DetailsPickResult?> _pickDetailsFieldsOne(
  Uri url,
  String engineHtml,
  bool sourceUsesWebview,
  VoidCallback? onRequestEnableWebview,
  BuildContext? context,
  PickResult? seed,
  RowsConfig? seedRows,
) async {
  if (!cloudflareSolveSupported) return null;
  if (context == null || !context.mounted) return null;
  return showDialog<DetailsPickResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DetailsPickerDialog(
      url: url,
      engineHtml: engineHtml,
      sourceUsesWebview: sourceUsesWebview,
      onRequestEnableWebview: onRequestEnableWebview,
      seed: seed,
      seedRows: seedRows,
    ),
  );
}

class _DetailsPickerDialog extends StatefulWidget {
  const _DetailsPickerDialog({
    required this.url,
    required this.engineHtml,
    required this.sourceUsesWebview,
    this.onRequestEnableWebview,
    this.seed,
    this.seedRows,
  });

  final Uri url;
  final String engineHtml;
  final bool sourceUsesWebview;
  final VoidCallback? onRequestEnableWebview;

  /// Already-known fields to pre-populate the palette with — the current
  /// config's already-picked selectors, or (from "Back to picker") the
  /// in-progress result of the session just backed out of. A config-seed
  /// has no previews (nothing was ever captured for them); see
  /// [_DetailsPickerDialogState.initState]'s backfill pass.
  final PickResult? seed;

  /// [seed]'s counterpart for the `rows` block — the current config's
  /// already-picked `details.rows`, or the in-progress draft from a
  /// "Back to picker" reopen.
  final RowsConfig? seedRows;

  @override
  State<_DetailsPickerDialog> createState() => _DetailsPickerDialogState();
}

class _DetailsPickerDialogState extends State<_DetailsPickerDialog>
    with _PickerTreeAndPauseMixin<_DetailsPickerDialog> {
  /// What's currently armed for picking — a flat [detailsFields] chip or
  /// `Status` (see [_Armed]). Null between picks.
  _Armed? _armed;

  final Map<String, String> _picked = {};

  /// The in-progress `rows` block — see [_RowsDraft].
  _RowsDraft _rows = _RowsDraft();

  /// The most recent click's row-structure proposal, if any — see
  /// [_RowsDetection] and `_runRowsDetection`. Cleared on every re-arm.
  _RowsDetection? _rowsDetection;

  /// Guards the one async detection path (a live-page item-mode click,
  /// e.g. Genre) against a stale reply: a second click before the first's
  /// `evaluateJavascript` round-trip resolves must not let the older
  /// result overwrite the newer one — same pattern as [_adjustingLevel].
  int _detectionRequestId = 0;

  /// Whether the collapsible row-container/label/multi-label/value-
  /// selector section is expanded — collapsed by default; auto-opens only
  /// when `Status` detection fails outright (see `_runRowsDetection`),
  /// since Status has no flat fallback to quietly keep instead.
  bool _adjustOpen = false;

  /// One persistent `join` text-field controller per field — created
  /// lazily, reused across rebuilds (a fresh `TextEditingController` every
  /// build would reset the cursor/selection on every keystroke).
  final Map<RowsFieldKey, TextEditingController> _joinControllers = {};

  TextEditingController _joinController(RowsFieldKey field) =>
      _joinControllers.putIfAbsent(
        field,
        () => TextEditingController(text: _rows.fields[field]?.join ?? ', '),
      );

  @override
  void dispose() {
    for (final controller in _joinControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// [_armed]'s prior state, captured when arming starts — under live-sync
  /// (see [_syncPendingIfValid]) a valid candidate overwrites whatever
  /// [_armed] points at the moment it's known, so Cancel needs something to
  /// restore rather than relying on "nothing was written yet" (true under
  /// the old explicit-Confirm model, not this one). See [_ArmSnapshot].
  _ArmSnapshot? _armSnapshot;

  StepMode get _armedMode => switch (_armed) {
    _ArmedFlatField(:final field) => field.mode,
    _ArmedStatus() => StepMode.relative,
    null => StepMode.relative,
  };

  /// `RowField` has no attribute-capture concept at all — `_applyRows`
  /// always reads `.text.trim()` — so `Status` reads `''` here too; only a
  /// flat field (e.g. `coverSelector`'s `src`) ever has a real one.
  String get _armedAttr => switch (_armed) {
    _ArmedFlatField(:final field) => field.attr,
    _ => '',
  };

  bool get _armedPreviewIsImage => switch (_armed) {
    _ArmedFlatField(:final field) => field.previewIsImage,
    _ => false,
  };

  String get _armedInstruction => switch (_armed) {
    _ArmedFlatField(:final field) => field.instruction,
    _ArmedStatus() =>
      'Click the status text on the page (e.g. "Ongoing"). If it sits in a '
          'labeled row like the other rows-based fields, it\'s detected '
          'automatically.',
    null => '',
  };

  String get _armedFieldLabel => switch (_armed) {
    _ArmedFlatField(:final field) => field.fieldLabel,
    _ArmedStatus() => 'Status',
    null => '',
  };

  /// [_PickerDialogState._highlightedGroup]'s counterpart: for whatever's
  /// armed. Every arm is single-global-root now (`[doc.body]`) — rows
  /// detection runs after the fact on whatever was clicked, it no longer
  /// scopes the click itself the way the old label/value sub-steps did.
  /// Once a non-conflicting rows detection exists, it wins over the flat
  /// item-mode candidate: for an item-mode field like Genre, the flat
  /// candidate is frequently *unscoped* on real sites (e.g. one live source's
  /// tag/author `<span>`s share no distinguishing class at any ancestor
  /// level — a long-pinned, deliberate "known gap" `domItemCandidate`
  /// alone can't close), so tinting *its* group would highlight unrelated
  /// rows (confirmed live: clicking a genre tag lit up the Author row
  /// too). The rows-matched row(s) are the honest, correctly-scoped
  /// answer once available.
  @override
  Set<dom.Element>? get _highlightedGroup {
    final doc = _engineDoc;
    final body = doc?.body;
    if (doc == null || body == null || _armed == null) return null;
    final detection = _rowsDetection;
    if (detection != null && !detection.conflictsWithContainer) {
      return rowsMatchingLabels(
        doc.querySelectorAll(detection.containerSelector),
        _rows.labelSelector,
        {detection.labelText},
      ).toSet();
    }
    if (_armedMode == StepMode.item) {
      final pending = _pendingItem;
      if (pending == null) return null;
      return doc.querySelectorAll(pending.selector).toSet();
    }
    final pending = _pendingRelative;
    if (pending == null) return null;
    return [body]
        .map((r) => r.querySelector(pending.selector))
        .whereType<dom.Element>()
        .toSet();
  }

  /// [_PickerDialogState._onTreeNodeTap]'s counterpart: whatever's armed
  /// decides item-detection vs. a whole-document relative pick.
  void _onTreeNodeTap(dom.Element el) {
    final doc = _engineDoc;
    if (doc == null || _armed == null) return;
    if (_armedMode == StepMode.item) {
      final item = domItemCandidate(doc, el, minLevel: _minLevel);
      setState(() {
        _lastTreeClick = el;
        _pendingItem = item == null
            ? null
            : (
                selector: item.selector,
                engineCount: item.globalMatchCount,
                browserCount: item.globalMatchCount,
              );
      });
      _highlightInPage(item?.selector);
      _pendingCandidateChanged();
      return;
    }
    final body = doc.body;
    if (body == null) return;
    final rel = domRelativeCandidate([body], el, previewAttr: _armedAttr);
    setState(() {
      _lastTreeClick = el;
      _pendingRelative = rel == null
          ? null
          : (
              selector: rel.selector,
              engineHits: rel.matchCount,
              totalItems: rel.totalItems,
              preview: rel.preview,
            );
    });
    _highlightInPage(rel?.selector);
    _pendingCandidateChanged();
  }

  @override
  void initState() {
    super.initState();
    _initEngineDoc(widget.engineHtml);
    final seed = widget.seed;
    if (seed != null) {
      _picked.addAll(seed.fields);
      _previews.addAll(seed.previews);
      _backfillMissingPreviews();
    }
    final seedRows = widget.seedRows;
    if (seedRows != null) {
      _rows = _RowsDraft.fromConfig(seedRows);
      _backfillRowsPreviews();
    }
  }

  /// [_backfillMissingPreviews]'s counterpart for a seeded `rows` block —
  /// nothing was ever captured for it either. Reuses the same simulation
  /// the field-value arm's live-sync gate runs, so a reopened, untouched
  /// rows field shows the exact same preview it would if the user had
  /// just picked it.
  void _backfillRowsPreviews() {
    final doc = _engineDoc;
    final itemSel = _rows.itemSelector;
    if (doc == null || itemSel == null) return;
    final rows = doc.querySelectorAll(itemSel);
    for (final entry in _rows.fields.entries) {
      if (entry.value.labels.isEmpty) continue;
      final matching = rowsMatchingLabels(
        rows,
        _rows.labelSelector,
        entry.value.labels,
      );
      final sim = simulateRowsFieldValue(
        matching,
        entry.value.valueSelector,
        join: entry.value.join,
      );
      if (sim.texts.isNotEmpty) {
        _previews['rows.${entry.key.configKey}'] = sim.preview;
      }
    }
  }

  /// A config-derived seed has selectors but no previews — nothing was ever
  /// captured for them. Extracts one directly from [_engineDoc] per seeded
  /// field that's missing a preview, using each field's own mode/attr —
  /// deliberately not [_evaluateRelative], which reads [_armedStep] for its
  /// attr (null here, at `initState` time), so it would wrongly extract
  /// text instead of e.g. `coverSelector`'s `src`.
  void _backfillMissingPreviews() {
    final doc = _engineDoc;
    if (doc == null) return;
    for (final step in detailsFields) {
      final selector = _picked[step.key];
      if (selector == null || _previews.containsKey(step.key)) continue;
      final matches = doc.querySelectorAll(selector);
      if (step.mode == StepMode.item) {
        _previews[step.key] = _itemPreview((
          selector: selector,
          engineCount: matches.length,
          browserCount: matches.length,
        ), step);
      } else if (matches.isNotEmpty) {
        final first = matches.first;
        _previews[step.key] = step.attr.isEmpty
            ? first.text.trim().replaceAll(RegExp(r'\s+'), ' ')
            : (first.attributes[step.attr] ?? '');
      }
    }
  }

  /// [_PickerDialogState._evaluateRelative]'s counterpart — every arm
  /// (flat field or `Status`) is a plain whole-document search now; rows
  /// detection runs as a *separate* pass over whatever this resolves to
  /// (see `_runRowsDetection`), not by scoping this search itself. Kept as
  /// the original whole-document search (not body-scoped) since a flat
  /// field can legitimately target `<head>` content (e.g.
  /// `meta[property="og:image"]`, per the real engine's own
  /// `documentElement`-not-`body` extraction root, see
  /// `lib/src/config_source.dart`) — a pre-existing inconsistency with
  /// [_highlightedGroup]/[_onTreeNodeTap] (body-scoped), preserved as-is.
  @override
  _PendingRelative _evaluateRelative(
    String selector, {
    required String browserPreview,
  }) {
    final engineDoc = _engineDoc;
    if (engineDoc == null) {
      return (
        selector: selector,
        engineHits: -1,
        totalItems: -1,
        preview: browserPreview,
      );
    }
    final matches = engineDoc.querySelectorAll(selector);
    final attr = _armedAttr;
    var preview = '';
    if (matches.isNotEmpty) {
      final first = matches.first;
      preview = attr.isEmpty
          ? first.text.trim().replaceAll(RegExp(r'\s+'), ' ')
          : (first.attributes[attr] ?? '');
    }
    if (preview.isEmpty) preview = browserPreview;
    return (
      selector: selector,
      engineHits: matches.isEmpty ? 0 : 1,
      totalItems: 1,
      preview: preview,
    );
  }

  /// A rows field's human-readable, honest preview: what it would actually
  /// capture across every row matching [field]'s labels (or
  /// [labelsOverride], for a proposed label not yet committed) — see
  /// [simulateRowsFieldValue] (`dom_tree_algo.dart`) for why this, not a
  /// plain existence/identity check, is the right measure. Used by
  /// [_runRowsDetection] to compute the truthful "Found N values" counts
  /// before a detection card is ever shown.
  RowsFieldSimulation _simulateFieldValue(
    dom.Document doc,
    RowsFieldKey field,
    String candidateValueSelector, {
    Set<String>? labelsOverride,
  }) {
    final itemSel = _rows.itemSelector;
    final rows = itemSel == null
        ? const <dom.Element>[]
        : rowsMatchingLabels(
            doc.querySelectorAll(itemSel),
            _rows.labelSelector,
            labelsOverride ?? _rows.fields[field]?.labels ?? const {},
          );
    final join = _rows.fields[field]?.join ?? ', ';
    return simulateRowsFieldValue(rows, candidateValueSelector, join: join);
  }

  /// See [_PickerDialogState._resyncPickerState].
  Future<void> _resyncPickerState() async {
    // Same onLoadStop-after-dispose race as _PickerDialogState's version.
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    if (_pendingItem != null || _pendingRelative != null) {
      setState(() {
        _pendingItem = null;
        _pendingRelative = null;
      });
    }
    await controller.evaluateJavascript(
      source:
          '''
      if (window.__koniPicker) {
        window.__koniPicker.paused = $_paused;
        window.__koniPicker.minLevel = $_minLevel;
      }
      ''',
    );
    final armed = _armed;
    if (armed == null) return;
    await controller.evaluateJavascript(
      source:
          '''
      if (window.__koniPicker) {
        window.__koniPicker.forceMode = ${jsonEncode(_armedMode == StepMode.item ? 'item' : 'relative')};
        window.__koniPicker.looseItemMode = false;
        window.__koniPicker.preferAncestorTag = null;
        window.__koniPicker.previewAttr = ${jsonEncode(_armedAttr)};
        window.__koniPicker.itemRoots = null;
      }
      ''',
    );
  }

  /// Arms [target]: the next click on the page is interpreted per its
  /// mode/attr, overriding the linear wizard's itemRoots-based inference
  /// (see `forceMode` in [_pickerScript]) — the palette is always a
  /// single, whole-document root (`itemRoots: null`, same as the linear
  /// wizard's own body fallback). Any rows detection for [target] happens
  /// after the fact, once a click lands (see `_runRowsDetection`), not by
  /// pre-scoping the click itself the way the old label/value sub-steps
  /// did — so unlike before, arming never needs to re-evaluate a prior
  /// rows selector immediately; the "already configured" confirm-bar state
  /// reads straight from `_rows`/`_previews` instead.
  Future<void> _armWith(_Armed target) async {
    setState(() {
      _armSnapshot = _snapshotFor(target);
      _armed = target;
      _minLevel = 0;
      _pendingItem = null;
      _pendingRelative = null;
      _lastTreeClick = null;
      _liveTreeMatch = null;
      _rowsDetection = null;
      _adjustOpen = false;
    });
    final mode = _armedMode;
    await _controller?.evaluateJavascript(
      source:
          '''
      if (window.__koniPicker) {
        window.__koniPicker.forceMode = ${jsonEncode(mode == StepMode.item ? 'item' : 'relative')};
        window.__koniPicker.looseItemMode = false;
        window.__koniPicker.preferAncestorTag = null;
        window.__koniPicker.previewAttr = ${jsonEncode(_armedAttr)};
        window.__koniPicker.minLevel = 0;
        window.__koniPicker.lastClicked = null;
        window.__koniPicker.itemRoots = null;
      }
      if (window.__koniClearHighlight) window.__koniClearHighlight();
      ''',
    );
  }

  /// Convenience wrapper for the five flat-field chips.
  Future<void> _arm(FieldStep field) => _armWith(_ArmedFlatField(field));

  /// Maps a flat field's [FieldStep.key] to its `rows` counterpart — null
  /// for `titleSelector`/`coverSelector`, which are never rows-sourced.
  RowsFieldKey? _rowsFieldFor(String flatKey) => switch (flatKey) {
    'authorSelector' => RowsFieldKey.author,
    'descriptionSelector' => RowsFieldKey.description,
    'genreSelector' => RowsFieldKey.genres,
    _ => null,
  };

  bool _rowsFieldConfigured(RowsFieldKey field) =>
      _rows.fields[field]?.labels.isNotEmpty ?? false;

  bool _rowsAlreadyConfigured(FieldStep field) {
    final rowsField = _rowsFieldFor(field.key);
    return rowsField != null && _rowsFieldConfigured(rowsField);
  }

  /// Whether [field]'s top-level chip should show a checkmark — satisfied
  /// either by a flat pick or by rows, since a field can now be configured
  /// either way.
  bool _fieldConfigured(FieldStep field) =>
      _picked.containsKey(field.key) || _rowsAlreadyConfigured(field);

  /// The rows field whatever's currently armed maps onto — a flat field's
  /// own counterpart, or [RowsFieldKey.status] directly for the one field
  /// with no flat counterpart at all. `null` for title/cover (never
  /// rows-sourced) and when nothing's armed.
  RowsFieldKey? get _armedRowsField => switch (_armed) {
    _ArmedFlatField(:final field) => _rowsFieldFor(field.key),
    _ArmedStatus() => RowsFieldKey.status,
    null => null,
  };

  /// An honest element to detect row structure from: the actual
  /// DOM-tree-tapped element if that's how the current pick was made,
  /// otherwise re-queried from `_engineDoc` using whichever selector is on
  /// hand (a fresh pending click, or — for an already flat-picked field —
  /// [committedSelector]).
  dom.Element? _representativeElementFor({String? committedSelector}) {
    final doc = _engineDoc;
    if (doc == null) return null;
    if (_lastTreeClick != null) return _lastTreeClick;
    final selector =
        _pendingItem?.selector ?? _pendingRelative?.selector ?? committedSelector;
    if (selector == null) return null;
    return doc.querySelector(selector);
  }

  /// [_runRowsDetection]'s counterpart for a live-page item-mode click
  /// (e.g. clicking a genre tag directly on the page, not in the DOM
  /// tree): re-querying `_engineDoc` by the click's own *group* selector
  /// (e.g. bare `span`) can land on a different instance of the group than
  /// the one actually clicked — there's no per-instance identity check for
  /// item mode the way there is for a relative pick — so instead this asks
  /// the *live WebView* directly, keying off `window.__koniPicker.lastClicked`
  /// (the exact clicked element, still a live reference at this point, no
  /// relocation needed). Delegates the actual orchestration to
  /// `seedRowFieldFromClick`, a named function inside `_pickerScript`'s
  /// `picker-algo:start`/`:end` block — extracted there (not inlined as a
  /// one-off snippet here) specifically so `picker-algo.test.js` covers it
  /// under jsdom rather than this only ever being exercised by hand against
  /// a live page. Returns a proposal — never mutates `_rows`.
  Future<({String? containerSelector, String? labelText, String? valueSelector})?>
  _seedRowCandidateFromLiveClick() async {
    final controller = _controller;
    if (controller == null) return null;
    final raw = await controller.evaluateJavascript(
      source:
          '''
      (function() {
        var picker = window.__koniPicker;
        var clicked = picker && picker.lastClicked;
        if (!clicked) return null;
        var result = picker.seedRowFieldFromClick(clicked, ${jsonEncode(_rows.labelSelector)});
        return result ? JSON.stringify(result) : null;
      })();
      ''',
    );
    if (raw is! String || raw.isEmpty) return null;
    final Map<String, dynamic> result;
    try {
      result = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    return (
      containerSelector: result['containerSelector'] as String?,
      labelText: result['labelText'] as String?,
      valueSelector: result['valueSelector'] as String?,
    );
  }

  /// A click that produced no usable row-structure proposal: clears any
  /// stale prior proposal (a fresh click superseded it) and, for `Status`
  /// only — the one field with no flat fallback to quietly keep instead —
  /// opens the Adjust panel automatically so it stays configurable by
  /// hand.
  void _failRowsDetection(RowsFieldKey rowsField) {
    setState(() {
      _rowsDetection = null;
      if (rowsField == RowsFieldKey.status) _adjustOpen = true;
    });
  }

  /// Runs after every valid click while a rows-eligible field is armed
  /// (see [_pendingCandidateChanged]) — proposes a [_RowsDetection] for the
  /// confirm bar to show; never mutates `_rows` itself (the user's
  /// explicit Yes/Add/Replace tap does that — see `_confirmBar`). Reuses
  /// [guessRowContainer]/[rowFieldSeed] (`dom_tree_algo.dart`, already
  /// unit-tested) directly for a *provably* correct representative element
  /// (a real tree tap, or any relative-mode click — its stored selector is
  /// identity-verified by `domRelativeCandidate`'s own sync gate before
  /// it's ever stored). An item-mode live-page click (Genre) has no such
  /// guarantee — its group selector can re-query to a different instance
  /// of the group, the classic "bare `span` matches the wrong row" hazard
  /// this whole feature exists to avoid — so that case instead asks the
  /// *live WebView* directly via [_seedRowCandidateFromLiveClick], which
  /// also means it can't reuse an already-established `rows.itemSelector`
  /// the way the trustworthy path does (it always re-guesses from
  /// scratch) — a genuine mismatch there is surfaced as
  /// [_RowsDetection.conflictsWithContainer], never silently trusted.
  Future<void> _runRowsDetection() async {
    final rowsField = _armedRowsField;
    final doc = _engineDoc;
    if (rowsField == null || doc == null) return;

    // Same validity gate _syncPendingIfValid uses: an invalid/overshoot
    // click leaves whatever was already proposed alone rather than
    // clearing it — a bad click never erases a good prior state.
    final verified = widget.engineHtml.isNotEmpty;
    final validClick = _armedMode == StepMode.item
        ? (_pendingItem != null && (!verified || _pendingItem!.engineCount > 0))
        : (_pendingRelative != null &&
              (!verified || _pendingRelative!.engineHits > 0));
    if (!validClick) return;

    final elIsTrustworthy =
        _lastTreeClick != null || _armedMode == StepMode.relative;

    String? containerSelector;
    String? labelText;
    String? valueSelector;
    var conflicts = false;

    if (elIsTrustworthy) {
      final committedSelector = switch (_armed) {
        _ArmedFlatField(:final field) => _picked[field.key],
        _ => null,
      };
      final el = _representativeElementFor(committedSelector: committedSelector);
      if (el == null) return _failRowsDetection(rowsField);
      containerSelector =
          _rows.itemSelector ??
          guessRowContainer(doc, el, labelSelector: _rows.labelSelector)
              ?.selector;
      if (containerSelector == null) return _failRowsDetection(rowsField);
      final seed = rowFieldSeed(doc, containerSelector, _rows.labelSelector, el);
      if (seed == null) return _failRowsDetection(rowsField);
      labelText = seed.labelText;
      valueSelector = seed.valueSelector;
    } else {
      final requestId = ++_detectionRequestId;
      final candidate = await _seedRowCandidateFromLiveClick();
      if (requestId != _detectionRequestId || !mounted) return;
      containerSelector = candidate?.containerSelector;
      labelText = candidate?.labelText;
      if (containerSelector == null) return _failRowsDetection(rowsField);
      valueSelector = candidate?.valueSelector;
      final established = _rows.itemSelector;
      conflicts = established != null && established != containerSelector;
    }
    if (labelText == null || labelText.isEmpty) {
      return _failRowsDetection(rowsField);
    }

    final existing = _rows.fields[rowsField];
    if (!conflicts && existing != null && existing.labels.contains(labelText)) {
      // No new information — a repeat click on the same kind of row. Fall
      // through to the "already configured" summary instead of re-asking
      // a question with no new answer.
      setState(() => _rowsDetection = null);
      return;
    }

    const emptySimulation = RowsFieldSimulation(
      rowsWithValue: 0,
      totalRows: 0,
      texts: [],
      preview: '',
    );
    final previewIfReplaced = conflicts
        ? emptySimulation
        : _simulateFieldValue(
            doc,
            rowsField,
            valueSelector ?? '',
            labelsOverride: {labelText},
          );
    final previewIfAdded = conflicts || existing == null
        ? previewIfReplaced
        : _simulateFieldValue(
            doc,
            rowsField,
            existing.valueSelector.isEmpty
                ? (valueSelector ?? '')
                : existing.valueSelector,
            labelsOverride: {...existing.labels, labelText},
          );

    final resolvedContainer = containerSelector;
    final resolvedLabel = labelText;
    setState(() {
      _rowsDetection = _RowsDetection(
        rowsField: rowsField,
        containerSelector: resolvedContainer,
        labelText: resolvedLabel,
        valueSelector: valueSelector,
        previewIfAdded: previewIfAdded,
        previewIfReplaced: previewIfReplaced,
        conflictsWithContainer: conflicts,
      );
    });
    if (!conflicts) {
      _highlightRowsMatchingLabel(resolvedContainer, resolvedLabel);
    }
  }

  /// Overrides whatever the live page's own click handler already
  /// highlighted (it self-highlights synchronously off the *flat*
  /// item-mode candidate, before this method's caller even resolves — see
  /// `_pickerScript`'s click handler) with just the row(s) actually
  /// matching [labelText] within [containerSelector] — the same
  /// `rowsMatchingLabels`-style label filter [_highlightedGroup] applies
  /// for the DOM-tree sidebar, mirrored here for the live WebView since
  /// there's no shared-element identity between the two to reuse one
  /// highlight call for both.
  void _highlightRowsMatchingLabel(String containerSelector, String labelText) {
    _controller?.evaluateJavascript(
      source:
          '''
      (function() {
        var rows = document.querySelectorAll(${jsonEncode(containerSelector)});
        var labelSel = ${jsonEncode(_rows.labelSelector)};
        var label = ${jsonEncode(labelText.toLowerCase())};
        var matched = [];
        for (var i = 0; i < rows.length; i++) {
          var labelEl = rows[i].querySelector(labelSel);
          var text = labelEl ? (labelEl.textContent || '').trim().toLowerCase() : '';
          if (text && text.indexOf(label) !== -1) matched.push(rows[i]);
        }
        if (window.__koniHighlightGroup) window.__koniHighlightGroup(matched);
      })();
      ''',
    );
  }

  /// Captures everything one arm session could plausibly mutate: the flat
  /// selector/attr/preview (if [target] is a flat field), plus the shared
  /// row container/label selectors and this session's own rows field —
  /// since a rows-eligible arm session can now also commit into `_rows`
  /// mid-session (via the confirm bar's Yes/Add/Replace, not a separate
  /// arm-able step), Cancel needs all of it to undo cleanly.
  _ArmSnapshot _snapshotFor(_Armed target) {
    final rowsField = switch (target) {
      _ArmedFlatField(:final field) => _rowsFieldFor(field.key),
      _ArmedStatus() => RowsFieldKey.status,
    };
    final draft = rowsField == null ? null : _rows.fields[rowsField];
    return _ArmSnapshot(
      flatSelector: target is _ArmedFlatField ? _picked[target.field.key] : null,
      flatAttr: target is _ArmedFlatField && target.field.attr.isNotEmpty
          ? _picked[target.field.attrKey]
          : null,
      flatPreview: target is _ArmedFlatField ? _previews[target.field.key] : null,
      rowsItemSelector: _rows.itemSelector,
      rowsLabelSelector: _rows.labelSelector,
      rowsFieldDraft: draft == null
          ? null
          : _RowFieldDraft(
              labels: {...draft.labels},
              valueSelector: draft.valueSelector,
              join: draft.join,
            ),
      rowsFieldPreview: rowsField == null
          ? null
          : _previews['rows.${rowsField.configKey}'],
    );
  }

  void _restoreSnapshot(_Armed armed, _ArmSnapshot snap) {
    if (armed is _ArmedFlatField) {
      final field = armed.field;
      if (snap.flatSelector == null) {
        _picked.remove(field.key);
      } else {
        _picked[field.key] = snap.flatSelector!;
      }
      if (field.attr.isNotEmpty) {
        final attrKey = field.attrKey;
        if (snap.flatAttr == null) {
          _picked.remove(attrKey);
        } else {
          _picked[attrKey] = snap.flatAttr!;
        }
      }
      if (snap.flatPreview == null) {
        _previews.remove(field.key);
      } else {
        _previews[field.key] = snap.flatPreview!;
      }
    }
    _rows.itemSelector = snap.rowsItemSelector;
    if (snap.rowsLabelSelector != null) {
      _rows.labelSelector = snap.rowsLabelSelector!;
    }
    final rowsField = switch (armed) {
      _ArmedFlatField(:final field) => _rowsFieldFor(field.key),
      _ArmedStatus() => RowsFieldKey.status,
    };
    if (rowsField == null) return;
    if (snap.rowsFieldDraft == null) {
      _rows.fields.remove(rowsField);
    } else {
      _rows.fields[rowsField] = snap.rowsFieldDraft!;
    }
    final previewKey = 'rows.${rowsField.configKey}';
    if (snap.rowsFieldPreview == null) {
      _previews.remove(previewKey);
    } else {
      _previews[previewKey] = snap.rowsFieldPreview!;
    }
  }

  /// [_PickerTreeAndPauseMixin._pendingCandidateChanged]'s override: live-
  /// syncs a valid armed candidate straight into `_picked`/`_previews`, so
  /// picking a field no longer needs a separate Confirm click — arming
  /// something *different* before this one is "done" no longer loses the
  /// pick, because it was already written the moment it became valid.
  /// Also runs row-structure detection in the background for whatever's
  /// armed — see `_runRowsDetection`.
  @override
  void _pendingCandidateChanged() {
    _syncPendingIfValid();
    _runRowsDetection();
  }

  /// Same validity gate the old per-field Confirm button used to enable on
  /// (`pending.engineCount > 0` / `engineHits > 0`), just relocated from
  /// "enables a button" to "gates a live write". An invalid intermediate
  /// candidate (an ancestor-level overshoot, a webview-mismatch zero-hit)
  /// deliberately leaves the prior value at its last good state instead of
  /// clearing it — a bad click never erases a good prior pick, including
  /// one seeded from the current config.
  void _syncPendingIfValid() {
    final armed = _armed;
    // `Status` never writes to `_picked` — it has no flat DetailsConfig
    // selector to write into at all; its only path is `_rows` (see
    // `_runRowsDetection`).
    if (armed is! _ArmedFlatField) return;
    final field = armed.field;
    final verified = widget.engineHtml.isNotEmpty;
    if (_armedMode == StepMode.item) {
      final pending = _pendingItem;
      if (pending == null || (verified && pending.engineCount <= 0)) return;
      setState(() {
        _picked[field.key] = pending.selector;
        if (field.attr.isNotEmpty) _picked[field.attrKey] = field.attr;
        _previews[field.key] = _itemPreview(pending, field);
      });
      return;
    }
    final pending = _pendingRelative;
    if (pending == null || (verified && pending.engineHits <= 0)) return;
    setState(() {
      _picked[field.key] = pending.selector;
      if (field.attr.isNotEmpty) _picked[field.attrKey] = field.attr;
      _previews[field.key] = pending.preview;
    });
  }

  /// Leaves whatever's currently armed. [revert] (Cancel) restores
  /// whatever state existed before this arm session started (see
  /// [_armSnapshot]/[_restoreSnapshot]) — under live-sync, re-arming an
  /// already-picked field/step and clicking around overwrites it
  /// immediately, so Cancel needs an explicit undo. `false` (Done) just
  /// stops editing and keeps whatever's already synced. Also resets the
  /// live page's `itemRoots` back to `null` — a rows arm leaves it
  /// genuinely non-empty, and a stale non-empty array would make the click
  /// handler wrongly treat an unarmed click as relative-mode (`useRelative
  /// = state.forceMode ? ... : !!state.itemRoots` — flat mode never hit
  /// this because it always left `itemRoots` at `null`).
  void _leaveArmed({required bool revert}) {
    final armed = _armed;
    final snap = _armSnapshot;
    setState(() {
      if (revert && armed != null && snap != null) {
        _restoreSnapshot(armed, snap);
      }
      _armed = null;
      _armSnapshot = null;
      _pendingItem = null;
      _pendingRelative = null;
      _lastTreeClick = null;
      _liveTreeMatch = null;
    });
    _controller?.evaluateJavascript(
      source: '''
      if (window.__koniPicker) {
        window.__koniPicker.forceMode = null;
        window.__koniPicker.looseItemMode = false;
        window.__koniPicker.itemRoots = null;
      }
      if (window.__koniClearHighlight) window.__koniClearHighlight();
      ''',
    );
  }

  /// See [_PickerDialogState._requestEnableWebview].
  void _requestEnableWebview() {
    widget.onRequestEnableWebview?.call();
    Navigator.of(context).pop<DetailsPickResult>(null);
  }

  /// Clears [key]'s flat pick *and* its rows counterpart (if any) — a
  /// field can now be satisfied either way, so its chip's delete icon
  /// needs to fully un-configure it regardless of which path was used.
  void _clearField(String key) {
    setState(() {
      _picked.remove(key);
      // Same derivation as FieldStep.attrKey (key.replaceAll('Selector',
      // 'Attr')) — not the '${key}Attr' pattern that produced e.g.
      // 'coverSelectorAttr' instead of the real 'coverAttr' written by
      // _syncPendingIfValid, which meant Clear silently left the attr entry
      // behind (a real bug, same shape as the one FieldStep.attrKey was
      // introduced to fix elsewhere in this file — this call site was
      // missed).
      _picked.remove(key.replaceAll('Selector', 'Attr'));
      _previews.remove(key);
      final rowsField = _rowsFieldFor(key);
      if (rowsField != null) {
        _rows.fields.remove(rowsField);
        _previews.remove('rows.${rowsField.configKey}');
      }
      // Deleting the field this arm session started from would otherwise
      // leave a stale _armSnapshot pointing at the just-deleted value,
      // which a later Cancel would silently resurrect.
      final armed = _armed;
      if (armed is _ArmedFlatField && armed.field.key == key) {
        _armSnapshot = const _ArmSnapshot();
      }
    });
  }

  /// [_clearField]'s counterpart for `Status`, which has no flat selector
  /// to clear alongside it.
  void _clearStatus() {
    setState(() {
      _rows.fields.remove(RowsFieldKey.status);
      _previews.remove('rows.${RowsFieldKey.status.configKey}');
      if (_armed is _ArmedStatus) _armSnapshot = const _ArmSnapshot();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _engineDoc;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: doc != null && _showTree ? 1400 : 900,
          maxHeight: 760,
        ),
        child: Column(
          children: [
            AppBar(
              title: Text('Pick details fields — ${widget.url.host}'),
              automaticallyImplyLeading: false,
              actions: [
                if (doc != null)
                  IconButton(
                    icon: Icon(
                      _showTree
                          ? Icons.account_tree
                          : Icons.account_tree_outlined,
                    ),
                    tooltip: _showTree
                        ? 'Hide the parsed DOM tree'
                        : 'Show the parsed DOM tree — click a node to pick '
                              'it directly, works even where the live page '
                              'and the engine\'s parse disagree',
                    onPressed: () => setState(() => _showTree = !_showTree),
                  ),
                _pausePickingAction(paused: _paused, onChanged: _setPaused),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final field in detailsFields)
                        InputChip(
                          label: Text(field.fieldLabel),
                          avatar: Icon(
                            _fieldConfigured(field)
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 16,
                            color: _fieldConfigured(field)
                                ? Colors.green
                                : null,
                          ),
                          selected: switch (_armed) {
                            _ArmedFlatField(field: final f) =>
                              f.key == field.key,
                            _ => false,
                          },
                          onPressed: () => _arm(field),
                          onDeleted: _fieldConfigured(field)
                              ? () => _clearField(field.key)
                              : null,
                          deleteIcon: _fieldConfigured(field)
                              ? const Icon(Icons.close, size: 16)
                              : null,
                        ),
                      // Status: the one details field with no flat
                      // DetailsConfig selector at all — RowsConfig is its
                      // only path, so it's always tappable here directly
                      // rather than needing another field to reach it.
                      InputChip(
                        label: const Text('Status'),
                        avatar: Icon(
                          _rowsFieldConfigured(RowsFieldKey.status)
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 16,
                          color: _rowsFieldConfigured(RowsFieldKey.status)
                              ? Colors.green
                              : null,
                        ),
                        selected: _armed is _ArmedStatus,
                        onPressed: () => _armWith(const _ArmedStatus()),
                        onDeleted: _rowsFieldConfigured(RowsFieldKey.status)
                            ? _clearStatus
                            : null,
                        deleteIcon: _rowsFieldConfigured(RowsFieldKey.status)
                            ? const Icon(Icons.close, size: 16)
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_paused)
                    _pausedNotice(theme)
                  else
                    Text(
                      _armed == null
                          ? 'Tap a field above, then click it on the page. '
                                'Title is the only one required.'
                          : _armedInstruction,
                      style: theme.textTheme.bodySmall,
                    ),
                  if (widget.engineHtml.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'No probed HTML yet — match status below isn\'t '
                        'verified against a real probe, only the browser.',
                        style: theme.textTheme.bodySmall!.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(widget.url.toString()),
                        cachePolicy: URLRequestCachePolicy
                            .RELOAD_IGNORING_LOCAL_CACHE_DATA,
                      ),
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        controller.addJavaScriptHandler(
                          handlerName: 'koniPicker',
                          callback: (args) {
                            if (args.isNotEmpty && args[0] is Map) {
                              _onPickerMessage(args[0] as Map);
                            }
                            return null;
                          },
                        );
                      },
                      onLoadStop: (controller, _) async {
                        await controller.evaluateJavascript(
                          source: _pickerScript,
                        );
                        await _resyncPickerState();
                      },
                    ),
                  ),
                  if (doc != null && _showTree) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 360,
                      child: DomTreePanel(
                        root: doc.body ?? doc.documentElement!,
                        onTap: _onTreeNodeTap,
                        selected: _treeSelected,
                        highlightedGroup: _highlightedGroup,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _confirmBar(theme),
          ],
        ),
      ),
    );
  }

  /// Shown inside the Adjust panel (see `_confirmBar`) for whichever rows
  /// field is armed — every distinct label text found among confirmed
  /// rows, as toggleable chips: checking one adds it to [field]'s
  /// `RowField.labels`. This is what expresses a multi-label field like
  /// genres (`["Tag","Type"]`, as one real hand-written config does) — the
  /// click-to-detect flow only ever proposes one label at a time; this is
  /// how a second, different label gets composed in alongside it.
  Widget _rowsFieldLabelChips(ThemeData theme, RowsFieldKey field) {
    final doc = _engineDoc;
    final itemSel = _rows.itemSelector;
    if (doc == null || itemSel == null) return const SizedBox.shrink();
    final labelSel = _rows.labelSelector;
    final distinctLabels = <String>{
      for (final row in doc.querySelectorAll(itemSel))
        row.querySelector(labelSel)?.text.trim() ?? '',
    }..removeWhere((s) => s.isEmpty);
    final sorted = distinctLabels.toList()..sort();
    final checked = _rows.fields[field]?.labels ?? const <String>{};
    if (sorted.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'No row labels found yet — check the Label step first.',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Which row(s) is ${field.label} in?',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final label in sorted)
                FilterChip(
                  label: Text(label),
                  selected: checked.contains(label),
                  onSelected: (selected) => setState(() {
                    final draft = _rows.fields[field] ??= _RowFieldDraft();
                    if (selected) {
                      draft.labels.add(label);
                    } else {
                      draft.labels.remove(label);
                    }
                  }),
                ),
            ],
          ),
          if (field.usesJoin) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _joinController(field),
                decoration: const InputDecoration(
                  labelText: 'Join with',
                  isDense: true,
                ),
                onChanged: (v) => setState(() {
                  (_rows.fields[field] ??= _RowFieldDraft()).join = v;
                }),
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                field == RowsFieldKey.genres
                    ? 'Every matched value is kept as a list.'
                    : 'Only the first matched row\'s value is used; a '
                          'canonical status still needs a matching '
                          '"statusMap" entry, hand-edited.',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _confirmBar(ThemeData theme) {
    final armed = _armed;
    final canDone = (_picked['titleSelector'] ?? '').isNotEmpty;
    if (armed == null) {
      final rowsSuffix = _rows.configuredFieldCount == 0
          ? ''
          : ', rows: ${_rows.configuredFieldCount} field'
                '${_rows.configuredFieldCount == 1 ? '' : 's'}';
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Text(
              '${_picked.length} field${_picked.length == 1 ? '' : 's'} '
              'picked$rowsSuffix',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            FilledButton(
              onPressed: canDone
                  ? () => Navigator.of(context).pop<DetailsPickResult>((
                      fields: Map.of(_picked),
                      previews: Map.of(_previews),
                      rows: _rows.build(),
                    ))
                  : null,
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
    final verified = widget.engineHtml.isNotEmpty;
    final fieldLabel = _armedFieldLabel;
    final mode = _armedMode;
    final rowsField = _armedRowsField;
    final rowsSection = rowsField == null ? null : _rowsSection(theme, rowsField);
    if (mode == StepMode.item) {
      final pending = _pendingItem;
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rowsSection != null)
              rowsSection
            else if (pending != null)
              _pendingItemSummary(
                theme,
                pending,
                verified: verified,
                sourceUsesWebview: widget.sourceUsesWebview,
                onRequestEnableWebview: widget.onRequestEnableWebview == null
                    ? null
                    : _requestEnableWebview,
              )
            else
              Text(
                'No repeating group found at this level. Click a tag '
                'directly, or try ▲ for a wider ancestor.',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            if (rowsField != null) _rowsAdjustPanel(theme, rowsField),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: 'Try a narrower ancestor',
                  icon: _adjustingLevel
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.unfold_less),
                  onPressed: (_minLevel > 0 && !_adjustingLevel)
                      ? () => _adjustLevel(-1)
                      : null,
                ),
                IconButton(
                  tooltip: 'Try a wider ancestor',
                  icon: const Icon(Icons.unfold_more),
                  onPressed: (_minLevel < 6 && !_adjustingLevel)
                      ? () => _adjustLevel(1)
                      : null,
                ),
                IconButton(
                  tooltip: 'Edit the selector by hand',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: pending == null
                      ? null
                      : () => _editSelectorManually(pending.selector, mode),
                ),
                if (rowsField != null) _rowsAdjustToggle(theme),
                const Spacer(),
                TextButton(
                  onPressed: () => _leaveArmed(revert: true),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _leaveArmed(revert: false),
                  child: Text('Done — $fieldLabel'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final pending = _pendingRelative;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rowsSection != null)
            rowsSection
          else if (pending != null)
            _pendingRelativeSummary(
              theme,
              pending,
              verified: verified,
              sourceUsesWebview: widget.sourceUsesWebview,
              onRequestEnableWebview: widget.onRequestEnableWebview == null
                  ? null
                  : _requestEnableWebview,
              previewIsImage: _armedPreviewIsImage,
              pageUrl: widget.url,
            ),
          if (rowsField != null) _rowsAdjustPanel(theme, rowsField),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () => _leaveArmed(revert: true),
                child: const Text('Cancel'),
              ),
              IconButton(
                tooltip: 'Edit the selector by hand',
                icon: const Icon(Icons.edit_outlined),
                onPressed: pending == null
                    ? null
                    : () => _editSelectorManually(pending.selector, mode),
              ),
              if (rowsField != null) _rowsAdjustToggle(theme),
              const Spacer(),
              FilledButton(
                onPressed: () => _leaveArmed(revert: false),
                child: Text('Done — $fieldLabel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The pending-summary *replacement* for [rowsField] — a detection card,
  /// a conflict notice, or the already-configured summary, whichever
  /// applies right now. `null` falls through to the ordinary flat pending
  /// summary (nothing rows-related to show yet).
  Widget? _rowsSection(ThemeData theme, RowsFieldKey rowsField) {
    final detection = _rowsDetection;
    if (detection != null && detection.rowsField == rowsField) {
      return detection.conflictsWithContainer
          ? _rowsConflictNotice(theme, rowsField)
          : _rowsDetectionCard(theme, detection);
    }
    if (_rowsFieldConfigured(rowsField)) {
      return _rowsConfiguredSummary(theme, rowsField);
    }
    return null;
  }

  Widget _rowsCard(ThemeData theme, {required Widget child, bool error = false}) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color:
            (error
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.primaryContainer)
                .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }

  /// "Found via a nearby label — use it?" (first/only label for this
  /// field) or "this row's label differs from what's already configured —
  /// add/replace/keep?" (a second, different label) — whichever [detection]
  /// represents. Neither commits anything by itself; the buttons do (see
  /// `_commitRowsDetection`).
  Widget _rowsDetectionCard(ThemeData theme, _RowsDetection detection) {
    final existing = _rows.fields[detection.rowsField];
    final isNewLabel =
        existing != null && !existing.labels.contains(detection.labelText);
    String countText(int n, String preview) =>
        '$n value${n == 1 ? '' : 's'}: $preview';
    if (isNewLabel) {
      return _rowsCard(
        theme,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${detection.rowsField.label} currently uses label '
              '"${existing.labels.join('", "')}". This row\'s label is '
              '"${detection.labelText}" — '
              '${countText(detection.previewIfReplaced.rowsWithValue, detection.previewIfReplaced.preview)}.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton(
                  onPressed: () => _commitRowsDetection(detection, replace: false),
                  child: Text(
                    'Add "${detection.labelText}" too — '
                    '${detection.previewIfAdded.rowsWithValue} total',
                  ),
                ),
                OutlinedButton(
                  onPressed: () => _commitRowsDetection(detection, replace: true),
                  child: Text('Replace with "${detection.labelText}"'),
                ),
                TextButton(
                  onPressed: () => setState(() => _rowsDetection = null),
                  child: const Text('Keep as-is'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final n = detection.previewIfReplaced.rowsWithValue;
    return _rowsCard(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Found via the "${detection.labelText}" row — '
            '${countText(n, detection.previewIfReplaced.preview)}. '
            'Use ${n == 1 ? 'it' : 'all of them'} for '
            '${detection.rowsField.label}?',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton(
                onPressed: () => _commitRowsDetection(detection, replace: true),
                child: Text(n == 1 ? 'Yes, use it' : 'Yes, use all $n'),
              ),
              OutlinedButton(
                onPressed: () => setState(() => _rowsDetection = null),
                child: Text(
                  detection.rowsField == RowsFieldKey.status
                      ? 'Try a different click'
                      : _armedMode == StepMode.item
                      ? 'No, keep the direct pick'
                      : 'No, use just this value',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Commits [detection] into `_rows` — the only place a detection
  /// actually gets written, whether from the single-label "Yes" button or
  /// the multi-label "Add"/"Replace" buttons ([replace] distinguishes
  /// them; a first/only label is always a "replace" of nothing).
  void _commitRowsDetection(_RowsDetection detection, {required bool replace}) {
    setState(() {
      _rows.itemSelector ??= detection.containerSelector;
      final draft = _rows.fields.putIfAbsent(
        detection.rowsField,
        () => _RowFieldDraft(),
      );
      if (replace) {
        draft.labels
          ..clear()
          ..add(detection.labelText);
      } else {
        draft.labels.add(detection.labelText);
      }
      if (draft.valueSelector.isEmpty && detection.valueSelector != null) {
        draft.valueSelector = detection.valueSelector!;
      }
      final sim = replace ? detection.previewIfReplaced : detection.previewIfAdded;
      _previews['rows.${detection.rowsField.configKey}'] = sim.preview;
      _rowsDetection = null;
    });
  }

  Widget _rowsConflictNotice(ThemeData theme, RowsFieldKey rowsField) {
    return _rowsCard(
      theme,
      error: true,
      child: Text(
        'This click doesn\'t look like it\'s in the same repeating '
        'structure already used for rows — click somewhere in that same '
        'list, or use Adjust below to configure ${rowsField.label} '
        'separately.',
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  Widget _rowsConfiguredSummary(ThemeData theme, RowsFieldKey rowsField) {
    final labels = _rows.fields[rowsField]?.labels ?? const <String>{};
    final preview = _previews['rows.${rowsField.configKey}'];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_outline, size: 15, color: Colors.green),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${rowsField.label} is set via rows — label '
            '"${labels.join('", "')}"'
            '${preview == null || preview.isEmpty ? '' : ': $preview'}',
            style: theme.textTheme.bodySmall!.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }

  Widget _rowsAdjustToggle(ThemeData theme) => TextButton.icon(
    icon: Icon(_adjustOpen ? Icons.expand_less : Icons.tune, size: 16),
    label: const Text('Adjust'),
    onPressed: () => setState(() => _adjustOpen = !_adjustOpen),
  );

  /// The row container/label/multi-label/value-selector editor — collapsed
  /// by default (see `_rowsAdjustToggle`), auto-opened only when `Status`
  /// detection fails outright (see `_runRowsDetection`/`_failRowsDetection`),
  /// since Status has no flat fallback to quietly keep instead.
  Widget _rowsAdjustPanel(ThemeData theme, RowsFieldKey rowsField) {
    if (!_adjustOpen) return const SizedBox.shrink();
    final draft = _rows.fields[rowsField];
    // [display] is a human placeholder ("(not yet set)") when [editValue]
    // is empty — the edit dialog must always seed from the real,
    // possibly-empty selector, never from that placeholder text.
    Widget selectorRow(
      String label,
      String display, {
      required String editValue,
      required ValueChanged<String> onApply,
      Widget? trailing,
    }) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 90,
              child: Text(label, style: theme.textTheme.labelSmall),
            ),
            Expanded(
              child: Text(
                display,
                style: theme.textTheme.bodySmall!.copyWith(
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null) trailing,
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 16),
              tooltip: 'Edit by hand',
              onPressed: () async {
                final result = await _promptSelectorDialog(context, editValue);
                if (result != null) onApply(result);
              },
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rowsField == RowsFieldKey.status &&
              _rowsDetection == null &&
              !_rowsFieldConfigured(RowsFieldKey.status))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'No labeled row detected yet for Status — configure it by '
                'hand below, or click the status text on the page.',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          Text(
            'Shared by every rows-based field (Author, Description, '
            'Genre, Status) — changing this affects all of them.',
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          selectorRow(
            'Row',
            _rows.itemSelector ?? '(not yet set)',
            editValue: _rows.itemSelector ?? '',
            onApply: (v) => setState(
              () => _rows.itemSelector = v.isEmpty ? null : v,
            ),
          ),
          selectorRow(
            'Label',
            _rows.labelSelector,
            editValue: _rows.labelSelector,
            onApply: (v) =>
                setState(() => _rows.labelSelector = v.isEmpty ? 'strong' : v),
          ),
          const SizedBox(height: 6),
          _rowsFieldLabelChips(theme, rowsField),
          selectorRow(
            'Value',
            draft == null || draft.valueSelector.isEmpty
                ? '(row\'s own text)'
                : draft.valueSelector,
            editValue: draft?.valueSelector ?? '',
            onApply: (v) => setState(
              () => (_rows.fields[rowsField] ??= _RowFieldDraft()).valueSelector = v,
            ),
            trailing: TextButton(
              onPressed: () => setState(() {
                (_rows.fields[rowsField] ??= _RowFieldDraft()).valueSelector = '';
              }),
              child: const Text('Whole row text'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Injected once per page load (guarded by `__koniPickerInstalled`, since
/// `onLoadStop` can fire more than once). Defines the item/relative
/// selector-generation algorithm — identical to the standalone version
/// verified headlessly under jsdom against real and synthetic listing pages
/// before this went anywhere near a WebView — plus hover/click wiring:
/// every click is captured, cancelled (so the picker never navigates away),
/// and reported to Dart via the `koniPicker` JS-to-Dart handler. Dart drives
/// the wizard's step state (`itemRoots`/`preferAncestorTag`) by pushing
/// small commands back in via further `evaluateJavascript` calls; the script
/// itself has no notion of "step", only "am I picking an item, or a field
/// relative to an already-confirmed item".
const _pickerScript = r'''
(function() {
  if (window.__koniPickerInstalled) return;
  window.__koniPickerInstalled = true;

  // picker-algo:start -- test/picker_algo/picker-algo.test.js extracts
  // everything between these two markers verbatim and runs it under jsdom,
  // so this block must stay pure (DOM-in/selector-out, no page-global
  // side effects) and the markers must stay put. Do not add anything here
  // that touches `window`/`document` at *definition* time (only inside a
  // function body, called later, is fine) or the extraction breaks.
  function classList(el) {
    // Excludes the picker's own hover/highlight bookkeeping classes
    // (__koni_hover / __koni_group): by the time a click fires, the click
    // target IS the hovered element, so it carries __koni_hover -- without
    // this filter every relative-selector candidate built from it would
    // bake that class in, matching nothing once the picker closes.
    return (el.getAttribute('class') || '')
      .trim()
      .split(/\s+/)
      .filter(function(c) { return c && c.indexOf('__koni') !== 0; });
  }
  function sharedClasses(els) {
    if (els.length === 0) return [];
    var shared = {};
    classList(els[0]).forEach(function(c) { shared[c] = true; });
    for (var i = 1; i < els.length; i++) {
      var cls = {};
      classList(els[i]).forEach(function(c) { cls[c] = true; });
      Object.keys(shared).forEach(function(c) { if (!cls[c]) delete shared[c]; });
    }
    return Object.keys(shared).sort();
  }
  function cssEscape(s) {
    return s.replace(/([^a-zA-Z0-9_-])/g, '\\$&');
  }
  function tagSelector(tag, classes) {
    return classes.length
      ? tag + classes.map(function(c) { return '.' + cssEscape(c); }).join('')
      : tag;
  }
  function parentScopeCandidates(parent) {
    var candidates = [''];
    if (!parent || parent.tagName === 'BODY') return candidates;
    if (parent.id) candidates.push('#' + cssEscape(parent.id) + ' > ');
    var pClasses = classList(parent);
    if (pClasses.length) {
      candidates.push(parent.tagName.toLowerCase() + '.' + pClasses.map(cssEscape).join('.') + ' > ');
    } else {
      candidates.push(parent.tagName.toLowerCase() + ' > ');
    }
    return candidates;
  }
  function computeItemCandidate(clicked, opts) {
    opts = opts || {};
    var maxLevels = opts.maxLevels != null ? opts.maxLevels : 6;
    var minLevel = opts.minLevel != null ? opts.minLevel : 0;
    // Rows-only relaxation -- see the Dart port's matching comment in
    // dom_tree_algo.dart (domItemCandidateLoose) for why grids need this
    // guard (confirmed via a real jsdom regression) and rows don't
    // (confirmed on a live page).
    var loose = !!opts.loose;
    var doc = clicked.ownerDocument;
    var node = clicked;
    for (var level = 0; level <= maxLevels; level++) {
      var parent = node.parentElement;
      if (!parent) break;
      var sameTag = Array.prototype.filter.call(parent.children, function(c) {
        return c.tagName === node.tagName;
      });
      if (sameTag.length > 1 && level >= minLevel) {
        var shared = sharedClasses(sameTag);
        if (!loose) {
          var anyHasClass = sameTag.some(function(c) { return classList(c).length > 0; });
          if (shared.length === 0 && anyHasClass) {
            node = parent;
            continue;
          }
        }
        var itemSig = tagSelector(node.tagName.toLowerCase(), shared);
        var selector = itemSig;
        var matchedGlobally = doc.querySelectorAll(selector).length;
        if (matchedGlobally !== sameTag.length) {
          // Prefer the closest available scope over giving up and keeping
          // the bare, unscoped selector -- see the Dart port's matching
          // comment in dom_tree_algo.dart for the full reasoning (scoping
          // via parent's own id/class can only ever add matches beyond
          // the original group, never drop any of it).
          var scopes = parentScopeCandidates(parent);
          for (var i = 0; i < scopes.length; i++) {
            if (scopes[i] === '') continue;
            var candidate = scopes[i] + itemSig;
            var n = doc.querySelectorAll(candidate).length;
            if (n < matchedGlobally) {
              selector = candidate;
              matchedGlobally = n;
              if (n === sameTag.length) break;
            }
          }
        }
        return {
          selector: selector,
          tag: node.tagName.toLowerCase(),
          sharedClasses: shared,
          groupSize: sameTag.length,
          globalMatchCount: matchedGlobally,
          level: level
        };
      }
      node = parent;
    }
    return null;
  }
  function computeRelativeCandidate(itemRoots, clickedEl, opts) {
    opts = opts || {};
    var preferAncestorTag = opts.preferAncestorTag;
    // What to show the user as a live preview of what this candidate would
    // actually capture: an attribute's value (cover/url steps), or the
    // element's own text (title step, previewAttr left empty). Computed
    // browser-side so there's always something to show even before a real
    // probe has run to cross-check against (see _evaluateRelative in the
    // Dart dialog, which prefers its own engine-parsed value once one
    // exists but falls back to this).
    var previewAttr = opts.previewAttr || '';
    function previewOf(el) {
      if (!el) return '';
      if (previewAttr) return el.getAttribute(previewAttr) || '';
      return (el.textContent || '').trim().replace(/\s+/g, ' ');
    }
    var containingRoot = null;
    for (var i = 0; i < itemRoots.length; i++) {
      if (itemRoots[i].contains(clickedEl)) { containingRoot = itemRoots[i]; break; }
    }
    if (!containingRoot) return null;
    function pathFrom(el) {
      var path = [];
      var n = el;
      while (n && n !== containingRoot) { path.push(n); n = n.parentElement; }
      return path.reverse();
    }
    // A root's *first* match is what the engine's own querySelector-based
    // extraction will actually use at scrape time -- so "the selector
    // works" has to mean "its first match in the containing root IS the
    // clicked element", not merely "it matches something". A bare
    // existence check passes trivially for a single-global-root pick (the
    // Details palette's itemRoots is always [document.body]) the instant
    // *any* element anywhere shares the clicked element's tag+class --
    // confirmed on a live page, where a classless cover <img>
    // produced the bare selector 'img', whose first document-order match
    // is the site's header logo, not the cover. Every *other* root (only
    // possible in the multi-card wizard) has no click of its own to
    // compare against -- for those, existence is still the right check.
    function verify(relSelector, target) {
      var hits = 0;
      for (var i = 0; i < itemRoots.length; i++) {
        var match = itemRoots[i].querySelector(relSelector);
        if (!match) continue;
        if (itemRoots[i] === containingRoot) {
          if (match === target) hits++;
        } else {
          hits++;
        }
      }
      return hits;
    }
    var candidates = [];
    if (preferAncestorTag) {
      var n = clickedEl;
      while (n && n !== containingRoot) {
        if (n.tagName.toLowerCase() === preferAncestorTag) { candidates.push(n); break; }
        n = n.parentElement;
      }
    }
    candidates.push(clickedEl);
    for (var ci = 0; ci < candidates.length; ci++) {
      var target = candidates[ci];
      var chain = pathFrom(target);
      for (var start = chain.length - 1; start >= 0; start--) {
        var segment = chain.slice(start);
        var relSelector = segment.map(function(el) {
          return tagSelector(el.tagName.toLowerCase(), classList(el));
        }).join(' > ');
        var hits = verify(relSelector, target);
        if (hits === itemRoots.length) {
          return { selector: relSelector, tag: target.tagName.toLowerCase(), matchCount: hits, totalItems: itemRoots.length, preview: previewOf(target) };
        }
      }
    }
    var fallbackTarget = candidates[candidates.length - 1];
    var fallbackSelector = tagSelector(fallbackTarget.tagName.toLowerCase(), classList(fallbackTarget));
    return {
      selector: fallbackSelector,
      tag: fallbackTarget.tagName.toLowerCase(),
      matchCount: verify(fallbackSelector, fallbackTarget),
      totalItems: itemRoots.length,
      preview: previewOf(fallbackTarget)
    };
  }
  // Rows escalation from a live-page item-mode click (e.g. clicking a
  // genre tag directly on the page, not in the DOM tree): re-querying by
  // the click's own *group* selector (e.g. bare 'span') can land on a
  // different instance of the group than the one actually clicked -- so
  // this takes the exact clicked element directly (the caller passes
  // window.__koniPicker.lastClicked, a live reference, not a re-query) and
  // does its own widen-until-labeled loop, mirroring the Dart port's
  // guessRowContainer (dom_tree_algo.dart) since this call site -- unlike
  // rowFieldSeed's, the pure Dart counterpart to the second half of this
  // function -- can't assume a row container is already confirmed.
  function seedRowFieldFromClick(clicked, labelSelector, opts) {
    opts = opts || {};
    var maxLevels = opts.maxLevels != null ? opts.maxLevels : 6;
    if (!clicked) return null;
    var doc = clicked.ownerDocument;
    var minLevel = 0;
    var container = null;
    for (var i = 0; i <= maxLevels; i++) {
      var candidate = computeItemCandidate(clicked, { minLevel: minLevel, loose: true, maxLevels: maxLevels });
      if (!candidate) break;
      var rows = doc.querySelectorAll(candidate.selector);
      var hasLabel = false;
      for (var j = 0; j < rows.length; j++) {
        if (rows[j].querySelector(labelSelector)) { hasLabel = true; break; }
      }
      if (hasLabel) { container = candidate; break; }
      minLevel = candidate.level + 1;
    }
    if (!container) return null;
    var rows2 = doc.querySelectorAll(container.selector);
    var ownRow = null;
    for (var k = 0; k < rows2.length; k++) {
      if (rows2[k] === clicked || rows2[k].contains(clicked)) { ownRow = rows2[k]; break; }
    }
    var result = { containerSelector: container.selector, labelText: null, valueSelector: null };
    if (ownRow) {
      var labelEl = ownRow.querySelector(labelSelector);
      result.labelText = labelEl ? labelEl.textContent.trim() : null;
      var rel = computeRelativeCandidate([ownRow], clicked);
      result.valueSelector = rel ? rel.selector : null;
    }
    return result;
  }
  // picker-algo:end

  window.__koniPicker = {
    computeItemCandidate: computeItemCandidate,
    computeRelativeCandidate: computeRelativeCandidate,
    seedRowFieldFromClick: seedRowFieldFromClick,
    itemRoots: null,
    preferAncestorTag: null,
    previewAttr: '',
    minLevel: 0,
    lastClicked: null,
    // Overrides the itemRoots-based item/relative inference below for the
    // details field-palette dialog, which has no linear "confirm the item
    // container first" step of its own — it picks whichever single field
    // is currently armed, in item or relative mode depending on that
    // field's own shape (see _DetailsPickerDialog). null preserves the
    // linear wizard's original inference untouched.
    forceMode: null,
    // Rows' "row container" step only -- see computeItemCandidate's
    // `loose` opt. Left false for every other flow (the grid pickers and
    // the linear wizard's own item step all need the stricter default).
    looseItemMode: false,
    // When true, the click handler below does nothing at all -- no
    // preventDefault/stopPropagation, no candidate computed -- so the page
    // behaves like a normal browser tab. Toggled from a button in the
    // dialog chrome (see _pausePickingAction, shared by both dialogs):
    // confirmed live that an interstitial ad overlay is otherwise a
    // click-trap the user can never escape, since capturing *every* click
    // (to detect picks) also captures clicks meant to dismiss the ad
    // itself -- there's no way to click "Cancel" on an overlay if every
    // click is hijacked before the page ever sees it.
    paused: false
  };

  var style = document.createElement('style');
  style.textContent =
    '.__koni_hover{outline:2px solid #2196f3 !important;outline-offset:-2px !important;cursor:pointer !important;}' +
    '.__koni_group{outline:2px dashed #4caf50 !important;outline-offset:-2px !important;background:rgba(76,175,80,0.08) !important;}';
  document.head.appendChild(style);

  var hovered = null;
  document.addEventListener('mouseover', function(ev) {
    if (hovered) hovered.classList.remove('__koni_hover');
    hovered = ev.target;
    if (hovered && hovered.classList) hovered.classList.add('__koni_hover');
  }, true);

  window.__koniClearHighlight = function() {
    var els = document.querySelectorAll('.__koni_group');
    for (var i = 0; i < els.length; i++) els[i].classList.remove('__koni_group');
  };
  window.__koniHighlightGroup = function(els) {
    window.__koniClearHighlight();
    for (var i = 0; i < els.length; i++) els[i].classList.add('__koni_group');
  };

  document.addEventListener('click', function(ev) {
    var state = window.__koniPicker;
    // Paused: let the click through untouched, as if this script weren't
    // installed at all -- the escape hatch for anything that needs a real
    // click to get past (an ad overlay's own Cancel button, a cookie
    // banner, an age gate) rather than having it hijacked into a pick.
    if (state.paused) return;
    ev.preventDefault();
    ev.stopPropagation();
    var useRelative = state.forceMode ? (state.forceMode === 'relative') : !!state.itemRoots;
    if (useRelative) {
      // The details palette never sets itemRoots (there's no confirmed
      // item container in that flow) -- computeRelativeCandidate still
      // works fine seeded with just [document.body] as its one root.
      var roots = state.itemRoots || [document.body];
      var rel = computeRelativeCandidate(roots, ev.target, { preferAncestorTag: state.preferAncestorTag, previewAttr: state.previewAttr });
      window.flutter_inappwebview.callHandler('koniPicker', { phase: 'relative', result: rel });
    } else {
      state.lastClicked = ev.target;
      var item = computeItemCandidate(ev.target, { minLevel: state.minLevel, loose: state.looseItemMode });
      if (item) { window.__koniHighlightGroup(document.querySelectorAll(item.selector)); }
      window.flutter_inappwebview.callHandler('koniPicker', { phase: 'item', result: item });
    }
  }, true);
})();
''';

// ── WebViewFetcher ──────────────────────────────────────────────────────────

/// Blocks image loading in the scraping WebView.
///
/// Reading a page list only needs the HTML, but a WebView renders the whole
/// document — so scraping one chapter downloads and decodes every page image
/// in WebKit, alongside the reader decoding the same images itself. On a real
/// device that showed up as hundreds of failed WEBP decodes per chapter and a
/// phone warm enough to notice.
///
/// `contentBlockers` rather than `blockNetworkImage`: the latter is Android
/// only, and this matters most on iOS.
final _blockImages = [
  ContentBlocker(
    trigger: ContentBlockerTrigger(
      urlFilter: '.*',
      resourceType: [ContentBlockerTriggerResourceType.IMAGE],
    ),
    action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
  ),
];

/// Fetches CF-hard pages by navigating a persistent **headless** WebView and
/// reading the rendered DOM, for `webview: true` sources whose Cloudflare
/// mode re-challenges cookie-replay from a non-browser client. Shares the
/// WKWebView cookie jar with the solver, so a cleared host passes straight
/// through. One WebView, navigations serialized.
class _InAppWebViewFetcher implements WebViewFetcher {
  HeadlessInAppWebView? _webview;
  InAppWebViewController? _controller;
  Future<void> _chain = Future<void>.value();

  /// Origin the WebView is currently parked on, so a run of same-origin image
  /// [fetchBytes] calls (covers, page previews) skips re-navigating for each.
  String? _currentOrigin;

  /// Per-origin `jsonEncode` of the last `localStorageSeed` actually applied,
  /// keyed by content, not just "has this origin ever been seeded",
  /// because the seed isn't static: `SourceConfig.localStoragePreferences`
  /// lets it change mid-session (a user flips a consent toggle without
  /// restarting). [_navigateAndRead] re-seeds whenever the *current* call's
  /// encoded seed differs from what's recorded here, and only records it
  /// after every entry's `evaluateJavascript` succeeds, so a failed attempt
  /// (a wedged channel, a challenge on the seeding navigation itself)
  /// retries on the next fetch instead of silently never applying.
  final Map<String, String> _appliedLocalStorageSeeds = {};

  /// Turns image loading on or off for the shared controller. Cheap and
  /// idempotent; [_imagesBlocked] avoids a platform round-trip per call.
  bool? _imagesBlocked;

  Future<void> _setImagesBlocked(
    InAppWebViewController controller,
    bool blocked,
  ) async {
    if (_imagesBlocked == blocked) return;
    try {
      await controller.setSettings(
        settings: InAppWebViewSettings(
          contentBlockers: blocked ? _blockImages : [],
        ),
      );
      _imagesBlocked = blocked;
    } catch (e) {
      // Never fail a fetch over an optimisation. Leaving the flag unset means
      // the next call retries rather than assuming it took.
      cfLog('WebViewFetcher: setSettings(contentBlockers) failed: $e');
    }
  }

  Future<InAppWebViewController> _ensure() async {
    final existing = _controller;
    if (existing != null) {
      cfLog('WebViewFetcher: _ensure reusing existing controller');
      return existing;
    }
    cfLog('WebViewFetcher: _ensure creating a fresh HeadlessInAppWebView');
    final webview = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
    );
    await webview.run();
    cfLog('WebViewFetcher: _ensure fresh HeadlessInAppWebView.run() returned');
    _webview = webview;
    return _controller = webview.webViewController!;
  }

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? localStorageSeed,
  }) {
    // Serialize: one WebView can only be on one page at a time.
    final result = Completer<String>();
    _chain = _chain.then((_) async {
      try {
        result.complete(
          await _navigateAndRead(
            url,
            headers: headers,
            localStorageSeed: localStorageSeed,
          ),
        );
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  @override
  Future<Uint8List> fetchBytes(
    String url, {
    Map<String, String>? headers,
    bool warmByUrl = false,
    bool viaImgTag = false,
    String? baseUrl,
  }) {
    final result = Completer<Uint8List>();
    _chain = _chain.then((_) async {
      try {
        result.complete(
          await _fetchBytes(
            url,
            headers: headers,
            warmByUrl: warmByUrl,
            viaImgTag: viaImgTag,
            baseUrl: baseUrl,
          ),
        );
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  /// [viaImgTag] is tried first when set; on a failed extraction (confirmed
  /// live against a real source: covers threw `<img> failed to load` for
  /// every single request: a CDN whose redirect target doesn't grant
  /// `crossorigin="anonymous"` the CORS access `viaImgTag`'s canvas read
  /// needs, unlike the CDN `viaImgTag` was built for, which does) it falls
  /// back to [warmByUrl]'s full-page-navigation approach when [warmByUrl] is
  /// also set: that path has no CORS check at all (same-document read, not
  /// a cross-origin `<img>`), which is exactly why it worked for this host
  /// before `viaImgTag` replaced it as this source's only flag. A
  /// `CloudflareChallengeException` from the `viaImgTag` attempt (a wedged
  /// channel or a genuine unsolved challenge) isn't a per-image failure,
  /// falling back would just fail the same way again, so it always
  /// propagates instead of triggering the fallback.
  Future<Uint8List> _fetchBytes(
    String url, {
    Map<String, String>? headers,
    required bool warmByUrl,
    required bool viaImgTag,
    String? baseUrl,
  }) async {
    // ...and back on here: both byte paths depend on the image actually
    // loading — `viaImgTag` reads it off a canvas, `warmByUrl` navigates the
    // page so it lands in cache. Blocking images here would break downloading
    // for exactly the sources that need this WebView. Safe to flip per call
    // because every entry point is serialized on [_chain].
    await _setImagesBlocked(await _ensure(), false);
    if (viaImgTag) {
      try {
        return await _navigateAndExtractViaImgTag(
          url,
          baseUrl: baseUrl!,
          headers: headers,
        );
      } on CloudflareChallengeException {
        rethrow;
      } catch (e) {
        if (!warmByUrl) rethrow;
        cfLog(
          'WebViewFetcher: imgTag failed for $url, falling back to '
          'warmByUrl ($e)',
        );
      }
    }
    return _navigateAndFetchBytes(url, warmByUrl: warmByUrl, headers: headers);
  }

  /// [SourceConfig.warmImageViaImgTag]'s mechanism: navigate to (or reuse,
  /// if already parked there) a page at [baseUrl] (the referring site
  /// itself, not the image's own host), then inject a same-page `<img
  /// crossorigin="anonymous">` for [url] and canvas-read it once loaded.
  /// Recovers two failures [_navigateAndFetchBytes] can't: a WAF whose
  /// Referer check wants [baseUrl] specifically (an `<img>` tag on a page
  /// there sends exactly that Referer automatically; a navigation to the
  /// image's own origin never can), and a CDN that mislabels real image
  /// bytes with a non-image `Content-Type` (an `<img>` tag decodes by
  /// sniffing bytes, unlike a top-level navigation, which relies on the
  /// declared type to render `document.images[0]` at all). Needs the CDN's
  /// `Access-Control-Allow-Origin` to permit the read; when it doesn't, the
  /// canvas comes back tainted and `toDataURL` throws a `SecurityError`,
  /// surfaced here rather than swallowed.
  Future<Uint8List> _navigateAndExtractViaImgTag(
    String url, {
    required String baseUrl,
    Map<String, String>? headers,
  }) async {
    final origin = Uri.parse(baseUrl).origin;
    if (_currentOrigin != origin) {
      await _navigateAndRead(baseUrl, headers: headers);
    }
    final controller = await _ensure();
    CallAsyncJavaScriptResult? result;
    try {
      result = await controller
          .callAsyncJavaScript(
            functionBody: _extractViaImgTagScript,
            arguments: {'url': url},
          )
          .timeout(_channelTimeout);
    } on TimeoutException {
      cfLog(
        'WebViewFetcher: callAsyncJavaScript(imgTag $url) never called '
        'back, resetting',
      );
      await _resetWedgedWebView();
      throw CloudflareChallengeException(Uri.parse(url));
    }
    final value = result?.value;
    if (value is! Map || value['base64'] is! String) {
      // Silent before this: the JS side's own `throw` (img.onerror, a CORS
      // rejection or a genuine load failure, or a tainted-canvas
      // `SecurityError` from `toDataURL`) surfaced only in the thrown
      // Dart exception's message, which nothing was logging, so a whole
      // grid of failed covers showed up in cfLog as *zero* lines, as if
      // they'd never been attempted at all.
      cfLog(
        'WebViewFetcher: imgTag extraction failed for $url from origin '
        '$origin (${result?.error})',
      );
      throw StateError(
        'WebView <img> extraction returned no data for $url '
        '(${result?.error})',
      );
    }
    cfLog('WebViewFetcher: imgTag extracted $url from origin $origin');
    return base64Decode(value['base64'] as String);
  }

  /// Loads [url] through a plain `<img crossorigin="anonymous">` element
  /// (bytes sniffed regardless of declared `Content-Type`; Referer is
  /// whatever page this script runs on) and reads it back via canvas:
  /// same chunked-`fromCharCode` approach as [_fetchBytesScript].
  static const _extractViaImgTagScript = '''
    const img = new Image();
    img.crossOrigin = 'anonymous';
    const loaded = await new Promise((resolve) => {
      img.onload = () => resolve(true);
      img.onerror = () => resolve(false);
      img.src = url;
    });
    if (!loaded) { throw new Error('<img> failed to load ' + url); }
    const canvas = document.createElement('canvas');
    canvas.width = img.naturalWidth;
    canvas.height = img.naturalHeight;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(img, 0, 0);
    const dataUrl = canvas.toDataURL('image/png');
    return { base64: dataUrl.split(',')[1] };
  ''';

  /// Navigate to the image's own origin first (a real document, which also
  /// clears any challenge; clearance is domain-scoped), then fetch the
  /// bytes from that live page context: same-origin, so no CORS hurdle, and
  /// it rides the browser's real cookie jar + TLS fingerprint.
  ///
  /// The warming navigation targets the bare origin by default: some sites
  /// only run their challenge-solving JS on a real document there, so
  /// jumping straight to an image path can leave the challenge unsolved.
  /// [warmByUrl] targets the image [url] itself instead: a handful of
  /// CDN-only hosts (no real page at `/`) WAF-block a bare root-path
  /// request outright ("Attention Required", a hard block, not a solvable
  /// challenge) while happily serving the actual asset path with no
  /// challenge at all, set per-source (`SourceConfig.warmImageByUrl`), not
  /// a blanket behavior change.
  ///
  /// [warmByUrl] also changes how the bytes get read back. The default path
  /// reads them with a same-origin `fetch()` after the warming navigation.
  /// Fine there, since that navigation only ever needs to reach a same-site
  /// document. A `warmByUrl` navigation, though, often needs [headers] a
  /// script can't send: `fetch()` can't set `Referer` at all (a forbidden
  /// header, silently dropped) and can't spoof a cross-origin `referrer`
  /// option either, so a second `fetch()` to the same cross-site CDN would
  /// just drop the very header that got the navigation itself past the
  /// host's WAF. [headers] *can* reach that navigation, though (as native
  /// request headers on `loadUrl`, not a script's), so for `warmByUrl` the
  /// image is read straight off the page that navigation already loaded,
  /// with no second network request left to lose the header on.
  /// Strips `User-Agent`/`Cookie` (case-insensitive) out of a source's
  /// request headers before they reach the WebView: those two are the real
  /// browser engine's own to own. [headers] carries `ClearanceStore`'s
  /// replayed cookie + matching User-Agent (see that class's doc comment),
  /// meant for the plain `http.Client` fast path to *impersonate* the
  /// browser that solved a challenge; handed to the WebView itself (which
  /// *is* that browser), it does the opposite of what's intended. The
  /// WebView already carries the real session via its own cookie jar
  /// (`warmCookieJar`) and its own genuine engine UA; overriding either from
  /// here breaks the one property a real browser engine is for; on Android
  /// specifically, `loadUrl`'s `additionalHttpHeaders` honors an explicit
  /// `User-Agent` entry, so this isn't just inert: it actively replaces the
  /// real UA with whatever string the plain-HTTP path happened to compute
  /// (a stale replayed one, or the engine's own hardcoded default), which is
  /// exactly the kind of TLS/UA mismatch Cloudflare's fingerprinting exists
  /// to catch. `Referer` and any other custom header stay untouched: those
  /// are the ones a warming/reading navigation actually needs to carry.
  Map<String, String>? _navigationHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return headers;
    final filtered = Map<String, String>.of(headers)
      ..removeWhere(
        (k, _) =>
            k.toLowerCase() == 'user-agent' || k.toLowerCase() == 'cookie',
      );
    return filtered;
  }

  Future<Uint8List> _navigateAndFetchBytes(
    String url, {
    bool warmByUrl = false,
    Map<String, String>? headers,
  }) async {
    if (warmByUrl) {
      await _navigateAndRead(url, headers: headers);
      return _extractLoadedImageBytes(url);
    }
    final origin = Uri.parse(url).origin;
    // Only navigate when we're not already parked on this origin (the probe,
    // or the previous image, usually left us there). fetch() with an absolute
    // same-origin URL works from any page on that origin.
    if (_currentOrigin != origin) {
      await _navigateAndRead(origin, headers: headers);
    }
    final controller = await _ensure();
    CallAsyncJavaScriptResult? result;
    try {
      result = await controller
          .callAsyncJavaScript(
            functionBody: _fetchBytesScript,
            arguments: {
              'url': url,
              'headers': _navigationHeaders(headers) ?? const {},
            },
          )
          .timeout(_channelTimeout);
    } on TimeoutException {
      cfLog(
        'WebViewFetcher: callAsyncJavaScript($url) never called back, resetting',
      );
      await _resetWedgedWebView();
      throw CloudflareChallengeException(Uri.parse(url));
    }
    final value = result?.value;
    if (value is! Map || value['base64'] is! String) {
      cfLog('WebViewFetcher: byte fetch failed for $url (${result?.error})');
      throw StateError(
        'WebView byte fetch returned no data for $url (${result?.error})',
      );
    }
    return base64Decode(value['base64'] as String);
  }

  /// Chunked `String.fromCharCode` avoids blowing the call stack on a
  /// multi-hundred-KB image. `headers` passes through `Headers` as-is:
  /// forbidden names (`Referer` among them) are silently dropped by the
  /// browser rather than thrown, so it's safe to hand the whole map over
  /// unfiltered.
  static const _fetchBytesScript = '''
    const res = await fetch(url, { headers: headers || {} });
    if (!res.ok) { throw new Error('HTTP ' + res.status); }
    const buf = await res.arrayBuffer();
    const bytes = new Uint8Array(buf);
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return { base64: btoa(binary) };
  ''';

  /// Reads the bytes of the image the WebView just navigated straight to
  /// (the `warmByUrl` path in [_navigateAndFetchBytes], where a second
  /// `fetch()` can't carry the header that got the navigation itself past
  /// the host's WAF, see that method's doc comment). The navigated
  /// document and the image are the same resource, not a script-initiated
  /// cross-origin `<img>` load, so a canvas read isn't CORS-tainted even
  /// though the response never sent CORS headers.
  Future<Uint8List> _extractLoadedImageBytes(String url) async {
    final controller = await _ensure();
    CallAsyncJavaScriptResult? result;
    try {
      result = await controller
          .callAsyncJavaScript(functionBody: _extractLoadedImageScript)
          .timeout(_channelTimeout);
    } on TimeoutException {
      cfLog(
        'WebViewFetcher: callAsyncJavaScript(extract $url) never called '
        'back, resetting',
      );
      await _resetWedgedWebView();
      throw CloudflareChallengeException(Uri.parse(url));
    }
    final value = result?.value;
    if (value is! Map || value['base64'] is! String) {
      cfLog(
        'WebViewFetcher: navigated-page image extraction failed for $url '
        '(${result?.error})',
      );
      throw StateError(
        'WebView image extraction returned no data for $url '
        '(${result?.error})',
      );
    }
    return base64Decode(value['base64'] as String);
  }

  static const _extractLoadedImageScript = '''
    const img = document.images && document.images[0];
    if (!img) { throw new Error('no image element on navigated page'); }
    const canvas = document.createElement('canvas');
    canvas.width = img.naturalWidth;
    canvas.height = img.naturalHeight;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(img, 0, 0);
    return { base64: canvas.toDataURL('image/png').split(',')[1] };
  ''';

  /// Bound on any single platform-channel round trip (`loadUrl`,
  /// `evaluateJavascript`). These normally return in milliseconds; this only
  /// exists to catch the channel wedging outright: a known
  /// flutter_inappwebview headless-webview failure mode where a call never
  /// calls back at all, as opposed to the page just being slow (which the
  /// polling loop's own 20s deadline already handles). Without this, a wedge
  /// hangs the probe forever instead of failing.
  static const _channelTimeout = Duration(seconds: 6);

  /// Consecutive channel timeouts (not "page not ready yet": the call
  /// itself never returned) before giving up on this WebView instance as
  /// wedged, rather than just slow.
  static const _maxConsecutiveChannelTimeouts = 2;

  /// Below this, `document.documentElement.outerHTML` is treated as "not the
  /// real page yet" rather than a candidate result: `about:blank`'s own DOM
  /// (`<html><head></head><body></body></html>`, 39 bytes) and any similar
  /// transitional blank state land well under it, while every real listing/
  /// details/chapter page is many times larger. Empirically what let
  /// `_navigateAndRead` "clear" on a blank page after 3 polls (~1.2s) once
  /// the over-broad challenge-platform marker stopped keeping the loop going
  /// long enough for the real navigation to actually paint.
  static const _minPageBytes = 200;

  /// Applies [localStorageSeed] (see its doc on `WebViewFetcher.fetchHtml`)
  /// whenever it differs from whatever was last applied to [url]'s origin,
  /// not just once ever, since a config's `localStoragePreferences` can
  /// change the effective seed mid-session (a consent toggle flipped without
  /// restarting), then delegates to [_navigateAndReadOnce] for the actual
  /// (re-)navigation and read. Seeding needs a document already loaded on
  /// the origin: `localStorage` is origin-scoped and can only be written
  /// from a page there, so this navigates once to land on it, seeds, then
  /// navigates again for the real, now-unblocked content.
  Future<String> _navigateAndRead(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? localStorageSeed,
  }) async {
    final origin = Uri.parse(url).origin;
    if (localStorageSeed != null && localStorageSeed.isNotEmpty) {
      final encoded = jsonEncode(localStorageSeed);
      if (_appliedLocalStorageSeeds[origin] != encoded) {
        cfLog('WebViewFetcher: seeding localStorage for $origin before $url');
        await _navigateAndReadOnce(url, headers: headers);
        final controller = await _ensure();
        for (final entry in localStorageSeed.entries) {
          final jsValue = jsonEncode(entry.value);
          await controller
              .evaluateJavascript(
                source:
                    'localStorage.setItem(${jsonEncode(entry.key)}, '
                    '${jsonEncode(jsValue)});',
              )
              .timeout(_channelTimeout);
        }
        _appliedLocalStorageSeeds[origin] = encoded;
      }
    }
    return _navigateAndReadOnce(url, headers: headers);
  }

  Future<String> _navigateAndReadOnce(
    String url, {
    Map<String, String>? headers,
  }) async {
    final controller = await _ensure();
    _currentOrigin = Uri.parse(url).origin;
    // Read before navigating: the poll loop below uses this to tell a
    // completed navigation from one that silently never left the previous
    // page (see `stale`'s doc there): a `loadUrl` that's swallowed
    // (blocked, redirected back client-side, or otherwise a no-op) leaves
    // the DOM byte-for-byte the same as before, which the old length-only
    // stability check couldn't distinguish from "genuinely done loading".
    final startUrl = await _currentLocation(controller);
    final targetIsReload = startUrl == url;
    // Images off for a scrape: this navigation exists to read the DOM, and
    // rendering the chapter's artwork is pure waste (see [_blockImages]).
    await _setImagesBlocked(controller, true);
    cfLog('WebViewFetcher: navigating to $url');
    try {
      await controller
          .loadUrl(
            urlRequest: URLRequest(
              url: WebUri(url),
              // Native request headers (unlike a page's own `fetch()`, which
              // can't set `Referer` at all, see `_navigateAndFetchBytes`'s
              // doc comment): a source's configured `SourceConfig.headers`
              // flows all the way here so a warming/reading navigation
              // actually carries it, not just the plain-HTTP fast path. Filtered
              // through [_navigationHeaders] first, see its doc comment for why
              // `User-Agent`/`Cookie` specifically never belong here.
              headers: _navigationHeaders(headers),
              // Without this, a retry to the *same* URL right after a solve
              // can be served from the WebView's local cache instead of
              // actually re-fetched, indistinguishable from a genuinely
              // still-blocked page (same title, same byte count) because
              // it's literally the same bytes as the pre-solve response.
              // The now-valid cf_clearance cookie never gets a chance to
              // matter if the request never goes out.
              cachePolicy:
                  URLRequestCachePolicy.RELOAD_IGNORING_LOCAL_CACHE_DATA,
            ),
          )
          .timeout(_channelTimeout);
    } on TimeoutException {
      cfLog('WebViewFetcher: loadUrl($url) never called back, resetting');
      await _resetWedgedWebView();
      throw CloudflareChallengeException(Uri.parse(url));
    }
    cfLog('WebViewFetcher: loadUrl($url) returned, starting poll loop');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    int? prevLen;
    int stable = 0;
    String? lastGood;
    var consecutiveChannelTimeouts = 0;
    var pollCount = 0;
    String? lastTitle;
    var lastLooksLikeChallenge = false;
    String? lastChallengeMarker;
    var lastHtmlLen = 0;
    int? lastTransferSize;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final polled = await _pollOnce(controller);
      pollCount++;
      // A heartbeat every ~2s (5 polls): visible progress *during* the 20s
      // window instead of only a final "cleared"/"did not clear" message, so
      // a genuine stall (nothing incrementing) is distinguishable from a
      // slow-but-progressing page from the log alone.
      if (pollCount % 5 == 0) {
        cfLog(
          'WebViewFetcher: $url poll #$pollCount '
          '${polled == null ? "(channel timeout)" : "ready=${polled.ready} htmlLen=${polled.html.length} title=\"${polled.title}\" url=${polled.url}"}',
        );
      }
      if (polled == null) {
        if (++consecutiveChannelTimeouts >= _maxConsecutiveChannelTimeouts) {
          cfLog(
            'WebViewFetcher: evaluateJavascript wedged $_maxConsecutiveChannelTimeouts'
            ' times in a row on $url, resetting',
          );
          await _resetWedgedWebView();
          throw CloudflareChallengeException(Uri.parse(url));
        }
        continue;
      }
      consecutiveChannelTimeouts = 0;
      // 'interactive' (DOMContentLoaded fired, subresources (images,
      // scripts, ad/tracker network calls) still pending) is accepted
      // alongside 'complete': a page can sit at 'interactive' forever when
      // some ad or analytics script never finishes loading, even though the
      // DOM itself is fully parsed and done changing (confirmed live on a
      // real source's chapter pages: real, correct, byte-stable HTML for
      // 30+ consecutive polls, `readyState` never once reaching 'complete',
      // wrongly timing out as an unsolved Cloudflare challenge). Only the
      // markup matters for scraping, not whether every subresource finished,
      // and the stability check below (two consecutive matching-length
      // reads) already guards against capturing a still-changing DOM.
      if (polled.ready != 'complete' && polled.ready != 'interactive') {
        continue;
      }
      if (polled.html.isEmpty) continue;
      lastTitle = polled.title;
      lastHtmlLen = polled.html.length;
      lastTransferSize = polled.transferSize;
      lastChallengeMarker = _challengeMarker(polled.title, polled.html);
      lastLooksLikeChallenge = lastChallengeMarker != null;
      // A near-empty document, `about:blank`'s own DOM (the headless
      // WebView's starting state, see `_ensure`), or a transitional blank
      // moment right after `loadUrl` returns but before the real navigation
      // has actually painted, is indistinguishable from "stable" once it
      // stops changing, since it was never changing to begin with. Treat it
      // the same as a detected challenge: still loading, not a result, keep
      // polling. Any real listing/details/chapter page is many times this
      // size, so the threshold has no legitimate false-positive risk.
      final looksBlank = polled.html.length < _minPageBytes;
      // `loadUrl` returning doesn't guarantee the navigation actually left
      // the previous page: a request that gets blocked, bounced back by a
      // client-side redirect, or otherwise silently swallowed leaves the DOM
      // exactly as it was, which is trivially "stable" by length alone and
      // was getting captured as if it were the real, freshly-loaded target
      // (confirmed live: a genre-archive fetch "cleared" after 3 polls with
      // the *previous* page's exact title and byte count). Skip for a
      // deliberate same-URL reload, where the URL never changes by design:
      // the cache-busting `cachePolicy` on `loadUrl` already covers
      // freshness there.
      final stale = !targetIsReload && polled.url == startUrl;
      if (lastLooksLikeChallenge || looksBlank || stale) {
        prevLen = null; // still settling, restart stabilization
        stable = 0;
        lastGood = null;
        continue;
      }
      // Wait for the DOM to hold still across two polls (~0.8s quiet): the CF
      // redirect can flip readyState 'complete' a tick before the real page's
      // body paints, which would otherwise capture a transitional empty DOM.
      lastGood = polled.html;
      if (prevLen != null && polled.html.length == prevLen) {
        if (++stable >= 2) {
          cfLog(
            'WebViewFetcher: $url cleared after $pollCount polls, '
            'title="${polled.title}", ${polled.html.length}b, url=${polled.url}',
          );
          return polled.html;
        }
      } else {
        stable = 0;
      }
      prevLen = polled.html.length;
    }
    // Window elapsed: best non-challenge HTML we saw, else an unsolved
    // challenge so the caller runs the solver.
    cfLog(
      'WebViewFetcher: $url did not clear after $pollCount polls '
      '(20s), lastTitle="$lastTitle", ${lastHtmlLen}b, '
      'stillLooksLikeChallenge=$lastLooksLikeChallenge (marker: $lastChallengeMarker), '
      'hadLastGood=${lastGood != null}, lastTransferSize=$lastTransferSize'
      '${lastTransferSize == 0 ? " (served from cache!)" : ""}, '
      'startUrl=$startUrl',
    );
    if (lastGood != null) return lastGood;
    throw CloudflareChallengeException(Uri.parse(url));
  }

  /// Best-effort `location.href` of whatever's currently loaded, used only
  /// to detect a `loadUrl` that silently didn't navigate (see
  /// `_navigateAndRead`'s `stale` check), so a channel timeout or a missing
  /// value here just means the check can't help this once, not a failure
  /// worth surfacing on its own.
  Future<String> _currentLocation(InAppWebViewController controller) async {
    try {
      final href = await controller
          .evaluateJavascript(source: 'location.href')
          .timeout(_channelTimeout);
      return href?.toString() ?? '';
    } on TimeoutException {
      return '';
    }
  }

  /// One poll iteration's `evaluateJavascript` reads, each individually
  /// timed out. Null means the channel itself didn't answer in time (distinct
  /// from a legitimate "not ready yet" result): the caller counts these to
  /// tell a wedged WebView from a merely slow page.
  ///
  /// [transferSize] is the page's Resource Timing `transferSize`. `0` means
  /// the browser served it entirely from its local cache rather than making
  /// a network request, which the retry-after-solve path can't afford: a
  /// cached copy of the *pre-solve* challenge page looks identical to a
  /// genuinely-still-blocked one (same title, same byte count), and
  /// `loadUrl`'s cache policy is set to bypass this, but if that policy
  /// ever stops working (plugin regression, a platform quirk), this is what
  /// would tell us, instead of another silent false "re-challenged".
  ///
  /// [url] (`location.href`) is what lets [_navigateAndRead] tell a completed
  /// navigation from a `loadUrl` that silently never left the previous page,
  /// see its `stale` check.
  Future<
    ({String ready, String title, String html, String url, int? transferSize})?
  >
  _pollOnce(InAppWebViewController controller) async {
    try {
      final ready =
          (await controller
                  .evaluateJavascript(source: 'document.readyState')
                  .timeout(_channelTimeout))
              ?.toString() ??
          '';
      final title =
          (await controller
                  .evaluateJavascript(source: 'document.title')
                  .timeout(_channelTimeout))
              ?.toString() ??
          '';
      final url =
          (await controller
                  .evaluateJavascript(source: 'location.href')
                  .timeout(_channelTimeout))
              ?.toString() ??
          '';
      // A JSON API response has no real markup to render: the WebView's
      // own raw-content viewer wraps it as the page's *only* content,
      // `<body><pre>{...}</pre></body>`, so a step expecting `parse: json`
      // would otherwise get that wrapper handed to jsonDecode instead of
      // the JSON itself. HTML pages never legitimately consist of a single
      // bare <pre> as the whole body, so this is a safe, general check, not
      // a hack for any one site: every other (real) page still gets the
      // full outerHTML unchanged.
      final html =
          (await controller
                  .evaluateJavascript(
                    source: '''
(function() {
  var b = document.body;
  if (b && b.children.length === 1 && b.children[0].tagName === 'PRE') {
    return b.children[0].textContent;
  }
  return document.documentElement.outerHTML;
})()
''',
                  )
                  .timeout(_channelTimeout))
              ?.toString() ??
          '';
      final transferSizeRaw = await controller
          .evaluateJavascript(
            source:
                "performance.getEntriesByType('navigation')[0]?.transferSize ?? -1",
          )
          .timeout(_channelTimeout);
      final transferSize = transferSizeRaw is num
          ? transferSizeRaw.toInt()
          : int.tryParse('$transferSizeRaw');
      return (
        ready: ready,
        title: title,
        html: html,
        url: url,
        transferSize: (transferSize != null && transferSize >= 0)
            ? transferSize
            : null,
      );
    } on TimeoutException {
      return null;
    }
  }

  /// Recreates the headless WebView after its platform channel stops
  /// responding. Disposing and letting the next [_ensure] build a fresh
  /// instance self-heals; without this, every future `webview:true` fetch
  /// in the session would keep retrying the same dead instance.
  Future<void> _resetWedgedWebView() async {
    final webview = _webview;
    _webview = null;
    _controller = null;
    _currentOrigin = null;
    try {
      await webview?.dispose();
    } catch (_) {
      // Best-effort: it's wedged anyway; drop the reference either way.
    }
  }

  /// Tears down the headless WebView (not currently called: it lives for
  /// the process's lifetime, but keeps ownership explicit). See
  /// [_resetWedgedWebView] for the equivalent teardown the wedge-recovery
  /// path actually uses.
  Future<void> dispose() async {
    await _webview?.dispose();
    _webview = null;
    _controller = null;
  }

  /// Broad on purpose: a missed challenge silently parses to zero results,
  /// whereas a recognized one throws → the solver, *except* one marker
  /// turned out not to be interstitial-specific at all. Cloudflare's
  /// "JavaScript Detections" (part of Bot Management) injects a
  /// `/cdn-cgi/challenge-platform/…` script tag into every HTML response,
  /// legitimate pages included, to continuously monitor visitors, not just
  /// to gate a block page (confirmed in Cloudflare's own docs). Treating that
  /// as proof of an uncleared challenge meant a real, successfully-cleared
  /// page got discarded every time and reported as "still walled". Returns
  /// which marker matched (for [cfLog]'s diagnostics: this exact
  /// false-positive class is why that's worth knowing, not just a yes/no).
  static String? _challengeMarker(String title, String html) {
    if (title.contains('Just a moment')) return 'title:Just a moment';
    if (title.contains('Attention Required')) {
      return 'title:Attention Required';
    }
    if (html.contains('cf_chl_opt')) return 'html:cf_chl_opt';
    if (html.contains('window._cf_chl')) return 'html:window._cf_chl';
    if (html.contains('cf-browser-verification')) {
      return 'html:cf-browser-verification';
    }
    if (html.contains('id="challenge-form"')) {
      return 'html:id="challenge-form"';
    }
    if (html.contains('Checking your browser')) {
      return 'html:Checking your browser';
    }
    if (html.contains('Enable JavaScript and cookies to continue')) {
      return 'html:Enable JavaScript and cookies to continue';
    }
    return null;
  }
}
