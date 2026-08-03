import 'package:http/http.dart' as http;

import 'cloudflare_challenge.dart';
import 'request_timeout.dart';
import 'search_status.dart';

/// GETs [uri], retrying transient failures up to [attempts] times with
/// exponential backoff, awaiting [throttle] before each try. Returns the 200
/// response.
///
/// Retried: dropped connections and timeouts (which the http client raises as
/// [http.ClientException], e.g. "Bad file descriptor" or "Timed out") and
/// HTTP 5xx/429. Not retried: permanent errors such as 404/403, which throw
/// immediately; a Cloudflare challenge throws [CloudflareChallengeException] so
/// the UI can open the WebView solver. After the final attempt the last error
/// propagates.
///
/// Source chapter-list resolution and the online reader both go through here,
/// so a single flaky response under load doesn't surface as a failure.
Future<http.Response> getWithRetry(
  http.Client client,
  Uri uri, {
  required Map<String, String> headers,
  required Future<void> Function() throttle,
  int attempts = 3,
}) => _sendWithRetry(
  uri,
  throttle: throttle,
  attempts: attempts,
  send: () => client.get(uri, headers: headers).withRequestTimeout(uri),
);

/// POSTs [body] to [uri] with the same retry/backoff/throttle policy as
/// [getWithRetry]. A form body defaults to `application/x-www-form-urlencoded`
/// unless [headers] already set a content type; declarative sources use this
/// for endpoints that only answer POST (e.g. Madara's `ajax/chapters/` and
/// `admin-ajax.php` load-more).
Future<http.Response> postWithRetry(
  http.Client client,
  Uri uri, {
  required String body,
  required Map<String, String> headers,
  required Future<void> Function() throttle,
  int attempts = 3,
}) {
  final hasContentType = headers.keys.any(
    (k) => k.toLowerCase() == 'content-type',
  );
  final merged = {
    if (body.isNotEmpty && !hasContentType)
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    ...headers,
  };
  return _sendWithRetry(
    uri,
    throttle: throttle,
    attempts: attempts,
    send: () =>
        client.post(uri, headers: merged, body: body).withRequestTimeout(uri),
  );
}

/// Shared retry loop behind [getWithRetry]/[postWithRetry]: [send] builds and
/// issues one attempt; the policy (what is transient, the backoff schedule) is
/// identical regardless of method.
Future<http.Response> _sendWithRetry(
  Uri uri, {
  required Future<void> Function() throttle,
  required int attempts,
  required Future<http.Response> Function() send,
}) async {
  for (var attempt = 1; ; attempt++) {
    // Surface progress to any ambient search-status sink (see search_status);
    // a no-op outside a search fan-out.
    reportSearchStatus(attempt == 1 ? 'Searching…' : 'Retrying…');
    await throttle();
    http.Response? response;
    try {
      response = await send();
    } on http.ClientException {
      if (attempt >= attempts) rethrow;
    }
    if (response != null) {
      if (response.statusCode == 200) return response;
      // A Cloudflare challenge isn't transient; retrying the same client only
      // earns the same wall. Surface it so the UI can open the WebView solver.
      if (isCloudflareChallenge(response)) {
        throw CloudflareChallengeException(uri);
      }
      final transient =
          response.statusCode >= 500 || response.statusCode == 429;
      if (!transient || attempt >= attempts) {
        throw http.ClientException('HTTP ${response.statusCode}', uri);
      }
    }
    // Back off before the next try: 400ms, 800ms, …
    await Future<void>.delayed(
      Duration(milliseconds: 400 * (1 << (attempt - 1))),
    );
  }
}
