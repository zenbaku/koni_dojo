import 'package:http/http.dart' as http;

/// Thrown by the retry layer when a source response is a Cloudflare challenge
/// (an interstitial / Turnstile / "verify you are human" page) rather than the
/// content. Carries the [url] that was blocked so the WebView solver knows where
/// to send the user to clear it; on success the request is retried with the
/// captured `cf_clearance` cookie.
///
/// It is **not** a transient error: the retry loop throws it immediately rather
/// than backing off, because retrying the same HTTP client only earns the same
/// challenge. Only solving it in a browser changes the outcome.
class CloudflareChallengeException implements Exception {
  CloudflareChallengeException(this.url);

  final Uri url;

  String get host => url.host;

  @override
  String toString() =>
      'CloudflareChallengeException: blocked by Cloudflare at $host';
}

/// Whether [response] is a Cloudflare challenge page rather than real content.
///
/// Cloudflare serves challenges as 403 or 503 from a `Server: cloudflare`
/// edge, marked either by the `cf-mitigated: challenge` header (newer managed
/// challenges) or by the challenge runtime's fingerprints in the HTML body
/// (`Just a moment…`, the `/cdn-cgi/challenge-platform` script, `__cf_chl…`).
/// A plain 403/503 from a non-Cloudflare origin is left alone; it's a real
/// error, not something a browser can clear.
bool isCloudflareChallenge(http.Response response) {
  final status = response.statusCode;
  if (status != 403 && status != 503) return false;

  if (response.headers['cf-mitigated']?.toLowerCase() == 'challenge') {
    return true;
  }

  final server = (response.headers['server'] ?? '').toLowerCase();
  if (!server.contains('cloudflare')) return false;

  final body = response.body;
  return body.contains('Just a moment') ||
      body.contains('/cdn-cgi/challenge-platform') ||
      body.contains('challenge-platform') ||
      body.contains('__cf_chl') ||
      body.contains('cf_chl_opt') ||
      body.contains('cf-chl');
}
