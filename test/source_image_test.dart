// The image-fetch policy, in isolation. Pure Dart: no Flutter, no device, no
// network — a fake http.Client and a recording fake WebViewFetcher.
//
// This is the suite that should have existed before the policy was copied into
// four places in the host app. Each copy had its own idea of what counts as
// failure and they had genuinely diverged, so a change to one of them could
// break the others with everything green.
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
