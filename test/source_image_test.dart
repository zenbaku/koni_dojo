// The image-fetch policy, in isolation. Pure Dart: no Flutter, no device, no
// network — a fake http.Client and a recording fake WebViewFetcher.
//
// This is the suite that should have existed before the policy was copied into
// four places in the host app. Each copy had its own idea of what counts as
// failure and they had genuinely diverged, so a change to one of them could
// break the others with everything green.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// A minimal but real PNG header — enough for [classifyPageBody].
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ...List.filled(64, 0),
]);

/// What a wall looks like: a successful-looking response carrying markup.
final _wall = Uint8List.fromList(utf8.encode('<html><body>Just a moment'));

/// Records what it was asked for, so a test can assert the source's own flags
/// reached the browser rather than defaults.
class _RecordingFetcher implements WebViewFetcher {
  _RecordingFetcher(this._result);

  final Uint8List Function() _result;
  int calls = 0;
  String? lastUrl;
  String? lastBaseUrl;
  bool? lastWarmByUrl;
  bool? lastViaImgTag;
  Map<String, String>? lastHeaders;

  @override
  Future<Uint8List> fetchBytes(
    String url, {
    Map<String, String>? headers,
    bool warmByUrl = false,
    bool viaImgTag = false,
    String? baseUrl,
  }) async {
    calls++;
    lastUrl = url;
    lastHeaders = headers;
    lastWarmByUrl = warmByUrl;
    lastViaImgTag = viaImgTag;
    lastBaseUrl = baseUrl;
    return _result();
  }

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? localStorageSeed,
  }) async => '';

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A client whose response body the test feeds by hand, so a fetch can be
/// aborted *while the body is still arriving*. [MockClient] cannot express
/// that: it hands back a body that has already completely arrived.
///
/// Records the cancel, because that is the assertion separating a real abort
/// from one that merely stops waiting while the download runs on regardless.
class _HandFedClient extends http.BaseClient {
  int sends = 0;
  bool cancelled = false;
  late final StreamController<List<int>> body = StreamController<List<int>>(
    onCancel: () => cancelled = true,
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    return http.StreamedResponse(body.stream, 200);
  }
}

