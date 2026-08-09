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
}) async {
  await throttle?.call();

  http.Response? response;
  try {
    response = await client.get(url, headers: headers).withRequestTimeout(url);
  } on http.ClientException {
    // Swallowed only so the WebView still gets its turn below: a host whose
    // plain client is being blocked outright is exactly one this can recover.
    response = null;
  }

  if (response != null &&
      response.statusCode == 200 &&
      !_isWall(response.bodyBytes)) {
    return response.bodyBytes;
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
    throw CloudflareChallengeException(url);
  }

  throw http.ClientException('HTTP ${response.statusCode}', url);
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
