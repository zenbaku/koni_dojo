import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloudflare_challenge.dart';
import 'page_body.dart';
import 'request_timeout.dart';
import 'web_view_fetcher.dart';

/// Everything a host needs to fetch one of a source's images itself.
///
/// The escape hatch for hosts that *cannot* call [fetchSourceImage] because
/// the fetch doesn't happen in Dart at all — the app's native download runner
/// hands URL and headers to a platform downloader that keeps working while
/// the process is suspended. Without this they'd have to reach into the
/// source's fields and rebuild the header set by hand, which is exactly the
/// duplication this file exists to end.
///
/// A host using this gives up the wall detection and WebView recovery in
/// [fetchSourceImage] and takes responsibility for both.
typedef SourceImageRequest = ({Uri url, Map<String, String> headers});

/// An image fetch that failed on the response rather than the transport.
///
/// Implements [http.ClientException] so existing catches keep working, and
/// adds [statusCode] so a caller can implement a retry policy — 5xx and 429
/// are worth another attempt, a 404 is not — without parsing a message
/// string. The download runner's retry loop is the reason this exists: it
/// composes over [fetchSourceImage] and would otherwise be blind.
class SourceImageException implements http.ClientException {
  SourceImageException(this.statusCode, this.uri, [String? message])
    : message = message ?? 'HTTP $statusCode';

  /// The response status, or null when there wasn't a response at all.
  final int? statusCode;

  @override
  final String message;

  @override
  final Uri? uri;

  /// Whether another attempt could plausibly succeed: a server-side or
  /// rate-limit failure, as opposed to a definitive answer.
  bool get isTransient =>
      statusCode != null && (statusCode! >= 500 || statusCode == 429);

  @override
  String toString() => 'SourceImageException: $message${uri == null ? '' : ', uri=$uri'}';
}

/// Why a fetch is taking much longer than a fetch should.
enum SourceImageNotice {
  /// Fell back to driving a headless browser through a challenge, which can
  /// take tens of seconds with no visible progress. Hosts surface this so it
  /// doesn't read as a hang.
  clearingChallenge,
}

/// Fetches the bytes of one image belonging to a source — a page or a cover.
///
/// **This is the single definition of that policy.** It used to live in four
/// places in the host app (the reader's image provider, the cover widget, the
/// downloader, and the in-process page runner), each with its own idea of what
/// counts as failure, and they had genuinely diverged: only one of the four
/// noticed that an HTTP **200 carrying markup** is a wall rather than an
/// image. The other three handed the markup downstream, where it surfaced as
/// an undecodable page with no error anywhere near the cause.
///
/// The policy, in order:
///
/// 1. Plain HTTP GET. A 200 whose body doesn't look like a wall is the answer.
/// 2. A 200 whose body *does* look like a wall (see [classifyPageBody]), or a
///    non-200 that looks like a Cloudflare challenge, means the host is being
///    challenged rather than served.
/// 3. If a [webViewFetcher] is available, re-fetch through it — a real browser
///    with the site's cleared session. [warmByUrl] and [viaImgTag] select how,
///    and both come from the source's own config rather than the caller.
/// 4. **The browser's bytes are re-validated, not trusted.** A WebView can
///    hand back the very wall it was sent to get past.
///
/// Throws [CloudflareChallengeException] when the host is walled and no
/// browser recovered it, and [http.ClientException] for an ordinary transport
/// or status failure. Those two are deliberately distinct: the first is worth
/// offering the user an interactive solve, the second isn't.
Future<Uint8List> fetchSourceImage(
  Uri url, {
  required http.Client client,
  Map<String, String> headers = const {},
  WebViewFetcher? webViewFetcher,
  bool warmByUrl = false,
  bool viaImgTag = false,
  String baseUrl = '',
  Future<void> Function()? throttle,
  void Function(SourceImageNotice notice)? onNotice,
  void Function(int received, int? total)? onProgress,
}) async {
  await throttle?.call();

  http.Response? response;
  try {
    // Streamed rather than a plain get so callers can report real download
    // progress. A reader showing a determinate progress bar per page needs
    // this; collapsing it to a single future would silently turn every page
    // into an indeterminate spinner.
    final request = http.Request('GET', url)..headers.addAll(headers);
    // Same cap RequestTimeout applies, spelled out because that extension is
    // typed to Future<Response> and this send returns a streamed one.
    final streamed = await client
        .send(request)
        .timeout(
          sourceRequestTimeout,
          onTimeout: () => throw http.ClientException(
            'Timed out after ${sourceRequestTimeout.inSeconds}s',
            url,
          ),
        );
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      onProgress?.call(builder.length, streamed.contentLength);
    }
    response = http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      request: streamed.request,
      reasonPhrase: streamed.reasonPhrase,
    );
  } on http.ClientException {
    // Swallowed only so the WebView still gets its turn below: a host whose
    // plain client is being blocked outright is exactly one this can recover.
    response = null;
  }

  if (response != null && response.statusCode == 200) {
    // Empty is a broken response, not a challenge. [classifyPageBody] calls it
    // a wall — right for "never store this as a page", wrong here: routing it
    // to the browser wastes tens of seconds and surfaces to the user as an
    // offer to solve a challenge that was never served. Callers retry on a
    // ClientException, which is the recovery this actually wants.
    if (response.bodyBytes.isEmpty) {
      throw SourceImageException(200, url, 'Empty image body');
    }
    if (!_isWall(response.bodyBytes)) return response.bodyBytes;
  }

  // A 200 that got here carried markup; that's a wall wearing a success code.
  final walled =
      response == null ||
      response.statusCode == 200 ||
      isCloudflareChallenge(response);

  if (walled) {
    final fetcher = webViewFetcher;
    if (fetcher != null) {
      onNotice?.call(SourceImageNotice.clearingChallenge);
      final bytes = await fetcher.fetchBytes(
        url.toString(),
        headers: headers,
        warmByUrl: warmByUrl,
        viaImgTag: viaImgTag,
        baseUrl: baseUrl,
      );
      if (bytes.isNotEmpty && !_isWall(bytes)) return bytes;
    }
    // Only a challenge-shaped response earns the challenge exception. A
    // request that never completed is a transport failure, and calling it a
    // challenge would be a lie with consequences: hosts branch on this type to
    // offer an interactive solve, and a reader shown that instead of an
    // ordinary error keeps a broken page it would otherwise just retry.
    if (response == null) {
      throw SourceImageException(null, url, 'Image request failed');
    }
    throw CloudflareChallengeException(url);
  }

  throw SourceImageException(response.statusCode, url);
}

/// Asymmetric on purpose: only a body that positively looks like markup is
/// rejected. See [classifyPageBody] for why requiring a known image signature
/// would be the worse trade.
bool _isWall(Uint8List bytes) {
  final head = bytes.length <= pageBodyProbeLength
      ? bytes
      : Uint8List.sublistView(bytes, 0, pageBodyProbeLength);
  return classifyPageBody(head) == PageBodyKind.wall;
}
