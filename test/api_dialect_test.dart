import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';

/// Delta's config running on the generic [apiSource] engine: the reference
/// acceptance test for the declarative API dialect (multi-path fallback
/// title/description, relationship-array author/cover extraction, template
/// cover URLs, grouped tag filters, chapter-feed pagination with an
/// external-URL skip). Reads a fictional fixture (`.example` domain,
/// invented site) exercising a real-world JSON:API-style shape; a real
/// installable API-dialect source lives in the data repo (koni_dojo_repo).
Source _delta(http.Client client) {
  final entry =
      jsonDecode(
            File(
              'test/fixtures/workspace/extensions/delta.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  return apiSource(
    ApiSourceConfig.fromJson(
      (entry['sources'] as List).single as Map<String, dynamic>,
    ),
    client: client,
  );
}

Map<String, dynamic> _tag(String id, String name, String group) => {
  'id': id,
  'attributes': {
    'name': {'en': name},
    'group': group,
  },
};

Map<String, dynamic> _mangaData(String id, String title) => {
  'id': id,
  'type': 'manga',
  'attributes': {
    'title': {'en': title},
    'description': {'en': 'Description of $title'},
    'tags': [
      _tag('tag-horror', 'Horror', 'genre'),
      _tag('tag-strip', 'Long Strip', 'format'),
    ],
  },
  'relationships': [
    {
      'type': 'cover_art',
      'attributes': {'fileName': 'cover-$id.jpg'},
    },
    {
      'type': 'author',
      'attributes': {'name': 'Author of $title'},
    },
  ],
};

http.Client _fakeApi({List<Uri>? requests}) => MockClient((request) async {
  requests?.add(request.url);
  final path = request.url.path;
  if (path == '/titles/tags') {
    return http.Response(
      jsonEncode({
        'data': [
          _tag('tag-action', 'Action', 'genre'),
          _tag('tag-horror', 'Horror', 'genre'),
          _tag('tag-school', 'School Life', 'theme'),
        ],
      }),
      200,
    );
  }
  if (path == '/titles') {
    return http.Response(
      jsonEncode({
        'data': [
          _mangaData('m-1', 'First Manga'),
          _mangaData('m-2', 'Second Manga'),
        ],
        'total': 50,
      }),
      200,
    );
  }
  if (path == '/titles/m-1/chapters') {
    return http.Response(
      jsonEncode({
        'data': [
          {
            'id': 'ch-1',
            'attributes': {
              'chapter': '1',
              'volume': '1',
              'title': 'Beginnings',
              'publishAt': '2024-01-05T10:00:00+00:00',
            },
          },
          {
            'id': 'ch-ext',
            'attributes': {
              'chapter': '2',
              'externalUrl': 'https://elsewhere.example',
            },
          },
        ],
        'total': 2,
      }),
      200,
    );
  }
  if (path == '/pages/ch-1') {
    return http.Response(
      jsonEncode({
        'baseUrl': 'https://cdn.delta.example',
        'chapter': {
          'hash': 'abc123',
          'data': ['1.png', '2.png'],
        },
      }),
      200,
    );
  }
  if (path == '/pages/ch-malformed') {
    return http.Response(jsonEncode({'result': 'ok'}), 200);
  }
  return http.Response('not found', 404);
});

void main() {
  late Source source;

  setUp(() {
    source = _delta(_fakeApi());
  });

  test('fetchPopular maps manga, covers and authors', () async {
    final page = await source.popular(1);
    expect(page.items.length, 2);
    expect(page.hasNextPage, true);

    final first = page.items.first;
    expect(first.url, 'm-1');
    expect(first.title, 'First Manga');
    expect(first.author, 'Author of First Manga');
    expect(first.description, 'Description of First Manga');
    expect(
      first.thumbnailUrl,
      'https://cdn.delta.example/covers/m-1/cover-m-1.jpg.jpg',
    );
  });

  test('manga tags become genres', () async {
    final page = await source.popular(1);
    expect(page.items.first.genres, ['Horror', 'Long Strip']);
  });

  test('fetchFilters groups tags and caches the tag list', () async {
    final requests = <Uri>[];
    source = _delta(_fakeApi(requests: requests));

    final groups = await source.filters();
    expect(groups.map((g) => g.name), ['Genres', 'Themes']);
    final genres = groups.first;
    expect(genres.supportsExclusion, isTrue);
    expect(genres.options.map((o) => o.label), ['Action', 'Horror']);

    await source.filters();
    expect(requests.where((u) => u.path == '/titles/tags').length, 1);
  });

  test('selected tags become includedTags/excludedTags parameters', () async {
    final requests = <Uri>[];
    source = _delta(_fakeApi(requests: requests));
    // Group ids are `<filter id>:<group key>`: the `tags` filter split by
    // Delta's tag groups.
    final selection = FilterSelection()
      ..set('tags:genre', 'tag-horror', FilterState.included)
      ..set('tags:theme', 'tag-school', FilterState.excluded);

    await source.search('', 1, filters: selection);

    // The engine resolves the group→parameter mapping first, so the tag
    // list fetch precedes the search request.
    final query = requests
        .singleWhere((u) => u.path == '/titles')
        .queryParametersAll;
    expect(query['includedTags[]'], ['tag-horror']);
    expect(query['excludedTags[]'], ['tag-school']);
    expect(query.containsKey('title'), isFalse);
  });

  test('fetchChapters labels chapters and skips external ones', () async {
    final chapters = await source.chapters(const MangaRef('m-1'));
    expect(chapters.length, 1);
    expect(chapters.single.url, 'ch-1');
    expect(chapters.single.name, 'Vol. 1 Ch. 1 Beginnings');
    expect(chapters.single.number, 1);
  });

  test('fetchChapters parses the publishAt upload date', () async {
    final chapters = await source.chapters(const MangaRef('m-1'));
    expect(chapters.single.dateUpload, DateTime.utc(2024, 1, 5, 10));
  });

  test('fetchPages builds page URLs from the page server', () async {
    final pages = await source.pages(const ChapterRef('ch-1'));
    expect(pages.map((p) => p.url.toString()), [
      'https://cdn.delta.example/data/abc123/1.png',
      'https://cdn.delta.example/data/abc123/2.png',
    ]);
  });

  test(
    'fetchPages rejects a page-server response missing its fields',
    () async {
      await expectLater(
        source.pages(const ChapterRef('ch-malformed')),
        throwsFormatException,
      );
    },
  );

  group('explicit steps', () {
    // A page list reached only through a JSON id hop (the multi-id-API shape):
    // GET the chapter object, capture an inner id, then GET the page server.
    ApiSourceConfig stepsConfig() => ApiSourceConfig.fromJson({
      'type': 'api',
      'id': 's',
      'name': 'S',
      'lang': 'en',
      'baseUrl': 'https://s.example',
      'apiUrl': 'https://api.example',
      'popular': {'path': '/popular', 'items': 'data'},
      'chapters': {'path': '/feed', 'items': 'data'},
      'pages': {
        'items': 'images',
        'template': '{value}',
        'steps': [
          {
            'request': {'url': '{apiUrl}/chapter/{url}'},
            'parse': 'json',
            'capture': {
              'sid': {'path': 'data.server'},
            },
          },
          {
            'request': {'url': '{apiUrl}/server/{sid}'},
            'parse': 'json',
          },
        ],
      },
    });

    test('a steps: block survives a JSON round trip', () {
      final restored = ApiSourceConfig.fromJson(stepsConfig().toJson());
      expect(restored.pages.steps, isNotNull);
      expect(restored.toJson(), stepsConfig().toJson());
    });

    test('fetchPages runs the steps and extracts off the final root', () async {
      final requested = <String>[];
      final source = apiSource(
        stepsConfig(),
        client: MockClient((req) async {
          requested.add(req.url.toString());
          if (req.url.path == '/chapter/c1') {
            return http.Response('{"data":{"server":"srv9"}}', 200);
          }
          if (req.url.path == '/server/srv9') {
            return http.Response('{"images":["a.jpg","b.jpg"]}', 200);
          }
          return http.Response('not found: ${req.url}', 404);
        }),
      );
      final pages = await source.pages(const ChapterRef('c1'));
      expect(requested, [
        'https://api.example/chapter/c1',
        'https://api.example/server/srv9',
      ]);
      // Bare filenames resolve against apiUrl, same as an already-absolute
      // page-server URL passing through unchanged. See the resolve test
      // below.
      expect(pages.map((p) => p.url.toString()), [
        'https://api.example/a.jpg',
        'https://api.example/b.jpg',
      ]);
    });
  });

  test('fetchPages resolves a relative pages value against apiUrl, '
      'leaving an absolute one untouched', () async {
    final cfg = ApiSourceConfig.fromJson({
      'type': 'api',
      'id': 'r',
      'name': 'R',
      'lang': 'en',
      'baseUrl': 'https://r.example',
      'apiUrl': 'https://api.r.example',
      'popular': {'path': '/popular', 'items': 'data'},
      'chapters': {'path': '/feed', 'items': 'data'},
      'pages': {'path': '/c/{url}', 'items': 'images', 'template': '{value}'},
    });
    final source = apiSource(
      cfg,
      client: MockClient((req) async {
        return http.Response(
          jsonEncode({
            'images': [
              'uploads/series/x/01.jpg',
              'https://cdn.other.example/x/02.jpg',
            ],
          }),
          200,
        );
      }),
    );
    final pages = await source.pages(const ChapterRef('ch-1'));
    expect(pages.map((p) => p.url.toString()), [
      'https://api.r.example/uploads/series/x/01.jpg',
      'https://cdn.other.example/x/02.jpg',
    ]);
  });

  test('descriptions containing HTML are normalized to plain text', () async {
    // Some API sources return the synopsis as HTML; the UI should show plain
    // text (block/<br> tags → line breaks, other tags stripped, entities decoded).
    final cfg = ApiSourceConfig.fromJson({
      'type': 'api',
      'id': 'h',
      'name': 'H',
      'lang': 'en',
      'baseUrl': 'https://h.example',
      'apiUrl': 'https://api.h.example',
      'manga': {'url': 'slug', 'title': 'title', 'description': 'content'},
      'popular': {'path': '/query', 'items': 'posts'},
      'chapters': {'path': '/feed', 'items': 'data'},
      'pages': {'path': '/c', 'items': 'images', 'template': '{value}'},
    });
    final source = apiSource(
      cfg,
      client: MockClient((req) async {
        if (req.url.path == '/query') {
          return http.Response(
            jsonEncode({
              'posts': [
                {
                  'slug': 's1',
                  'title': 'T',
                  'content':
                      '<p>First line with <b>bold</b> &amp; entity.</p>'
                      '<p>Second line.</p>',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    final page = await source.popular(1);
    expect(
      page.items.single.description,
      'First line with bold & entity.\nSecond line.',
    );
  });

  test('plain/markdown descriptions pass through unchanged', () async {
    // The guard means a description with no HTML tags (e.g. plain markdown)
    // is left exactly as-is: no entity mangling, no trimming surprises.
    final source = _delta(_fakeApi());
    final page = await source.popular(1);
    expect(page.items.first.description, 'Description of First Manga');
  });
}
