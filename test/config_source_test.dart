import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';

const _popularHtml = '''
<html><body>
  <div class="grid">
    <div class="item">
      <a class="title" href="/manga/alpha">Alpha Adventure</a>
      <img src="/covers/alpha.jpg">
    </div>
    <div class="item">
      <a class="title" href="https://example.com/manga/beta">Beta Blast</a>
      <img src="//cdn.example.com/covers/beta.jpg">
    </div>
  </div>
  <a class="next" href="/popular?page=2">Next</a>
</body></html>
''';

const _searchHtml = '''
<html><body>
  <div class="item">
    <a class="title" href="/manga/gamma">Gamma Girl</a>
    <img src="/covers/gamma.jpg">
  </div>
</body></html>
''';

const _mangaHtml = '''
<html><body>
  <h1 class="manga-title">Alpha Adventure: Deluxe</h1>
  <span class="author">Some Mangaka</span>
  <p class="summary">A thrilling tale.</p>
  <div class="cover"><img class="cover-img" src="/covers/alpha-big.jpg"></div>
  <ul class="chapter-list">
    <li class="chapter"><a href="/manga/alpha/ch-3">Chapter 3</a></li>
    <li class="chapter"><a href="/manga/alpha/ch-2">Chapter 2</a></li>
    <li class="chapter"><a href="/manga/alpha/ch-1">Chapter 1</a></li>
  </ul>
</body></html>
''';

// No `img.cover-img` element at all: some sites genuinely have no cover on
// the details page itself, unlike alpha's own fixture above.
const _mangaHtmlNoCover = '''
<html><body>
  <h1 class="manga-title">Alpha Adventure: Deluxe</h1>
  <span class="author">Some Mangaka</span>
  <p class="summary">A thrilling tale.</p>
  <ul class="chapter-list">
    <li class="chapter"><a href="/manga/alpha/ch-1">Chapter 1</a></li>
  </ul>
</body></html>
''';

const _chapterHtml = '''
<html><body>
  <div class="reader">
    <img class="page" src="/pages/1.jpg">
    <img class="page" src="/pages/2.jpg">
    <img class="page" data-src="/pages/3.jpg">
  </div>
</body></html>
''';

// Madara-style lazy load: unloaded images keep a 1x1 placeholder gif in
// `src` (never empty) with the real URL in `data-src`. Only images that
// were already in the viewport at load time get a real `src`.
const _chapterHtmlPlaceholderGif = '''
<html><body>
  <div class="reader">
    <img class="page" src="/pages/1.jpg">
    <img class="page" src="data:image/gif;base64,R0lGODlhAQABAAAA" data-src="/pages/2.jpg">
  </div>
</body></html>
''';

// A different lazy-load shape: the placeholder is a real, non-data: themed
// asset URL (a loading spinner), repeated identically for every unloaded
// image rather than left empty or inlined. No eager-loaded images at all,
// unlike the gif-placeholder fixture above.
const _chapterHtmlPlaceholderAsset = '''
<html><body>
  <div class="reader">
    <img class="page" src="/theme/loading.svg" data-src="/pages/1.jpg">
    <img class="page" src="/theme/loading.svg" data-src="/pages/2.jpg">
    <img class="page" src="/theme/loading.svg" data-src="/pages/3.jpg">
  </div>
</body></html>
''';

SourceConfig _config() => SourceConfig.fromJson({
  'id': 'example',
  'name': 'Example',
  'lang': 'en',
  'baseUrl': 'https://example.com',
  'popular': {
    'path': '/popular?page={page}',
    'itemSelector': 'div.item',
    'titleSelector': 'a.title',
    'urlSelector': 'a.title',
    'coverSelector': 'img',
    'nextPageSelector': 'a.next',
  },
  'search': {
    'path': '/search?q={query}&page={page}',
    'itemSelector': 'div.item',
    'titleSelector': 'a.title',
    'urlSelector': 'a.title',
    'coverSelector': 'img',
  },
  'details': {
    'titleSelector': 'h1.manga-title',
    'authorSelector': 'span.author',
    'descriptionSelector': 'p.summary',
    'coverSelector': 'img.cover-img',
  },
  'chapters': {
    'itemSelector': 'li.chapter',
    'nameSelector': 'a',
    'urlSelector': 'a',
    'reversed': true,
  },
  'pages': {'imageSelector': 'div.reader img.page', 'imageAttr': 'src'},
});

http.Client _fakeServer() => MockClient((request) async {
  final path = '${request.url.path}?${request.url.query}'.replaceAll(
    RegExp(r'\?$'),
    '',
  );
  return switch (path) {
    '/popular?page=1' => http.Response(_popularHtml, 200),
    '/search?q=gamma+girl&page=1' => http.Response(_searchHtml, 200),
    '/manga/alpha' => http.Response(_mangaHtml, 200),
    '/manga/alpha/ch-1' => http.Response(_chapterHtml, 200),
    _ => http.Response('not found', 404),
  };
});