void main() {
  final url = Uri.parse('https://cdn.example/chapter/1/p1.jpg');

  http.Client clientReturning(
    int status,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) => MockClient((_) async => http.Response.bytes(body, status, headers: headers));

  group('the happy path', () {
    test('a 200 carrying an image is the answer, and no browser is woken',
        () async {
      final fetcher = _RecordingFetcher(() => _png);
      final bytes = await fetchSourceImage(
        url,
        client: clientReturning(200, _png),
        webViewFetcher: fetcher,
      );
      expect(bytes, _png);
      expect(fetcher.calls, 0, reason: 'a working fetch must not open a browser');
    });

    test('the throttle runs before the request', () async {
      var throttled = false;
      await fetchSourceImage(
        url,
        client: MockClient((_) async {
          expect(throttled, isTrue, reason: 'request went out un-throttled');
          return http.Response.bytes(_png, 200);
        }),
        throttle: () async => throttled = true,
      );
      expect(throttled, isTrue);
    });
  });

  group('walls', () {
    // The divergence that mattered: three of the app's four copies accepted
    // this, handed markup to an image decoder, and produced a broken page
    // with no error anywhere near the cause.
    test('a 200 carrying markup is a wall, not an image', () async {
      final fetcher = _RecordingFetcher(() => _png);
      final bytes = await fetchSourceImage(
        url,
        client: clientReturning(200, _wall),
        webViewFetcher: fetcher,
      );
      expect(fetcher.calls, 1, reason: 'the 200-with-markup wall went undetected');
      expect(bytes, _png);
    });

    test('a Cloudflare-shaped non-200 falls back to the browser', () async {
      final fetcher = _RecordingFetcher(() => _png);
      final bytes = await fetchSourceImage(
        url,
        client: clientReturning(403, _wall, headers: {'cf-mitigated': 'challenge'}),
        webViewFetcher: fetcher,
      );
      expect(fetcher.calls, 1);
      expect(bytes, _png);
    });

    test('an ordinary error does NOT wake the browser', () async {
      final fetcher = _RecordingFetcher(() => _png);
      await expectLater(
        fetchSourceImage(
          url,
          client: clientReturning(404, Uint8List(0)),
          webViewFetcher: fetcher,
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(fetcher.calls, 0,
          reason: 'a 404 is not a challenge; driving a browser is pure cost');
    });

    test('walled with no browser available throws the challenge exception',
        () async {
      await expectLater(
        fetchSourceImage(url, client: clientReturning(200, _wall)),
        throwsA(isA<CloudflareChallengeException>()),
      );
    });
  });

  test('an empty 200 is a broken response, not a challenge', () async {
    // classifyPageBody calls empty a wall — right for "never store this",
    // wrong for "is this worth driving a browser through". Routing it to the
    // WebView costs tens of seconds and reaches the user as an offer to solve
    // a challenge that was never served.
    final fetcher = _RecordingFetcher(() => _png);
    await expectLater(
      fetchSourceImage(
        url,
        client: clientReturning(200, Uint8List(0)),
        webViewFetcher: fetcher,
      ),
      throwsA(isA<http.ClientException>()),
    );
    expect(fetcher.calls, 0);
  });

  group('the browser is not trusted', () {
    test('bytes that are themselves a wall are rejected', () async {
      final fetcher = _RecordingFetcher(() => _wall);
      await expectLater(
        fetchSourceImage(
          url,
          client: clientReturning(200, _wall),
          webViewFetcher: fetcher,
        ),
        throwsA(isA<CloudflareChallengeException>()),
        reason: 'a WebView can hand back the very wall it was sent to defeat',
      );
    });

    test('empty bytes are rejected', () async {
      final fetcher = _RecordingFetcher(() => Uint8List(0));
      await expectLater(
        fetchSourceImage(
          url,
          client: clientReturning(200, _wall),
          webViewFetcher: fetcher,
        ),
        throwsA(isA<CloudflareChallengeException>()),
      );
    });
  });

  // The assertion that would have caught a mistake at any of the 13 app call
  // sites that used to thread these by hand.
  test('the source\'s own recovery flags reach the browser', () async {
    final fetcher = _RecordingFetcher(() => _png);
    await fetchSourceImage(
      url,
      client: clientReturning(200, _wall),
      headers: const {'referer': 'https://example.test/'},
      webViewFetcher: fetcher,
      warmByUrl: true,
      viaImgTag: true,
      baseUrl: 'https://example.test',
    );
    expect(fetcher.lastUrl, url.toString());
    expect(fetcher.lastWarmByUrl, isTrue);
    expect(fetcher.lastViaImgTag, isTrue);
    expect(fetcher.lastBaseUrl, 'https://example.test');
    expect(fetcher.lastHeaders, {'referer': 'https://example.test/'});
  });

  group('requiresLiveTransport', () {
    Source sourceFrom(Map<String, dynamic> extra) => htmlSource(
      SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        ...extra,
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'a'},
        'pages': {'imageSelector': 'img'},
      }),
    );

    test('a plain source can be served by a deferred transport', () {
      expect(sourceFrom({}).requiresLiveTransport, isFalse);
    });

    test('a webview source cannot', () {
      expect(sourceFrom({'webview': true}).requiresLiveTransport, isTrue);
    });

    // The widening: these say "my images need a browser" even where the
    // webview marker is absent, which an imperative source has no way to set.
    test('a warm-strategy flag alone is enough', () {
      expect(sourceFrom({'warmImageByUrl': true}).requiresLiveTransport, isTrue);
      expect(
        sourceFrom({'warmImageViaImgTag': true}).requiresLiveTransport,
        isTrue,
      );
    });
  });

  group('caller headers layer over the source, never replace it', () {
    Source sourceWith(Map<String, String> headers) => htmlSource(
      SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://site.test',
        'headers': headers,
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'a'},
        'pages': {'imageSelector': 'img'},
      }),
      client: MockClient((request) async {
        // Stands in for the real CDN, which answers 403 to anything without a
        // Referer and 200 with it.
        final referer = request.headers['Referer'] ?? request.headers['referer'];
        return referer == null
            ? http.Response('denied', 403)
            : http.Response.bytes(_png, 200);
      }),
    );

    // The regression: an ImageProvider's `headers = const {}` default is not
    // null, so a `headers ?? source` fallback kept the empty map and threw the
    // source's Referer away. Every page 403'd.
    test('an empty map does not erase them', () async {
      final bytes = await sourceWith(const {}).imageBytes(
        url,
        headers: const {},
      );
      expect(bytes, _png);
    });

    test('a per-page token arrives alongside them, not instead', () async {
      var seen = <String, String>{};
      final source = htmlSource(
        SourceConfig.fromJson({
          'id': 'f',
          'name': 'F',
          'baseUrl': 'https://site.test',
          'popular': {'path': '/p', 'itemSelector': 'a'},
          'chapters': {'itemSelector': 'a'},
          'pages': {'imageSelector': 'img'},
        }),
        client: MockClient((request) async {
          seen = request.headers;
          return http.Response.bytes(_png, 200);
        }),
      );
      await source.imageBytes(url, headers: const {'X-Token': 'abc'});
      expect(seen['X-Token'], 'abc');
      expect(
        seen.keys.map((k) => k.toLowerCase()),
        contains('referer'),
        reason: 'the source Referer was dropped when a token was supplied',
      );
    });
  });

  test('the response is handed to the caller, for diagnostics', () async {
    // Losing these was the real cost of routing the reader through here: a
    // caller that only sees the thrown result cannot tell an error page
    // wearing a 200 from a challenge from a rate limit.
    int? seenStatus;
    Map<String, String>? seenHeaders;
    await fetchSourceImage(
      url,
      client: clientReturning(200, _png, headers: {'content-type': 'image/png'}),
      onResponse: (status, headers) {
        seenStatus = status;
        seenHeaders = headers;
      },
    );
    expect(seenStatus, 200);
    expect(seenHeaders?['content-type'], 'image/png');
  });

  test('a failing response is reported too, not only a successful one',
      () async {
    int? seenStatus;
    await expectLater(
      fetchSourceImage(
        url,
        client: clientReturning(429, Uint8List(0), headers: {'retry-after': '30'}),
        onResponse: (status, _) => seenStatus = status,
      ),
      throwsA(isA<SourceImageException>()),
    );
    expect(seenStatus, 429, reason: 'a rate limit must reach the log');
  });

  test('a browser fallback is announced, so it does not read as a hang',
      () async {
    final notices = <SourceImageNotice>[];
    await fetchSourceImage(
      url,
      client: clientReturning(200, _wall),
      webViewFetcher: _RecordingFetcher(() => _png),
      onNotice: notices.add,
    );
    expect(notices, [SourceImageNotice.clearingChallenge]);
  });

  test('a transport failure still gets the browser its turn', () async {
    final fetcher = _RecordingFetcher(() => _png);
    final bytes = await fetchSourceImage(
      url,
      client: MockClient((_) async => throw http.ClientException('refused', url)),
      webViewFetcher: fetcher,
    );
    expect(fetcher.calls, 1);
    expect(bytes, _png);
  });

  group('abort', () {
    /// Lets every pending microtask run.
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    /// Counts what an abandoned fetch must not spend.
    ({http.Client client, int Function() calls}) countingClient() {
      var calls = 0;
      return (
        client: MockClient((_) async {
          calls++;
          return http.Response.bytes(_png, 200);
        }),
        calls: () => calls,
      );
    }

    test('one already complete on entry spends nothing at all', () async {
      final counted = countingClient();
      var throttled = false;
      await expectLater(
        fetchSourceImage(
          url,
          client: counted.client,
          throttle: () async => throttled = true,
          abort: Future<void>.value(),
        ),
        throwsA(isA<SourceImageAborted>()),
      );
      expect(counted.calls(), 0);
      expect(
        throttled,
        isFalse,
        reason: 'a fetch nobody wants took a rate-limit slot from one wanted',
      );
    });

    test('one arriving during the throttle throws before the request',
        () async {
      final counted = countingClient();
      final abort = Completer<void>();
      final fetch = fetchSourceImage(
        url,
        client: counted.client,
        // A limiter that never lets go, so only the abort can end this wait.
        throttle: () => Completer<void>().future,
        abort: abort.future,
      );
      await settle();
      abort.complete();
      await expectLater(fetch, throwsA(isA<SourceImageAborted>()));
      expect(counted.calls(), 0);
    });

    // The assertion this whole seam exists for. A `Future.any` that merely
    // stopped *waiting* would pass every other test in this group while the
    // page went on downloading to nobody.
    test('one arriving mid-body cancels the subscription, not just the wait',
        () async {
      final client = _HandFedClient();
      final abort = Completer<void>();
      final fetch = fetchSourceImage(url, client: client, abort: abort.future);
      client.body.add(_png.sublist(0, 8));
      await settle();
      expect(client.sends, 1, reason: 'the request should be in flight by now');
      expect(client.cancelled, isFalse);

      abort.complete();
      await expectLater(fetch, throwsA(isA<SourceImageAborted>()));
      await settle();
      expect(
        client.cancelled,
        isTrue,
        reason: 'the body kept downloading for a caller that had gone',
      );
    });

    test('one arriving before the browser fallback never starts it', () async {
      final fetcher = _RecordingFetcher(() => _png);
      final abort = Completer<void>();
      final notices = <SourceImageNotice>[];
      await expectLater(
        fetchSourceImage(
          url,
          client: clientReturning(200, _wall),
          webViewFetcher: fetcher,
          onNotice: notices.add,
          // Fires with the body in hand and before any policy runs — exactly
          // the window between "the wall arrived" and "drive a browser
          // through it", which is the one this guard covers.
          onResponse: (_, __) => abort.complete(),
          abort: abort.future,
        ),
        throwsA(isA<SourceImageAborted>()),
      );
      expect(
        fetcher.calls,
        0,
        reason: 'tens of seconds of browser for a page nobody wants',
      );
      expect(
        notices,
        isEmpty,
        reason: 'announced a challenge-clear that never started',
      );
    });

    test('one arriving with the bytes already in hand is a no-op', () async {
      final abort = Completer<void>();
      final bytes = await fetchSourceImage(
        url,
        client: clientReturning(200, _png),
        onResponse: (_, __) => abort.complete(),
        abort: abort.future,
      );
      expect(bytes, _png, reason: 'bytes already paid for were thrown away');
    });

    test('one that never completes is inert', () async {
      final fetcher = _RecordingFetcher(() => _png);
      final bytes = await fetchSourceImage(
        url,
        client: clientReturning(200, _wall),
        webViewFetcher: fetcher,
        abort: Completer<void>().future,
      );
      expect(bytes, _png);
      expect(fetcher.calls, 1, reason: 'an inert abort changed the policy');
    });

    // Not an error of this fetch's making, but a scope that fails is a scope
    // that is gone; treating it as still-wanted would be the surprise.
    test('one that completes with an error still aborts', () async {
      final counted = countingClient();
      final abort = Completer<void>();
      final fetch = fetchSourceImage(
        url,
        client: counted.client,
        throttle: () => Completer<void>().future,
        abort: abort.future,
      );
      await settle();
      abort.completeError(StateError('the scope was disposed'));
      await expectLater(fetch, throwsA(isA<SourceImageAborted>()));
      expect(counted.calls(), 0);
    });

    // The retry loops downstream branch on these two, and an abort caught by
    // either would be retried — re-running the fetch the caller just dropped.
    test('is neither a ClientException nor a SourceImageException', () {
      final aborted = SourceImageAborted(url);
      expect(aborted, isNot(isA<http.ClientException>()));
      expect(aborted, isNot(isA<SourceImageException>()));
      expect(aborted, isA<Exception>());
    });

    test('reaches through Source.imageBytes', () async {
      final source = htmlSource(
        SourceConfig.fromJson({
          'id': 'f',
          'name': 'F',
          'baseUrl': 'https://site.test',
          'popular': {'path': '/p', 'itemSelector': 'a'},
          'chapters': {'itemSelector': 'a'},
          'pages': {'imageSelector': 'img'},
        }),
        client: clientReturning(200, _png),
      );
      await expectLater(
        source.imageBytes(url, abort: Future<void>.value()),
        throwsA(isA<SourceImageAborted>()),
      );
      expect(await source.imageBytes(url), _png, reason: 'no abort, no change');
    });
  });

  test('imageRequest exposes the source\'s own headers for a native transport',
      () async {
    final source = htmlSource(
      SourceConfig.fromJson({
        'id': 'fixture',
        'name': 'Fixture',
        'baseUrl': 'https://example.test',
        'headers': {'referer': 'https://example.test/'},
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'a'},
        'pages': {'imageSelector': 'img'},
      }),
      client: clientReturning(200, _png),
    );
    final request = source.imageRequest(url);
    expect(request.url, url);
    expect(request.headers, isNotEmpty,
        reason: 'a native downloader would send a bare request without these');
  });
}
