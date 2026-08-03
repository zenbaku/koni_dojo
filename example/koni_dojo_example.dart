// A self-contained, offline example: build a Source from a declarative HTML
// config and drive the reader path (popular → details → chapters → pages),
// with a MockClient standing in for the live site so it runs without a network.
//
//   dart run example/koni_dojo_example.dart
//
// In real use you drop the MockClient and pass a real http.Client (or none).
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';

/// The config *is* the source: no per-site Dart code.
final config = SourceConfig.fromJson({
  'id': 'example',
  'name': 'Example',
  'lang': 'en',
  'baseUrl': 'https://example.test',
  'popular': {
    'path': '/popular?page={page}',
    'itemSelector': 'div.card',
    'titleSelector': 'a.title',
    'urlSelector': 'a.title',
    'urlAttr': 'href',
  },
  'details': {'titleSelector': 'h1', 'descriptionSelector': 'p.summary'},
  'chapters': {
    'itemSelector': 'li.chapter',
    'nameSelector': 'a',
    'urlSelector': 'a',
    'urlAttr': 'href',
  },
  'pages': {'imageSelector': 'div.reader img', 'imageAttr': 'src'},
});

// A fake site so the example runs offline. Delete this and pass a real client.
http.Client fakeSite() => MockClient((req) async {
  final path = req.url.path;
  if (path == '/popular') {
    return http.Response(
      '<div class="card"><a class="title" href="/manga/1">Alpha</a></div>',
      200,
    );
  }
  if (path == '/manga/1') {
    return http.Response(
      '<h1>Alpha</h1><p class="summary">A tale.</p>'
      '<li class="chapter"><a href="/manga/1/c1">Chapter 1</a></li>',
      200,
    );
  }
  if (path == '/manga/1/c1') {
    return http.Response('<div class="reader"><img src="/p/1.jpg"></div>', 200);
  }
  return http.Response('not found', 404);
});

Future<void> main() async {
  final source = htmlSource(config, client: fakeSite());

  final popular = await source.popular(1);
  print('popular: ${popular.items.map((m) => m.title).toList()}');

  final ref = MangaRef(popular.items.first.url);
  print('details: ${(await source.details(ref)).title}');

  final chapters = await source.chapters(ref);
  print('chapters: ${chapters.map((c) => c.name).toList()}');

  final pages = await source.pages(ChapterRef(chapters.first.url));
  print('pages: ${pages.map((p) => p.url).toList()}');
}