void main() {
  late Source source;

  setUp(() {
    source = htmlSource(_config(), client: _fakeServer());
  });

  test('requiresWebView mirrors the config onto the built source', () {
    // A capability marker a host application routes on: a `webview` source
    // cannot be served by a transport that builds requests ahead of time and
    // performs them elsewhere (an OS background downloader), because such a
    // transport can neither refresh a credential nor escalate to the browser.
    expect(source.requiresWebView, isFalse);

    final walled = htmlSource(
      SourceConfig.fromJson({..._config().toJson(), 'webview': true}),
      client: _fakeServer(),
    );
    expect(walled.requiresWebView, isTrue);
  });

  test('config survives a JSON round trip', () {
    final restored = SourceConfig.fromJson(_config().toJson());
    expect(restored.id, 'example');
    expect(restored.popular.nextPageSelector, 'a.next');
    expect(restored.chapters.reversed, true);
  });

  test('fetchPopular parses items and resolves relative URLs', () async {
    final page = await source.popular(1);
    expect(page.items.length, 2);
    expect(page.hasNextPage, true);

    expect(page.items[0].title, 'Alpha Adventure');
    expect(page.items[0].url, 'https://example.com/manga/alpha');
    expect(page.items[0].thumbnailUrl, 'https://example.com/covers/alpha.jpg');

    // Absolute and protocol-relative URLs pass through correctly.
    expect(page.items[1].url, 'https://example.com/manga/beta');
    expect(
      page.items[1].thumbnailUrl,
      'https://cdn.example.com/covers/beta.jpg',
    );
  });

  test('fetchPopular with an empty path fetches the site root, not a hostless '
      'URL', () async {
    // An empty `path` is a deliberately valid config (the listing lives at
    // the base URL itself, e.g. example.com's homepage) — distinct from
    // an unmatched selector's empty extraction, which should stay empty
    // rather than resolve to baseUrl.
    final rootConfig = SourceConfig.fromJson({
      ..._config().toJson(),
      'popular': {
        'itemSelector': 'div.item',
        'titleSelector': 'a.title',
        'urlSelector': 'a.title',
        'coverSelector': 'img',
      },
    });
    final rootClient = MockClient((request) async {
      return request.url.path.isEmpty
          ? http.Response(_popularHtml, 200)
          : http.Response('not found', 404);
    });
    final rootSource = htmlSource(rootConfig, client: rootClient);

    final page = await rootSource.popular(1);
    expect(page.items.length, 2);
  });

  test('fetchSearch substitutes the query placeholder', () async {
    final page = await source.search('gamma girl', 1);
    expect(page.items.single.title, 'Gamma Girl');
    expect(page.hasNextPage, false);
  });

  group('tag browsing', () {
    test('hasTagListing is false without a tag config', () {
      expect(source.hasTagListing, isFalse);
    });

    test('tagCapabilities is all-false without a tag config, or with one '
        'that sets neither tagParam nor tagExcludeParam', () {
      expect(source.tagCapabilities.multiple, isFalse);
      expect(source.tagCapabilities.exclusion, isFalse);

      final singleTagSource = htmlSource(
        SourceConfig.fromJson({
          ..._config().toJson(),
          'tag': {
            'path': '/tags/{query}?page={page}',
            'itemSelector': 'div.item',
            'titleSelector': 'a.title',
            'urlSelector': 'a.title',
          },
        }),
      );
      expect(singleTagSource.tagCapabilities.multiple, isFalse);
      expect(singleTagSource.tagCapabilities.exclusion, isFalse);
    });

    test('tag config survives a JSON round trip', () {
      final json = _config().toJson();
      json['tag'] = {
        'path': '/tags/{query}?page={page}',
        'itemSelector': 'div.item',
        'titleSelector': 'a.title',
        'urlSelector': 'a.title',
        'tagParam': 'tag',
        'tagExcludeParam': 'exclude',
        'tagJoin': ',',
      };
      final restored = SourceConfig.fromJson(json);
      expect(restored.tag?.path, '/tags/{query}?page={page}');
      expect(restored.tag?.tagParam, 'tag');
      expect(restored.tag?.tagExcludeParam, 'exclude');
      expect(restored.tag?.tagJoin, ',');
      expect(SourceConfig.fromJson(restored.toJson()).tag?.tagParam, 'tag');
    });

    test('tag {query} is path-segment escaped (%20), not query-string '
        '(+) — the same tag text search would mangle differently', () async {
      final requested = <String>[];
      final tagSource = htmlSource(
        SourceConfig.fromJson({
          ..._config().toJson(),
          'tag': {
            'path': '/tags/{query}?page={page}',
            'itemSelector': 'div.item',
            'titleSelector': 'a.title',
            'urlSelector': 'a.title',
            'coverSelector': 'img',
          },
        }),
        client: MockClient((request) async {
          requested.add(request.url.toString());
          return http.Response(_searchHtml, 200);
        }),
      );

      expect(tagSource.hasTagListing, isTrue);
      // A space *and* an unescaped-in-Dart paren, both real-world tag
      // shapes confirmed live (e.g. `Shukan Taishu (週刊大衆)`): a naive
      // query-string escape (`Uri.encodeQueryComponent`) would send the
      // space as `+`, wrong in a URL path segment.
      await tagSource.tag({'Sci-Fi (Hard)'}, 1);

      expect(
        requested.single,
        'https://example.com/tags/Sci-Fi%20(Hard)?page=1',
      );
    });

    // Webtoons' genre labels ("Sci-fi", "Superhero") don't derive their
    // browse slug ("sf", "super-hero") from the display text by any rule:
    // queryMap is the exact-match escape hatch, checked before queryReplace.
    test('tag queryMap exact-matches (case-insensitively) before '
        'queryReplace, and unmatched queries still fall through', () async {
      final requested = <String>[];
      final tagSource = htmlSource(
        SourceConfig.fromJson({
          ..._config().toJson(),
          'tag': {
            'path': '/genres/{query}',
            'queryMap': {'Sci-Fi': 'sf', 'Superhero': 'super-hero'},
            'queryReplace': {'pattern': ' ', 'replace': '-'},
            'itemSelector': 'div.item',
            'titleSelector': 'a.title',
            'urlSelector': 'a.title',
            'coverSelector': 'img',
          },
        }),
        client: MockClient((request) async {
          requested.add(request.url.toString());
          return http.Response(_searchHtml, 200);
        }),
      );

      // A queryMap key, matched case-insensitively against the tapped value.
      await tagSource.tag({'sci-fi'}, 1);
      // Not a queryMap key: falls through to queryReplace's space->hyphen.
      await tagSource.tag({'Slice of Life'}, 1);

      expect(requested, [
        'https://example.com/genres/sf',
        'https://example.com/genres/Slice-of-Life',
      ]);
    });

    // No real source exercises multi-tag/exclusion yet (a real source's own
    // `/tags/{name}`-shaped endpoint only ever takes one): this is a
    // synthetic config proving the *mechanism* works, not a live-verified
    // site.
    group('multi-tag + exclusion (synthetic — not live-verified)', () {
      SourceConfig multiTagConfig() => SourceConfig.fromJson({
        ..._config().toJson(),
        'tag': {
          'path': '/browse?page={page}',
          'itemSelector': 'div.item',
          'titleSelector': 'a.title',
          'urlSelector': 'a.title',
          'tagParam': 'tag',
          'tagExcludeParam': 'exclude',
        },
      });

      test('tagCapabilities reflects both tagParam and tagExcludeParam', () {
        final multiTagSource = htmlSource(multiTagConfig());
        expect(multiTagSource.tagCapabilities.multiple, isTrue);
        expect(multiTagSource.tagCapabilities.exclusion, isTrue);
      });

      test('included values become repeated tagParam params, excluded '
          'become tagExcludeParam', () async {
        final requested = <String>[];
        final multiTagSource = htmlSource(
          multiTagConfig(),
          client: MockClient((request) async {
            requested.add(request.url.toString());
            return http.Response(_searchHtml, 200);
          }),
        );

        await multiTagSource.tag({'horror', 'romance'}, 1, excluded: {'ecchi'});

        final uri = Uri.parse(requested.single);
        expect(uri.path, '/browse');
        expect(uri.queryParametersAll['tag']?.toSet(), {'horror', 'romance'});
        expect(uri.queryParametersAll['exclude'], ['ecchi']);
      });
    });
  });

  group('filters', () {
    SourceConfig filteredConfig() {
      final json = _config().toJson();
      json['filters'] = [
        {
          'id': 'genres',
          'name': 'Genres',
          'param': 'genre',
          'excludeParam': 'exclude',
          'options': [
            {'value': 'horror', 'label': 'Horror'},
            {'value': 'action', 'label': 'Action'},
            {'value': 'romance', 'label': 'Romance'},
          ],
        },
        {
          'id': 'status',
          'name': 'Status',
          'param': 'status',
          'join': ',',
          'options': [
            {'value': 'ongoing', 'label': 'Ongoing'},
            {'value': 'done', 'label': 'Completed'},
          ],
        },
      ];
      return SourceConfig.fromJson(json);
    }

    test('survive a JSON round trip', () {
      final restored = SourceConfig.fromJson(filteredConfig().toJson());
      expect(restored.filters, hasLength(2));
      expect(restored.filters.first.excludeParam, 'exclude');
      expect(restored.filters.last.join, ',');
      expect(restored.filters.first.options.first.label, 'Horror');
    });

    test('map to filter groups, exclusion only where configured', () async {
      final source = htmlSource(filteredConfig(), client: _fakeServer());
      expect(source.hasFilters, isTrue);

      final groups = await source.filters();
      expect(groups.map((g) => g.name), ['Genres', 'Status']);
      expect(groups.first.supportsExclusion, isTrue);
      expect(groups.last.supportsExclusion, isFalse);
    });

    test(
      'selections become query parameters per param and join style',
      () async {
        final requests = <Uri>[];
        final source = htmlSource(
          filteredConfig(),
          client: MockClient((request) async {
            requests.add(request.url);
            return http.Response(_searchHtml, 200);
          }),
        );
        final selection = FilterSelection()
          ..set('genres', 'horror', FilterState.included)
          ..set('genres', 'action', FilterState.included)
          ..set('genres', 'romance', FilterState.excluded)
          ..set('status', 'ongoing', FilterState.included)
          ..set('status', 'done', FilterState.included);

        await source.search('gamma', 1, filters: selection);

        final query = requests.single.queryParametersAll;
        expect(query['q'], ['gamma']);
        expect(query['page'], ['1']);
        expect(query['genre'], ['horror', 'action']); // repeated parameter
        expect(query['exclude'], ['romance']);
        expect(query['status'], ['ongoing,done']); // joined parameter
      },
    );

    test('optionsFrom scrapes the option list, once per session', () async {
      final json = filteredConfig().toJson();
      (json['filters'] as List<dynamic>)[0] = {
        'id': 'genres',
        'name': 'Genres',
        'param': 'genre',
        'optionsFrom': {
          'path': '/advanced-search',
          'itemSelector': 'select.genres option',
        },
      };
      var fetches = 0;
      final source = htmlSource(
        SourceConfig.fromJson(json),
        client: MockClient((request) async {
          if (request.url.path == '/advanced-search') {
            fetches++;
            return http.Response(
              '<select class="genres">'
              '<option value="horror">Horror</option>'
              '<option value="act">Action</option>'
              '</select>',
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final groups = await source.filters();
      final genres = groups.first;
      expect(genres.options.map((o) => '${o.id}:${o.label}'), [
        'act:Action',
        'horror:Horror',
      ]);

      await source.filters();
      expect(fetches, 1);
    });

    test('failed discovery falls back to the static options', () async {
      final json = filteredConfig().toJson();
      final filter =
          ((json['filters'] as List<dynamic>)[0] as Map<String, dynamic>);
      filter['optionsFrom'] = {'path': '/missing', 'itemSelector': 'option'};
      final source = htmlSource(
        SourceConfig.fromJson(json),
        client: MockClient((request) async => http.Response('nope', 404)),
      );

      final groups = await source.filters();
      expect(groups.first.options.map((o) => o.label), [
        'Horror',
        'Action',
        'Romance',
      ]);
    });

    test('an empty selection leaves the search URL untouched', () async {
      final requests = <Uri>[];
      final source = htmlSource(
        filteredConfig(),
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(_searchHtml, 200);
        }),
      );
      await source.search('gamma', 1, filters: FilterSelection());
      expect(requests.single.queryParametersAll.containsKey('genre'), isFalse);
    });
  });

  test('fetchDetails fills title, author, description and cover', () async {
    final manga = await source.details(
      const MangaRef('https://example.com/manga/alpha'),
    );
    expect(manga.title, 'Alpha Adventure: Deluxe');
    expect(manga.author, 'Some Mangaka');
    expect(manga.description, 'A thrilling tale.');
    expect(manga.thumbnailUrl, 'https://example.com/covers/alpha-big.jpg');
  });

  test('fetchDetails falls back to knownThumbnailUrl when the details page has '
      'no cover of its own', () async {
    final noCoverSource = htmlSource(
      _config(),
      client: MockClient((request) async {
        final path = request.url.path;
        return path == '/manga/alpha'
            ? http.Response(_mangaHtmlNoCover, 200)
            : http.Response('not found', 404);
      }),
    );

    final manga = await noCoverSource.details(
      const MangaRef(
        'https://example.com/manga/alpha',
        knownThumbnailUrl: 'https://example.com/covers/from-listing.jpg',
      ),
    );

    expect(manga.thumbnailUrl, 'https://example.com/covers/from-listing.jpg');
  });

  test('fetchDetails.genreSelector collects an unlabeled tag list — no '
      '"Tags:" prefix needed, unlike rows', () async {
    // A real source's shape (confirmed live): two bare `<a href="/tags/…">`
    // links, nothing marking them as a labeled row.
    const html = '''
<html><body>
  <h1 class="manga-title">Some Album</h1>
  <div class="tags">
    <a href="/tags/model">Aika Sawaguchi</a>
    <a href="/tags/type">Photo Book</a>
  </div>
</body></html>
''';
    final genreSource = htmlSource(
      SourceConfig.fromJson({
        'id': 'example',
        'name': 'Example',
        'lang': 'en',
        'baseUrl': 'https://example.com',
        'popular': {'itemSelector': 'div.none'},
        'search': {'itemSelector': 'div.none'},
        'details': {
          'titleSelector': 'h1.manga-title',
          'genreSelector': 'div.tags a',
        },
        'chapters': {'itemSelector': 'li.none'},
        'pages': {'imageSelector': 'img.none'},
      }),
      client: MockClient((request) async => http.Response(html, 200)),
    );

    final manga = await genreSource.details(
      const MangaRef('https://example.com/albums/x'),
    );
    expect(manga.genres, ['Aika Sawaguchi', 'Photo Book']);
  });

  test(
    'fetchDetails.unlistedChaptersSelector parses the first run of '
    'digits out of surrounding prose; no selector configured means 0',
    () async {
      // Webtoons' real shape: a promotional banner mentioning a count, not a
      // clean standalone number. The selector shouldn't need to isolate it.
      const html = '''
<html><body>
  <h1 class="manga-title">Some Series</h1>
  <div class="detail_install_app">
    <strong>Read <em>12</em> new episodes only on the app!</strong>
  </div>
</body></html>
''';
      final unlistedSource = htmlSource(
        SourceConfig.fromJson({
          'id': 'example',
          'name': 'Example',
          'lang': 'en',
          'baseUrl': 'https://example.com',
          'popular': {'itemSelector': 'div.none'},
          'search': {'itemSelector': 'div.none'},
          'details': {
            'titleSelector': 'h1.manga-title',
            'unlistedChaptersSelector': 'div.detail_install_app strong em',
          },
          'chapters': {'itemSelector': 'li.none'},
          'pages': {'imageSelector': 'img.none'},
        }),
        client: MockClient((request) async => http.Response(html, 200)),
      );

      final manga = await unlistedSource.details(
        const MangaRef('https://example.com/manga/x'),
      );
      expect(manga.unlistedChapterCount, 12);

      // The shared fixture config sets no unlistedChaptersSelector at all.
      final defaultManga = await source.details(
        const MangaRef('https://example.com/manga/alpha'),
      );
      expect(defaultManga.unlistedChapterCount, 0);
    },
  );

  test('fetchDetails.bannerSelector captures a hero image distinct from '
      'cover; absent selector leaves bannerUrl empty', () async {
    const html = '''
<html><head>
  <meta property="og:image" content="https://example.com/poster.jpg">
</head><body>
  <h1 class="manga-title">Some Series</h1>
  <div class="detail_header"><div class="thmb">
    <img src="https://cdn.example.com/banner-art.png" alt="wide character banner">
  </div></div>
</body></html>
''';
    final bannerSource = htmlSource(
      SourceConfig.fromJson({
        'id': 'example',
        'name': 'Example',
        'lang': 'en',
        'baseUrl': 'https://example.com',
        'popular': {'itemSelector': 'div.none'},
        'search': {'itemSelector': 'div.none'},
        'details': {
          'titleSelector': 'h1.manga-title',
          'coverSelector': 'meta[property="og:image"]',
          'coverAttr': 'content',
          'bannerSelector': 'div.thmb img',
        },
        'chapters': {'itemSelector': 'li.none'},
        'pages': {'imageSelector': 'img.none'},
      }),
      client: MockClient((request) async => http.Response(html, 200)),
    );

    final manga = await bannerSource.details(
      const MangaRef('https://example.com/manga/x'),
    );
    expect(manga.thumbnailUrl, 'https://example.com/poster.jpg');
    expect(manga.bannerUrl, 'https://cdn.example.com/banner-art.png');

    // The shared fixture config sets no bannerSelector at all.
    final defaultManga = await source.details(
      const MangaRef('https://example.com/manga/alpha'),
    );
    expect(defaultManga.bannerUrl, '');
  });

  test(
    'fetchDetails.background extracts a CSS background:url(...) out of '
    "an inline style attribute — no dedicated engine support, just attr: "
    "'style' plus a chain rewrite pulling the URL out of the raw value",
    () async {
      // Webtoons' real shape: a tiled backdrop, not a plain <img>.
      const html = '''
<html><body>
  <h1 class="manga-title">Some Series</h1>
  <div class="detail_bg" style="background:url('https://cdn.example.com/mood.jpg') repeat-x"></div>
</body></html>
''';
      final backgroundSource = htmlSource(
        SourceConfig.fromJson({
          'id': 'example',
          'name': 'Example',
          'lang': 'en',
          'baseUrl': 'https://example.com',
          'popular': {'itemSelector': 'div.none'},
          'search': {'itemSelector': 'div.none'},
          'details': {
            'titleSelector': 'h1.manga-title',
            'background': [
              {
                'selector': 'div.detail_bg',
                'attr': 'style',
                'replace': {
                  'pattern': r"^.*url\('([^']+)'\).*$",
                  'replace': r'$1',
                },
              },
            ],
          },
          'chapters': {'itemSelector': 'li.none'},
          'pages': {'imageSelector': 'img.none'},
        }),
        client: MockClient((request) async => http.Response(html, 200)),
      );

      final manga = await backgroundSource.details(
        const MangaRef('https://example.com/manga/x'),
      );
      expect(manga.backgroundUrl, 'https://cdn.example.com/mood.jpg');

      // The shared fixture config sets no background at all.
      final defaultManga = await source.details(
        const MangaRef('https://example.com/manga/alpha'),
      );
      expect(defaultManga.backgroundUrl, '');
    },
  );

  test('fetchChapters returns reading order (oldest first)', () async {
    final chapters = await source.chapters(
      const MangaRef('https://example.com/manga/alpha'),
    );
    expect(chapters.map((c) => c.name).toList(), [
      'Chapter 1',
      'Chapter 2',
      'Chapter 3',
    ]);
    expect(chapters.first.url, 'https://example.com/manga/alpha/ch-1');
  });

  test('fetchPages collects image URLs including data-src fallback', () async {
    final pages = await source.pages(
      const ChapterRef('https://example.com/manga/alpha/ch-1'),
    );
    expect(pages.map((p) => p.url.toString()), [
      'https://example.com/pages/1.jpg',
      'https://example.com/pages/2.jpg',
      'https://example.com/pages/3.jpg',
    ]);
  });

  test(
    'fetchPages prefers data-src over a data: URI placeholder in src',
    () async {
      final lazySource = htmlSource(
        _config(),
        client: MockClient((request) async {
          final path = request.url.path;
          return path == '/manga/alpha/ch-1'
              ? http.Response(_chapterHtmlPlaceholderGif, 200)
              : http.Response('not found', 404);
        }),
      );

      final pages = await lazySource.pages(
        const ChapterRef('https://example.com/manga/alpha/ch-1'),
      );

      expect(pages.map((p) => p.url.toString()), [
        'https://example.com/pages/1.jpg',
        'https://example.com/pages/2.jpg',
      ]);
    },
  );

  test('fetchPages prefers data-src when src repeats the same non-data: '
      'placeholder across every page', () async {
    final lazySource = htmlSource(
      _config(),
      client: MockClient((request) async {
        final path = request.url.path;
        return path == '/manga/alpha/ch-1'
            ? http.Response(_chapterHtmlPlaceholderAsset, 200)
            : http.Response('not found', 404);
      }),
    );

    final pages = await lazySource.pages(
      const ChapterRef('https://example.com/manga/alpha/ch-1'),
    );

    expect(pages.map((p) => p.url.toString()), [
      'https://example.com/pages/1.jpg',
      'https://example.com/pages/2.jpg',
      'https://example.com/pages/3.jpg',
    ]);
  });

  test('HTTP errors surface as exceptions', () async {
    expect(
      () => source.pages(const ChapterRef('https://example.com/missing')),
      throwsA(isA<http.ClientException>()),
    );
  });

  group('a real-world-shaped HTML config (cover chains, offset pagination, '
      'label rows)', () {
    late Source wc;

    setUp(() {
      wc = htmlSource(_wcConfig(), client: _wcFakeServer());
    });

    test('new fields survive a JSON round trip', () {
      final restored = SourceConfig.fromJson(_wcConfig().toJson());
      expect(restored.rateLimit!.requests, 100);
      expect(restored.rateLimit!.perMs, 1000);
      expect(restored.popular.pageSize, 2);
      expect(restored.popular.cover!.length, 2);
      expect(restored.popular.cover!.first.rewrite!.find, 'small');
      expect(restored.search!.queryReplace!.pattern, '[!#:(),-]');
      expect(restored.details.rows!.fields['genres']!.labels, ['Tag', 'Type']);
      expect(restored.details.statusMap['complete'], 'completed');
      expect(restored.chapters.request!.replace, r'$1/full-chapter-list');
      expect(restored.pages.request!.suffix, contains('/images'));
    });

    test('popular substitutes {offset} and walks the cover chain', () async {
      final page1 = await wc.popular(1);
      expect(page1.items.single.title, 'Iron Bloom Saga');
      expect(page1.items.single.url, 'https://wc.example/series/abc123/solo');
      // srcset value with the small->normal rewrite applied.
      expect(
        page1.items.single.thumbnailUrl,
        'https://wc.example/covers/abc-normal.webp',
      );
      expect(page1.hasNextPage, true);

      // Page 2 maps to offset=2 and its fragment has no next-page button.
      final page2 = await wc.popular(2);
      expect(page2.hasNextPage, false);
    });

    test('search sanitizes the query before substitution', () async {
      final page = await wc.search('naruto: shippuden!', 1);
      expect(page.items.single.title, 'Iron Bloom Saga');
    });

    test('details fills fields from label rows', () async {
      final manga = await wc.details(
        const MangaRef('https://wc.example/series/abc123/solo'),
      );
      expect(manga.title, 'Iron Bloom Saga');
      expect(manga.author, 'ChuGong, Disciple');
      expect(manga.status, PublicationStatus.completed);
      // Type and Tag rows both feed genres, in document order.
      expect(manga.genres, ['Manhwa', 'Action', 'Fantasy']);
      expect(manga.description, 'Hunters rise.');
      expect(manga.thumbnailUrl, 'https://wc.example/covers/solo-normal.webp');
    });

    test('chapters fetch the transformed URL in reading order', () async {
      // The fake server only answers /series/abc123/full-chapter-list, so
      // these chapters prove the request transform was applied.
      final chapters = await wc.chapters(
        const MangaRef('https://wc.example/series/abc123/solo'),
      );
      expect(chapters.map((c) => c.name).toList(), ['Chapter 1', 'Chapter 2']);
      expect(chapters.first.url, 'https://wc.example/chapters/ch1');
    });

    test('pages append the request suffix', () async {
      final pages = await wc.pages(
        const ChapterRef('https://wc.example/chapters/ch1'),
      );
      expect(pages.map((p) => p.url.toString()), [
        'https://wc.example/img/p1.png',
        'https://wc.example/img/p2.png',
      ]);
    });
  });

  group('POST + script-blob (Madara / MangaThemesia shapes)', () {
    test('POST and script fields survive a JSON round trip', () {
      final json = {
        'id': 'm',
        'name': 'M',
        'lang': 'en',
        'baseUrl': 'https://m.example',
        'popular': {
          'path': '/wp-admin/admin-ajax.php',
          'method': 'POST',
          'body': 'action=madara_load_more&page={page}',
          'headers': {'X-Requested-With': 'XMLHttpRequest'},
          'itemSelector': 'div.item',
        },
        'chapters': {
          'request': {'suffix': 'ajax/chapters/', 'method': 'POST'},
          'itemSelector': 'li.wp-manga-chapter',
        },
        'pages': {
          'script': {
            'pattern': r'ts_reader.run\((.*?)\);',
            'itemsPath': 'sources[0].images',
          },
        },
      };
      final restored = SourceConfig.fromJson(
        SourceConfig.fromJson(json).toJson(),
      );
      expect(restored.popular.method, 'POST');
      expect(restored.popular.body, 'action=madara_load_more&page={page}');
      expect(restored.popular.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(restored.chapters.request!.isPost, isTrue);
      expect(restored.pages.script!.itemsPath, 'sources[0].images');
    });

    test('chapters POST to a derived ajax endpoint', () async {
      final captured = <http.Request>[];
      final cfg = SourceConfig.fromJson({
        'id': 'm',
        'name': 'M',
        'lang': 'en',
        'baseUrl': 'https://m.example',
        'popular': {'path': '/?page={page}', 'itemSelector': 'div.item'},
        'chapters': {
          'request': {'suffix': 'ajax/chapters/', 'method': 'POST'},
          'itemSelector': 'li.wp-manga-chapter',
          'nameSelector': 'a',
          'urlSelector': 'a',
        },
        'pages': {'imageSelector': 'div.reading-content img'},
      });
      final source = htmlSource(
        cfg,
        client: MockClient((req) async {
          captured.add(req);
          if (req.method == 'POST' &&
              req.url.path == '/manga/x/ajax/chapters/') {
            return http.Response(
              '<li class="wp-manga-chapter">'
              '<a href="/manga/x/ch-1">Chapter 1</a></li>',
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final chapters = await source.chapters(
        const MangaRef('https://m.example/manga/x/'),
      );
      expect(chapters.single.name, 'Chapter 1');
      expect(captured.single.method, 'POST');
    });

    test('chapters two-phase: lift an id, then POST it (admin-ajax)', () async {
      final cfg = SourceConfig.fromJson({
        'id': 'm',
        'name': 'M',
        'lang': 'en',
        'baseUrl': 'https://m.example',
        'popular': {'path': '/?page={page}', 'itemSelector': 'div.item'},
        'chapters': {
          'request': {
            'url': '/wp-admin/admin-ajax.php',
            'method': 'POST',
            'idSelector': '#manga-chapters-holder',
            'idAttr': 'data-id',
            'body': 'action=manga_get_chapters&manga={id}',
          },
          'itemSelector': 'li.wp-manga-chapter',
          'nameSelector': 'a',
          'urlSelector': 'a',
        },
        'pages': {'imageSelector': 'img'},
      });
      String? postBody;
      Uri? postUrl;
      final source = htmlSource(
        cfg,
        client: MockClient((req) async {
          if (req.method == 'GET' && req.url.path == '/manga/x/') {
            return http.Response(
              '<div id="manga-chapters-holder" data-id="760"></div>',
              200,
            );
          }
          if (req.method == 'POST') {
            postUrl = req.url;
            postBody = req.body;
            return http.Response(
              '<li class="wp-manga-chapter">'
              '<a href="/manga/x/ch-1">Chapter 1</a></li>',
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final chapters = await source.chapters(
        const MangaRef('https://m.example/manga/x/'),
      );
      expect(chapters.single.name, 'Chapter 1');
      expect(postUrl!.path, '/wp-admin/admin-ajax.php');
      expect(postBody, 'action=manga_get_chapters&manga=760');
    });

    test('popular POSTs a load-more body with substitutions', () async {
      String? postBody;
      final cfg = SourceConfig.fromJson({
        'id': 'm',
        'name': 'M',
        'lang': 'en',
        'baseUrl': 'https://m.example',
        'popular': {
          'path': '/wp-admin/admin-ajax.php',
          'method': 'POST',
          'body': 'action=madara_load_more&page={page}',
          'itemSelector': 'div.item',
          'titleSelector': 'a',
          'urlSelector': 'a',
        },
        'chapters': {'itemSelector': 'li'},
        'pages': {'imageSelector': 'img'},
      });
      final source = htmlSource(
        cfg,
        client: MockClient((req) async {
          postBody = req.body;
          return http.Response(
            '<div class="item"><a href="/manga/a">A</a></div>',
            200,
          );
        }),
      );
      final page = await source.popular(2);
      expect(page.items.single.title, 'A');
      expect(postBody, 'action=madara_load_more&page=2');
    });

    test('pages come from a ts_reader.run script blob', () async {
      final cfg = SourceConfig.fromJson({
        'id': 't',
        'name': 'T',
        'lang': 'en',
        'baseUrl': 'https://t.example',
        'popular': {'path': '/', 'itemSelector': 'div'},
        'chapters': {'itemSelector': 'li'},
        'pages': {
          'script': {
            'pattern': r'ts_reader.run\((.*?)\);',
            'itemsPath': 'sources[0].images',
          },
        },
      });
      final source = htmlSource(
        cfg,
        client: MockClient(
          (req) async => http.Response(
            '<html><body><script>ts_reader.run('
            '{"sources":[{"source":"Main","images":'
            '["/img/1.jpg","https://cdn.example/2.jpg"]}]});'
            '</script></body></html>',
            200,
          ),
        ),
      );
      final pages = await source.pages(
        const ChapterRef('https://t.example/ch/1'),
      );
      expect(pages.map((p) => p.url.toString()), [
        'https://t.example/img/1.jpg',
        'https://cdn.example/2.jpg',
      ]);
    });

    // A MangaThemesia config with both a `script` blob and an `imageSelector`
    // fallback: when the site drops `ts_reader.run`, the selector must run
    // instead of returning empty (the fallback the config declares).
    SourceConfig scriptWithFallback() => SourceConfig.fromJson({
      'id': 't',
      'name': 'T',
      'lang': 'en',
      'baseUrl': 'https://t.example',
      'popular': {'path': '/', 'itemSelector': 'div'},
      'chapters': {'itemSelector': 'li'},
      'pages': {
        'script': {
          'pattern': r'ts_reader.run\((.*?)\);',
          'itemsPath': 'sources[0].images',
        },
        'imageSelector': 'div#readerarea img',
      },
    });

    test(
      'pages fall back to imageSelector when the script is absent',
      () async {
        final source = htmlSource(
          scriptWithFallback(),
          client: MockClient(
            (req) async => http.Response(
              '<html><body><div id="readerarea">'
              '<img src="/img/1.jpg" loading="lazy" />'
              '<img src="https://cdn.example/2.jpg" /></div></body></html>',
              200,
            ),
          ),
        );
        final pages = await source.pages(
          const ChapterRef('https://t.example/ch/1'),
        );
        expect(pages.map((p) => p.url.toString()), [
          'https://t.example/img/1.jpg',
          'https://cdn.example/2.jpg',
        ]);
      },
    );

    test('the script wins when present, even with a selector fallback', () async {
      final source = htmlSource(
        scriptWithFallback(),
        client: MockClient(
          (req) async => http.Response(
            '<html><body><script>ts_reader.run('
            '{"sources":[{"images":["/a.jpg"]}]});</script>'
            // A stray <img> in #readerarea must be ignored while the script matches.
            '<div id="readerarea"><img src="/decoy.jpg" /></div>'
            '</body></html>',
            200,
          ),
        ),
      );
      final pages = await source.pages(
        const ChapterRef('https://t.example/ch/1'),
      );
      expect(pages.map((p) => p.url.toString()), ['https://t.example/a.jpg']);
    });

    test('pages read a ts_reader blob hidden in a base64 data: script', () async {
      // The WP "mangareader" theme ships ts_reader.run(…) inside a
      // `data:text/javascript;base64,…` <script>, so the raw HTML has no inline
      // match: the engine must decode the data script first.
      final blob = base64.encode(
        utf8.encode(
          'ts_reader.run({"sources":[{"images":'
          '["/img/1.jpg","https://cdn.example/2.jpg"]}]});',
        ),
      );
      final cfg = SourceConfig.fromJson({
        'id': 't',
        'name': 'T',
        'lang': 'en',
        'baseUrl': 'https://t.example',
        'popular': {'path': '/', 'itemSelector': 'div'},
        'chapters': {'itemSelector': 'li'},
        'pages': {
          'script': {
            'pattern': r'ts_reader.run\((.*?)\);',
            'itemsPath': 'sources[0].images',
          },
        },
      });
      final source = htmlSource(
        cfg,
        client: MockClient(
          (req) async => http.Response(
            '<html><body>'
            '<script src="data:text/javascript;base64,$blob"></script>'
            '</body></html>',
            200,
          ),
        ),
      );
      final pages = await source.pages(
        const ChapterRef('https://t.example/ch/1'),
      );
      expect(pages.map((p) => p.url.toString()), [
        'https://t.example/img/1.jpg',
        'https://cdn.example/2.jpg',
      ]);
    });
  });

  group('explicit steps', () {
    SourceConfig stepsConfig() => SourceConfig.fromJson({
      'id': 's',
      'name': 'S',
      'lang': 'en',
      'baseUrl': 'https://s.example',
      'popular': {'path': '/p', 'itemSelector': 'div.item'},
      'chapters': {'itemSelector': 'li'},
      // Pages need a cross-format hop the sugar fields can't express:
      // fetch the chapter page, lift a reading id, then read JSON from ajax.
      'pages': {
        'steps': [
          {
            'request': {'url': '{chapterUrl}'},
            'parse': 'html',
            'capture': {
              'id': {'selector': '#wrapper', 'attr': 'data-id'},
            },
          },
          {
            'request': {'url': '{baseUrl}/ajax/{id}'},
            'parse': 'json',
            'yield': {
              'list': {'path': 'images'},
              'value': {'template': '{url}'},
            },
          },
        ],
      },
    });

    test('a steps: block survives a JSON round trip', () {
      final restored = SourceConfig.fromJson(stepsConfig().toJson());
      expect(restored.pages.steps, isNotNull);
      expect(restored.pages.steps!.steps, hasLength(2));
      // Lossless: re-serializing the restored config matches the first.
      expect(restored.toJson(), stepsConfig().toJson());
    });

    test('the engine runs pages steps end to end (HTML → id → JSON)', () async {
      final source = htmlSource(
        stepsConfig(),
        client: MockClient((req) async {
          if (req.url.path == '/series/x') {
            return http.Response('<div id="wrapper" data-id="55">r</div>', 200);
          }
          if (req.url.path == '/ajax/55') {
            return http.Response(
              '{"images":[{"url":"https://cdn/1.webp"}]}',
              200,
            );
          }
          return http.Response('not found: ${req.url}', 404);
        }),
      );
      final pages = await source.pages(
        const ChapterRef('https://s.example/series/x'),
      );
      expect(pages.map((p) => p.url.toString()), ['https://cdn/1.webp']);
    });

    test('a JSON-feed listing paginates from a total count (meta)', () async {
      // The Blogger-feed shape: records come from JSON, has-next compares the
      // page window against feed total (openSearch$totalResults).
      final cfg = SourceConfig.fromJson({
        'id': 'z',
        'name': 'Z',
        'lang': 'en',
        'baseUrl': 'https://z.example',
        'popular': {
          'pageSize': 2,
          'steps': [
            {
              'request': {
                'url': '{baseUrl}/feeds?max-results=2&start-index={offset}',
              },
              'parse': 'json',
              'yield': {
                'list': {'path': 'feed.entry'},
                'fields': {
                  'url': {'path': r'link[rel=alternate].href'},
                  'title': {'path': r'title.$t'},
                },
                'meta': {
                  'total': {'path': r'feed.openSearch$totalResults.$t'},
                },
              },
            },
          ],
        },
        'chapters': {'itemSelector': 'li'},
        'pages': {'imageSelector': 'img'},
      });
      final source = htmlSource(
        cfg,
        client: MockClient(
          (req) async => http.Response(
            r'{"feed":{"openSearch$totalResults":{"$t":"3"},"entry":['
            r'{"title":{"$t":"A"},"link":[{"rel":"alternate","href":"/a"}]},'
            r'{"title":{"$t":"B"},"link":[{"rel":"alternate","href":"/b"}]}'
            r']}}',
            200,
          ),
        ),
      );
      final p1 = await source.popular(1);
      expect(p1.items.map((m) => m.title), ['A', 'B']);
      expect(p1.items.first.url, 'https://z.example/a');
      expect(p1.hasNextPage, isTrue); // 1*2 = 2 < 3
      final p2 = await source.popular(2);
      expect(p2.hasNextPage, isFalse); // 2*2 = 4 >= 3
    });
  });

  group('locked chapters (coin/premium selector)', () {
    // Mirrors a real "WP Manga Coin" Madara plugin's markup (confirmed live
    // on a real source): a lock icon inside the chapter link when it's
    // gated behind payment, absent when free. lockedSelector is a presence
    // check (Locator.exists), not a value extraction: an icon element like
    // this has no text/attr content to read.
    SourceConfig config() => SourceConfig.fromJson({
      'id': 'coinsite',
      'name': 'Coin Site',
      'lang': 'en',
      'baseUrl': 'https://coin.example',
      'popular': {'itemSelector': 'div'},
      'chapters': {
        'itemSelector': 'li',
        'nameSelector': 'a',
        'urlSelector': 'a',
        'urlAttr': 'href',
        'lockedSelector': 'i.fa-lock',
        'reversed': false,
      },
      'pages': {'imageSelector': 'img'},
    });

    test(
      'flags chapters whose lock icon is present, leaves free ones alone',
      () async {
        final client = MockClient(
          (request) async => http.Response('''
          <ul>
            <li><a href="/ch/1">Chapter 1</a></li>
            <li><a href="/ch/2">Chapter 2 <i class="fa-lock"></i></a></li>
            <li><a href="/ch/3">Chapter 3</a></li>
          </ul>
        ''', 200),
        );
        final source = htmlSource(config(), client: client);
        final chapters = await source.chapters(
          const MangaRef('https://coin.example/manga/x'),
        );
        expect(chapters.map((c) => c.locked).toList(), [false, true, false]);
      },
    );

    test('lockedSelector survives a JSON round trip', () {
      final restored = SourceConfig.fromJson(config().toJson());
      expect(restored.chapters.lockedSelector, 'i.fa-lock');
    });

    test('omitting lockedSelector leaves every chapter unlocked', () async {
      final noLockConfig = SourceConfig.fromJson({
        'id': 'freesite',
        'name': 'Free Site',
        'lang': 'en',
        'baseUrl': 'https://free.example',
        'popular': {'itemSelector': 'div'},
        'chapters': {
          'itemSelector': 'li',
          'nameSelector': 'a',
          'urlSelector': 'a',
          'urlAttr': 'href',
          'reversed': false,
        },
        'pages': {'imageSelector': 'img'},
      });
      expect(noLockConfig.chapters.lockedSelector, isEmpty);
      final client = MockClient(
        (request) async => http.Response('''
          <ul><li><a href="/ch/1">Chapter 1 <i class="fa-lock"></i></a></li></ul>
        ''', 200),
      );
      final source = htmlSource(noLockConfig, client: client);
      final chapters = await source.chapters(
        const MangaRef('https://free.example/manga/x'),
      );
      // No lockedSelector configured means the source has no such concept:
      // a stray lock-icon-shaped element in the markup isn't misread as one.
      expect(chapters.single.locked, isFalse);
    });
  });

  group('official chapters (licensed vs. fan translation)', () {
    // Mirrors a real source's real markup (confirmed live, 2026-07): every
    // chapter renders the *same* checkmark <svg>, official and fan alike;
    // only its `stroke` attribute differs (#d8b4fe official, #4C4D54 fan).
    // A presence-only check (like lockedSelector) can't distinguish these;
    // officialSelector/officialAttr/officialValue is a value-contains check.
    SourceConfig config() => SourceConfig.fromJson({
      'id': 'official-chapters-like',
      'name': 'Official-Chapters-Like',
      'lang': 'en',
      'baseUrl': 'https://wc.example',
      'popular': {'itemSelector': 'div'},
      'chapters': {
        'itemSelector': 'a',
        'nameSelector': 'span.name',
        'urlSelector': '',
        'urlAttr': 'href',
        'officialSelector': 'span.badge svg',
        'officialAttr': 'stroke',
        'officialValue': '#d8b4fe',
        'reversed': false,
      },
      'pages': {'imageSelector': 'img'},
    });

    String chapterHtml(String stroke) =>
        '<a href="/ch/1"><span class="badge"><svg stroke="$stroke"></svg></span>'
        '<span class="name">Chapter 1</span></a>';

    test(
      'flags chapters whose badge stroke matches officialValue, leaves others alone',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            '<div>'
            '${chapterHtml('#d8b4fe')}' // official
            '${chapterHtml('#4C4D54')}' // fan
            '</div>',
            200,
          ),
        );
        final source = htmlSource(config(), client: client);
        final chapters = await source.chapters(
          const MangaRef('https://wc.example/series/x'),
        );
        expect(chapters.map((c) => c.official).toList(), [true, false]);
      },
    );

    test('officialSelector/Attr/Value survive a JSON round trip', () {
      final restored = SourceConfig.fromJson(config().toJson());
      expect(restored.chapters.officialSelector, 'span.badge svg');
      expect(restored.chapters.officialAttr, 'stroke');
      expect(restored.chapters.officialValue, '#d8b4fe');
    });

    test('omitting officialValue leaves every chapter unofficial', () async {
      final noOfficialConfig = SourceConfig.fromJson({
        'id': 'no-official-concept',
        'name': 'No Official Concept',
        'lang': 'en',
        'baseUrl': 'https://plain.example',
        'popular': {'itemSelector': 'div'},
        'chapters': {
          'itemSelector': 'a',
          'nameSelector': 'span.name',
          'urlSelector': '',
          'urlAttr': 'href',
          'reversed': false,
        },
        'pages': {'imageSelector': 'img'},
      });
      expect(noOfficialConfig.chapters.officialValue, isEmpty);
      final client = MockClient(
        (request) async =>
            http.Response('<div>${chapterHtml('#d8b4fe')}</div>', 200),
      );
      final source = htmlSource(noOfficialConfig, client: client);
      final chapters = await source.chapters(
        const MangaRef('https://plain.example/series/x'),
      );
      // No officialSelector/officialValue configured means the source has no
      // such concept: a coincidentally-matching attribute isn't misread.
      expect(chapters.single.official, isFalse);
    });
  });
}

const _wcListingHtml = '''
<html><body>
  <article>
    <section>
      <a href="/series/abc123/solo">
        <picture>
          <source srcset="/covers/abc-small.webp">
          <img src="/covers/abc-fallback.jpg">
        </picture>
        <div class="badges">Ongoing</div>
        <div>Iron Bloom Saga</div>
      </a>
    </section>
  </article>
  <button>View more</button>
</body></html>
''';

const _wcListingLastHtml = '''
<html><body>
  <article>
    <section>
      <a href="/series/def456/other">
        <img src="/covers/def.jpg">
        <div>Other Series</div>
      </a>
    </section>
  </article>
</body></html>
''';

const _wcSeriesHtml = '''
<html><body>
  <section x-data class="head">
    <section>
      <picture>
        <source srcset="/covers/solo-small.webp">
        <img src="/covers/solo-fallback.jpg">
      </picture>
      <ul>
        <li><strong>Author(s): </strong><span><a>ChuGong</a></span><span><a>Disciple</a></span></li>
        <li><strong>Status: </strong><a>Complete</a></li>
        <li><strong>Type: </strong><a>Manhwa</a></li>
      </ul>
    </section>
    <section>
      <h1>Iron Bloom Saga</h1>
      <ul>
        <li><strong>Tag(s): </strong><a>Action</a> <a>Fantasy</a></li>
        <li><strong>Description</strong><p>Hunters rise.</p></li>
      </ul>
    </section>
  </section>
</body></html>
''';

const _wcChaptersHtml = '''
<html><body>
  <div x-data>
    <a href="/chapters/ch2"><span class="flex"><span>Chapter 2</span><span>today</span></span></a>
    <a href="/chapters/ch1"><span class="flex"><span>Chapter 1</span><span>yesterday</span></span></a>
  </div>
</body></html>
''';

const _wcPagesHtml = '''
<html><body>
  <section x-data="scroll">
    <img src="/img/p1.png">
    <img src="/img/p2.png">
  </section>
</body></html>
''';

SourceConfig _wcConfig() {
  final listing = {
    'pageSize': 2,
    'itemSelector': 'article > section > a',
    'titleSelector': 'div:not([class])',
    'urlSelector': '',
    'urlAttr': 'href',
    'cover': [
      {
        'selector': 'source',
        'attr': 'srcset',
        'replace': {'find': 'small', 'replace': 'normal'},
      },
      {'selector': 'img', 'attr': 'src'},
    ],
    'nextPageSelector': 'button',
  };
  return SourceConfig.fromJson({
    'id': 'epsilon',
    'name': 'Epsilon',
    'lang': 'en',
    'baseUrl': 'https://wc.example',
    'rateLimit': {'requests': 100, 'perMs': 1000},
    'popular': {
      'path': '/search/data?sort=Popularity&offset={offset}',
      ...listing,
    },
    'search': {
      'path': '/search/data?text={query}&offset={offset}',
      'queryReplace': {'pattern': '[!#:(),-]', 'replace': ' '},
      ...listing,
    },
    'details': {
      'titleSelector': 'section.head h1',
      'cover': [
        {
          'selector': 'section.head source',
          'attr': 'srcset',
          'replace': {'find': 'small', 'replace': 'normal'},
        },
        {'selector': 'section.head img', 'attr': 'src'},
      ],
      'rows': {
        'itemSelector': 'section.head ul > li',
        'labelSelector': 'strong',
        'fields': {
          'author': {'label': 'Author', 'valueSelector': 'span > a'},
          'status': {'label': 'Status', 'valueSelector': 'a'},
          'genres': {
            'label': ['Tag', 'Type'],
            'valueSelector': 'a',
          },
          'description': {'label': 'Description', 'valueSelector': 'p'},
        },
      },
      'statusMap': {
        'ongoing': 'ongoing',
        'complete': 'completed',
        'hiatus': 'hiatus',
        'canceled': 'cancelled',
      },
    },
    'chapters': {
      'request': {
        'pattern': r'^(.*/series/[^/]+)/.*$',
        'replace': r'$1/full-chapter-list',
      },
      'itemSelector': 'div[x-data] > a',
      'nameSelector': 'span.flex > span',
      'urlSelector': '',
      'urlAttr': 'href',
      'reversed': true,
    },
    'pages': {
      'request': {'suffix': '/images?reading_style=long_strip'},
      'imageSelector': 'section[x-data] > img',
      'imageAttr': 'src',
    },
  });
}

http.Client _wcFakeServer() => MockClient((request) async {
  final path = '${request.url.path}?${request.url.query}'.replaceAll(
    RegExp(r'\?$'),
    '',
  );
  return switch (path) {
    '/search/data?sort=Popularity&offset=0' => http.Response(
      _wcListingHtml,
      200,
    ),
    '/search/data?sort=Popularity&offset=2' => http.Response(
      _wcListingLastHtml,
      200,
    ),
    // 'naruto: shippuden!' sanitized: punctuation to spaces, trimmed.
    '/search/data?text=naruto++shippuden&offset=0' => http.Response(
      _wcListingHtml,
      200,
    ),
    '/series/abc123/solo' => http.Response(_wcSeriesHtml, 200),
    '/series/abc123/full-chapter-list' => http.Response(_wcChaptersHtml, 200),
    '/chapters/ch1/images?reading_style=long_strip' => http.Response(
      _wcPagesHtml,
      200,
    ),
    _ => http.Response('not found: $path', 404),
  };
});
