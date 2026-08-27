// Live end-to-end probe for the pipeline engine's cross-format two-phase
// capability, entirely within this package (no Flutter). Point it at any
// Blogger-backed feed and run it directly:
//
//   dart run tool/pipeline_live_probe.dart https://<a-blogger-site>
//
// It drives `runFlatListPipeline` (the very runner ConfigSource.fetchPages
// uses) through a hand-authored two-step pipeline against a live
// Blogger-backed site, exercising a cross-format hop:
//   step 1  parse JSON, capture a URL from a [rel=alternate] link
//   step 2  thread that URL into the next request, parse HTML, yield page images
// Some reader clusters use this exact HTML->id->JSON shape but sit behind a
// Cloudflare challenge that can't be cleared headlessly; Blogger feeds are
// Google-hosted and reachable, so they prove the engine mechanics on live
// bytes without baking in any particular site. The deterministic equivalents
// live in test/pipeline_test.dart.
//
// Hits the network; not part of `dart test`.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:koni_dojo/koni_dojo.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/pipeline_live_probe.dart <blogger-base-url>');
    print(
      '  e.g. dart run tool/pipeline_live_probe.dart '
      'https://example.blogspot.com',
    );
    exit(2);
  }
  final base = args.first.replaceAll(RegExp(r'/+$'), '');
  final feedUrl = '$base/feeds/posts/default/-/Series?alt=json&max-results=1';
  const ua =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36';

  final client = http.Client();
  Future<String> fetch(
    String url, {
    String method = 'GET',
    String body = '',
    Map<String, String> headers = const {},
    bool document = true,
  }) async {
    final res = await client.get(
      Uri.parse(url),
      headers: {'User-Agent': ua, ...headers},
    );
    print('  fetched [$method ${res.statusCode}] $url');
    return res.body;
  }

  // Phase 1: JSON feed -> capture the first series' page URL.
  // Phase 2: fetch that HTML page -> yield its content images.
  final pipeline = Pipeline.fromJson([
    {
      'request': {'url': '{feedUrl}'},
      'parse': 'json',
      'capture': {
        'seriesUrl': {'path': 'feed.entry[0].link[rel=alternate].href'},
      },
    },
    {
      'request': {'url': '{seriesUrl}'},
      'parse': 'html',
      'yield': {
        'list': {'selector': 'div.separator img'},
        'value': {'attr': 'src', 'imageFallback': true},
      },
    },
  ]);

  final pages = await runFlatListPipeline(
    pipeline,
    {'baseUrl': base, 'feedUrl': feedUrl},
    baseUrl: base,
    fetch: fetch,
  );
  client.close();

  print('── cross-format two-phase live probe ──');
  print(
    'PAGES: ${pages.length}${pages.isEmpty ? "" : "; first=${pages.first}"}',
  );

  if (pages.isEmpty) {
    print('FAIL: pipeline yielded no pages');
    exit(1);
  }
  if (!pages.first.startsWith('http')) {
    print('FAIL: yielded value is not a resolved URL');
    exit(1);
  }
}
