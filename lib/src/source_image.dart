import 'dart:async';
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
  String toString() =>
      'SourceImageException: $message${uri == null ? '' : ', uri=$uri'}';
}

/// The caller stopped wanting these bytes — a chapter left, a screen closed.
///
/// **Not an error, and deliberately neither an [http.ClientException] nor a
/// [SourceImageException].** Hosts retry the first (`getWithRetry` here, the
/// app's page runner there) and branch on the second's
/// [SourceImageException.isTransient]; a retry loop that caught this would
/// re-run the exact fetch its caller just abandoned, which is the opposite of
/// the intent. An abort is an expected outcome, so hosts should suppress it
/// from error UI entirely rather than log it.
class SourceImageAborted implements Exception {
  SourceImageAborted(this.url);

  /// The image that is no longer wanted.
  final Uri url;

  @override
  String toString() => 'SourceImageAborted: the caller abandoned $url';
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
/// offering the user an interactive solve, the second isn't. [abort] adds a
/// third, [SourceImageAborted], which is not a failure at all.
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
  void Function(int status, Map<String, String> headers)? onResponse,

  /// Completes when the caller no longer wants these bytes.
  ///
  /// Optional and inert by default: a fetch with no [abort] behaves exactly as
  /// it did before this existed. Only *speculative* work should pass one — a
  /// reader preloading four pages ahead abandons all four on a chapter switch,
  /// and without this every one of them runs to completion, holding a
  /// connection for a caller that has gone.
  ///
  /// A plain future rather than a token type, deliberately: it composes with
  /// [Future.any], a [Completer] satisfies it, and it adds no new vocabulary
  /// to a package whose seams are all functions and futures.
  ///
  /// Honoured before the rate limit is taken, during it, around the request,
  /// *during the response body* (the subscription is cancelled, which is what
  /// closes the connection), and before the WebView recovery starts. Once the
  /// bytes are in hand it is a no-op — they are returned.
  Future<void>? abort,
}) async {
  // One derived signal for the whole function rather than listening to [abort]
  // in five places. An abort that completes with an *error* still counts: the
  // caller's scope failing is not this fetch's business, and treating it as a
  // live request would be the surprising reading.
  var aborted = false;
  final signal = abort?.then<void>(
    (_) => aborted = true,
    onError: (_) => aborted = true,
  );

  // Throws if the abort has landed, after giving it the one turn it needs to
  // be visible: `then` on a completed future runs as a microtask, so [aborted]
  // lags an abort by exactly one turn and reading it straight after a stretch
  // of synchronous code would always see false. The microtask queue is FIFO,
  // so one turn is enough. A fetch with no abort skips the yield and keeps its
  // timing untouched.
  Future<void> abortCheck() async {
    if (signal == null) return;
    await Future<void>.value();
    if (aborted) throw SourceImageAborted(url);
  }

  // Before anything is spent. A fetch abandoned before it started must not
  // take a rate-limit slot from one that is still wanted.
  await abortCheck();

  // Raced rather than merely checked: a limiter can hold this for seconds, and
  // an abort arriving mid-wait shouldn't have to wait the slot out. The check
  // above is the one that keeps an already-abandoned fetch from *taking* a
  // slot — racing alone would still call `acquire`.
  final throttling = throttle?.call();
  if (throttling != null) await _untilAborted(throttling, signal, url);

  http.Response? response;
  try {
    // Streamed rather than a plain get so callers can report real download
    // progress. A reader showing a determinate progress bar per page needs
    // this; collapsing it to a single future would silently turn every page
    // into an indeterminate spinner.
    final request = http.Request('GET', url)..headers.addAll(headers);
    // Same cap RequestTimeout applies, spelled out because that extension is
    // typed to Future<Response> and this send returns a streamed one.
    final sending = client
        .send(request)
        .timeout(
          sourceRequestTimeout,
          onTimeout: () => throw http.ClientException(
            'Timed out after ${sourceRequestTimeout.inSeconds}s',
            url,
          ),
        );
    final http.StreamedResponse streamed;
    try {
      streamed = await _untilAborted(sending, signal, url);
    } on SourceImageAborted {
      // The send is still in flight, and when it lands nobody will read it —
      // an unread response stream holds its connection open. `listen(null)`
      // then `cancel()`, never `drain()`: draining downloads the very body
      // this abort exists to avoid downloading.
      unawaited(
        sending.then((r) => r.stream.listen(null).cancel(), onError: (_) {}),
      );
      rethrow;
    }
    final builder = BytesBuilder(copy: false);
    // An explicit subscription rather than `await for`, which cannot be
    // cancelled from outside. Cancelling is the part that actually closes the
    // connection: stopping the await alone would leave a megabyte streaming to
    // a caller that has already gone — on web, base64-encoded and shipped
    // through the browser process on the way.
    final read = Completer<void>();
    final sub = streamed.stream.listen(
      (chunk) {
        builder.add(chunk);
        onProgress?.call(builder.length, streamed.contentLength);
      },
      onError: (Object error, StackTrace stack) {
        if (!read.isCompleted) read.completeError(error, stack);
      },
      onDone: () {
        if (!read.isCompleted) read.complete();
      },
      cancelOnError: true,
    );
    if (signal != null) {
      unawaited(
        signal.then((_) {
          if (read.isCompleted) return;
          // Cancel first, unblock second, and don't wait on the cancel: the
          // caller is freed now while the connection closes behind it.
          unawaited(sub.cancel());
          read.completeError(SourceImageAborted(url));
        }),
      );
    }
    await read.future;
    response = http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      request: streamed.request,
      reasonPhrase: streamed.reasonPhrase,
    );
    // Handed to the caller before any policy runs. A host's own answer —
    // content-type, cf-mitigated, retry-after — is what tells an error page
    // wearing a 200 from a challenge from a rate limit, and a caller that
    // only sees the thrown result cannot recover any of it.
    onResponse?.call(response.statusCode, response.headers);
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
    // The single worst thing to do for an abandoned page: the WebView has no
    // cancellation of its own and can take tens of seconds, so an abort that
    // landed while the wall was still arriving has to stop here — including
    // one that landed during the synchronous stretch just above, which is why
    // this goes through [abortCheck] rather than reading the flag. Ahead of
    // [onNotice] as well: announcing a challenge-clear that never starts reads
    // as a hang of its own. And ahead of the challenge exception, which hosts
    // answer by offering the user an interactive solve — absurd for a page
    // they have already left. Every post-abort outcome is the same type.
    await abortCheck();
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

/// [work], unless [signal] completes first — then [SourceImageAborted].
///
/// [signal] is listed first so that when both are already complete the abort
/// still wins: [Future.any] registers its listeners in order onto a FIFO
/// microtask queue. Losing futures are not left unhandled — `Future.any`
/// attaches an error handler to every entry.
///
/// Only useful where the work has no cancellation of its own. Where it does —
/// the response body — cancel it instead: this merely stops *waiting*, and a
/// download nobody is waiting for is still a download.
Future<T> _untilAborted<T>(Future<T> work, Future<void>? signal, Uri url) {
  if (signal == null) return work;
  return Future.any([
    signal.then<T>((_) => throw SourceImageAborted(url)),
    work,
  ]);
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
