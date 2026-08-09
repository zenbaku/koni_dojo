// Coalescing identical GETs inside an explicit scope.
//
// A series screen asks for details and then chapters, and on most sites both
// parse the same document. On a `webview: true` source that was two full
// browser navigations to render one screen — the expensive kind, since each
// one drives a real browser through whatever the site puts in front of it.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

const _page = '''
<html><body>
  <h1 class="title">A Series</h1>
  <ul>
    <li class="chapter"><a href="/read/1">Chapter 1</a></li>
    <li class="chapter"><a href="/read/2">Chapter 2</a></li>
  </ul>
</body></html>
''';

void main() {
  late List<String> requested;

  Source build() {
    requested = [];
    return htmlSource(
      SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        'details': {'titleSelector': 'h1.title'},
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {
          'itemSelector': 'li.chapter',
          'nameSelector': 'a',
          'urlSelector': 'a',
          'urlAttr': 'href',
        },
        'pages': {'imageSelector': 'img'},
      }),
      client: MockClient((request) async {
        requested.add(request.url.path);
        return http.Response(_page, 200);
      }),
    );
  }

  test('details and chapters share one fetch inside a scope', () async {
    final source = build();
    final ref = MangaRef('/manga/one');

    final result = await source.withSharedRequests(() async {
      final details = await source.details(ref);
      final chapters = await source.chapters(ref);
      return (details, chapters);
    });

    expect(result.$1.title, 'A Series');
    expect(result.$2, hasLength(2), reason: 'the shared body must still parse');
    expect(
      requested,
      ['/manga/one'],
      reason: 'the same page was fetched twice for one screen',
    );
  });

  test('a later scope refetches, so a refresh is never stale', () async {
    final source = build();
    final ref = MangaRef('/manga/one');

    for (var i = 0; i < 2; i++) {
      await source.withSharedRequests(() async {
        await source.details(ref);
        await source.chapters(ref);
      });
    }

    expect(
      requested,
      ['/manga/one', '/manga/one'],
      reason: 'sharing leaked past the scope that opened it — a refresh would '
          'answer with a stale page',
    );
  });

  test('outside a scope nothing is shared', () async {
    final source = build();
    final ref = MangaRef('/manga/one');
    await source.details(ref);
    await source.chapters(ref);
    expect(requested, ['/manga/one', '/manga/one']);
  });

  test('nesting is refcounted: an inner scope does not end the outer', () async {
    final source = build();
    final ref = MangaRef('/manga/one');

    await source.withSharedRequests(() async {
      await source.withSharedRequests(() async => source.details(ref));
      await source.chapters(ref);
    });

    expect(requested, ['/manga/one']);
  });
}
