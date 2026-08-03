import 'dart:typed_data';

import 'cloudflare_challenge.dart';

/// An injected seam that fetches a page **through a real WebView** (the app's
/// flutter_inappwebview) rather than the HTTP client, for `webview: true`
/// sources whose Cloudflare mode re-challenges cookie-replay from a non-browser
/// client (it binds clearance to the browser's TLS fingerprint). The WebView
/// carries that fingerprint + the cleared session, so a full-page navigation
/// returns real HTML. Same composition pattern as the `http.Client`,
/// [ClearanceStore] and [JsRunner] seams. Null where unavailable (web/tests).
///
/// See `docs/architecture-decisions.md`.
abstract interface class WebViewFetcher {
  /// Navigates to [url] in the WebView, waits for the page (and any Cloudflare
  /// interstitial) to settle, and returns the rendered HTML. Throws
  /// [CloudflareChallengeException] when the host still needs an interactive
  /// solve; the reactive guard then opens the visible solver and the caller
  /// retries (the now-cleared session lets the next navigation through).
  ///
  /// [localStorageSeed] (from `SourceConfig.localStorageSeed`) is applied
  /// once per [url]'s origin, the first time this fetcher navigates there;
  /// see that field's doc comment for why this exists and what it recovers
  /// from (confirmed live against a real source's age-gated reader).
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? localStorageSeed,
  });

  /// Same idea as [fetchHtml], but for binary responses (cover/page images)
  /// whose Cloudflare mode re-challenges plain HTTP replay even with a valid
  /// clearance cookie; some sites bind clearance to the requesting client's
  /// TLS fingerprint, which only a real browser engine reproduces. Navigates
  /// to a warming URL on [url]'s origin, waits for the same challenge-clearing
  /// as [fetchHtml], then reads [url]'s response bytes back through the
  /// WebView's own `fetch()`. Throws [CloudflareChallengeException] on the
  /// same terms as [fetchHtml].
  ///
  /// [warmByUrl] picks what that warming navigation targets: the bare origin
  /// (default, needed when a site only runs its challenge-solving JS on a
  /// real document there) or [url] itself (some CDN-only hosts WAF-block a
  /// bare root-path request outright while serving the real asset path with
  /// no challenge at all). Per-source, from `SourceConfig.warmImageByUrl`;
  /// not something to flip globally.
  ///
  /// [viaImgTag] (from `SourceConfig.warmImageViaImgTag`) is a different
  /// recovery entirely, for two failures [warmByUrl] can't fix: a WAF whose
  /// Referer check wants the *site's* origin specifically (not the image
  /// host's), or a CDN that mislabels real image bytes with a non-image
  /// `Content-Type` (breaking the browser's own image-document rendering
  /// that [warmByUrl]'s canvas extraction depends on). Navigates to (or
  /// reuses, if already parked there) [baseUrl], required when this is
  /// true, then injects a same-page `<img crossorigin="anonymous">` for
  /// [url] and canvas-reads it once loaded; sniffs bytes regardless of
  /// declared content-type, and the injected tag's Referer is genuinely the
  /// referring site, not something spoofed. Tried first when both are true;
  /// on a failed extraction (the CDN doesn't grant the cross-origin canvas
  /// read [viaImgTag] needs) falls back to [warmByUrl] instead; the two
  /// recover different hosts of the same source, not alternatives to pick
  /// one of.
  Future<Uint8List> fetchBytes(
    String url, {
    Map<String, String>? headers,
    bool warmByUrl = false,
    bool viaImgTag = false,
    String? baseUrl,
  });
}
