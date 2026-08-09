// Fetches a real natomanga page image the way the reader does.
//
//   dart test -P live test/natomanga_image_test.dart
//
// No browser and no Cloudflare: the page images sit on a plain CDN that wants
// exactly one thing, a `Referer` for the site. Probed 2026-08-09:
//
//   no headers    403  text/html   (an error page, not an image)
//   referer only  200  image/webp  171304 bytes
//
// So this covers the half of the reading path that the walled search/details
// pages were hiding — and it needs none of the machinery they do.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

String get _configPath =>
    Platform.environment['NATOMANGA_CONFIG'] ??
    '../koni_dojo_repo/extensions/natomanga.json';

/// A page of chapter 1, read out of the live DOM on 2026-08-09. Hard-coded so
/// this test needs no walled navigation to reach the interesting part.
const _pageUrl = 'https://img-r1.2xstorage.com/martial-peak-colored/1/0.webp';

void main() {
  late SourceConfig config;

  setUpAll(() {
    final file = File(_configPath);
    if (!file.existsSync()) {
      fail('no config at $_configPath — set NATOMANGA_CONFIG');
    }
    config = SourceConfig.fromJson(
      ((jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['sources']
              as List<dynamic>)
          .first as Map<String, dynamic>,
    );
  });

  test('the config produces headers the image CDN accepts', () async {
    final source = htmlSource(config);
    final request = source.imageRequest(Uri.parse(_pageUrl));
    print('HEADERS ${request.headers}');
    expect(
      request.headers.keys.map((k) => k.toLowerCase()),
      contains('referer'),
      reason: 'without a Referer this CDN answers 403 with an HTML error page',
    );
  });

  test('imageBytes returns a real image, the way the reader asks for it',
      () async {
    final source = htmlSource(config);
    final bytes = await source.imageBytes(Uri.parse(_pageUrl));
    print('BYTES ${bytes.length} magic=${bytes.take(12).toList()}');
    expect(bytes.length, greaterThan(1000));
    expect(
      classifyPageBody(bytes.sublist(0, 32)),
      PageBodyKind.image,
      reason: 'not a recognised image — a wall or an error body got through',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a fetch with no Referer is caught, not stored as a page', () async {
    // The failure mode this guards: the CDN answers 403 with HTML, and
    // anything that treats a body as a page regardless would write markup to
    // 0001.jpg and mark the chapter downloaded.
    final bare = htmlSource(
      SourceConfig.fromJson({
        'id': 'no-referer',
        'name': 'No Referer',
        'baseUrl': 'https://example.invalid',
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'a'},
        'pages': {'imageSelector': 'img'},
      }),
    );
    await expectLater(
      bare.imageBytes(Uri.parse(_pageUrl), headers: const {}),
      throwsA(anyOf(isA<SourceImageException>(),
          isA<CloudflareChallengeException>())),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
