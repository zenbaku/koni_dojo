// Live E2E for a Cloudflare-walled source, through a real Chrome.
//
//   dart test test/natomanga_live_test.dart -P live
//
// Plain `dart test` — no Flutter, no device, no simulator. That is what the
// CDP transport buys: the same configs and the same engine ops as the app,
// driven by a browser that a persistent profile keeps cleared.
//
// Opt-in: it needs the network and a Chrome. Tagged `live` so the ordinary
// suite skips it.
//
// **This currently fails, and the reason is documented rather than hidden.**
// natomanga is behind Cloudflare, and Cloudflare rejects a CDP-attached
// Chrome outright — measured one variable at a time: plain Chrome clears in
// under 75 seconds unattended, the same profile with a DevTools client
// attached never clears, and neither does one already holding a clearance.
// See `lib/chrome_cdp.dart` for the table and what would actually be needed.
//
// It is kept because it is the check we want, it will pass the moment a
// transport that Cloudflare accepts exists, and every stage below the wall is
// already proven correct against the live site. Deleting it would only make
// the gap invisible.
//
// The config is the shipped one, read from the extension repo rather than
// copied here, so this tests what actually ships.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:koni_dojo/chrome_cdp.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

String get _profile =>
    Platform.environment['CHROME_PROFILE'] ??
    '${Platform.environment['HOME']}/.konimanga-chrome-profile';

String get _configPath =>
    Platform.environment['NATOMANGA_CONFIG'] ??
    '../koni_dojo_repo/extensions/natomanga.json';

void main() {
  late ChromeCdpFetcher chrome;

  setUpAll(() async {
    // Warm the profile without CDP first: Cloudflare refuses a DevTools
    // connection outright, but a plain Chrome earns the clearance on its own,
    // and the cookie is what the CDP session then rides. Skipped instantly
    // once the profile has one.
    chrome = await ChromeCdpFetcher.launch(
      userDataDir: _profile,
      warmUpUrl: 'https://www.natomanga.com/',
    );
  });

  tearDownAll(() async => chrome.close());

  test('reads Martial Peak (colored) end to end', () async {
    final file = File(_configPath);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'no config at $_configPath — set NATOMANGA_CONFIG',
    );
    final extension =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final config = SourceConfig.fromJson(
      (extension['sources'] as List<dynamic>).first as Map<String, dynamic>,
    );

    final source = htmlSource(config, webViewFetcher: chrome);
    expect(
      source.requiresLiveTransport,
      isTrue,
      reason: 'this source must be routed away from background downloading',
    );

    // 1. Search.
    final results = await source.search('martial peak', 1);
    print('SEARCH ${results.items.length} results');
    expect(results.items, isNotEmpty, reason: 'search returned nothing');

    final target = results.items.firstWhere(
      (m) =>
          m.title.toLowerCase().contains('martial peak') &&
          m.title.toLowerCase().contains('color'),
      orElse: () => throw StateError('Martial Peak (colored) not in results'),
    );
    print('TARGET "${target.title}" ${target.url}');

    // 2. Details and chapters share one fetch, the way the series screen does.
    final ref = MangaRef(target.url);
    final (details, chapters) = await source.withSharedRequests(() async {
      final d = await source.details(ref);
      final c = await source.chapters(ref);
      return (d, c);
    });
    print('DETAILS "${details.title}" cover=${details.thumbnailUrl.isNotEmpty}');
    print('CHAPTERS ${chapters.length} '
        'first="${chapters.first.name}" last="${chapters.last.name}"');
    expect(details.title, contains('Martial Peak'));
    expect(
      chapters.length,
      greaterThan(100),
      reason: 'the two-step chapter pipeline did not yield the full list',
    );

    // 3. Page list.
    final pages = await source.pages(ChapterRef(chapters.first.url));
    print('PAGES ${pages.length} first=${pages.first.url}');
    expect(pages, isNotEmpty, reason: 'the page list did not parse');

    // 4. Real bytes for page 1, through the engine's own policy — including
    //    the wall check, so markup wearing a 200 fails here rather than
    //    reaching an image decoder.
    final bytes = await source.imageBytes(
      pages.first.url,
      headers: pages.first.headers,
    );
    print('PAGE 1 ${bytes.length} bytes magic=${bytes.take(4).toList()}');
    expect(bytes.length, greaterThan(1000), reason: 'page 1 was not an image');
    expect(
      classifyPageBody(bytes.sublist(0, 32)),
      isNot(PageBodyKind.wall),
      reason: 'page 1 came back as markup — a wall wearing a 200',
    );
  }, timeout: const Timeout(Duration(minutes: 6)));
}
