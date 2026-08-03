import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

const _popularHtml = '''
<html><body>
  <div class="item">
    <a class="title" href="/manga/alpha">Alpha Adventure</a>
    <img src="/covers/alpha.jpg">
  </div>
</body></html>
''';

/// A popular listing whose first item has no chapters and second does.
/// Exercises the multi-candidate fallback in `probeSource`.
const _popularHtmlTwoItems = '''
<html><body>
  <div class="item">
    <a class="title" href="/manga/alpha">Alpha Adventure</a>
    <img src="/covers/alpha.jpg">
  </div>
  <div class="item">
    <a class="title" href="/manga/beta">Beta Journey</a>
    <img src="/covers/beta.jpg">
  </div>
</body></html>
''';

/// A popular listing with more chapterless items than `probeSource` will
/// try. Exercises the candidate cap.
String _popularHtmlManyItems(int count) =>
    '''
<html><body>
${[for (var i = 1; i <= count; i++) '  <div class="item"><a class="title" href="/manga/dud$i">Dud $i</a></div>'].join('\n')}
</body></html>
''';

const _mangaHtmlBeta = '''
<html><body>
  <h1 class="manga-title">Beta Journey</h1>
  <span class="author">Some Mangaka</span>
  <p class="summary">Another thrilling tale.</p>
  <ul class="chapter-list">
    <li class="chapter"><a href="/manga/beta/ch-1">Chapter 1</a></li>
  </ul>
</body></html>
''';

const _emptyHtml = '<html><body></body></html>';

const _mangaHtml = '''
<html><body>
  <h1 class="manga-title">Alpha Adventure: Deluxe</h1>
  <span class="author">Some Mangaka</span>
  <p class="summary">A thrilling tale.</p>
  <ul class="chapter-list">
    <li class="chapter"><a href="/manga/alpha/ch-1">Chapter 1</a></li>
  </ul>
</body></html>
''';

const _mangaHtmlNoChapters = '''
<html><body>
  <h1 class="manga-title">Alpha Adventure: Deluxe</h1>
  <span class="author">Some Mangaka</span>
  <p class="summary">A thrilling tale.</p>
  <ul class="chapter-list"></ul>
</body></html>
''';

const _chapterHtml = '''
<html><body>
  <div class="reader">
    <img class="page" src="/pages/1.jpg">
    <img class="page" src="/pages/2.jpg">
    <img class="page" src="/pages/3.jpg">
  </div>
</body></html>
''';

// A locked/paid chapter: the reader div exists but holds no images.
const _lockedChapterHtml = '''
<html><body>
  <div class="reader"><p>Buy this chapter to read it!</p></div>
</body></html>
''';

const _mangaHtmlWithGenre = '''
<html><body>
  <h1 class="manga-title">Alpha Adventure: Deluxe</h1>
  <span class="author">Some Mangaka</span>
  <p class="summary">A thrilling tale.</p>
  <a class="genre">Action</a>
  <ul class="chapter-list">
    <li class="chapter"><a href="/manga/alpha/ch-1">Chapter 1</a></li>
  </ul>
</body></html>
''';

const _mangaHtmlThreeChapters = '''
<html><body>
  <h1 class="manga-title">Alpha Adventure: Deluxe</h1>
  <span class="author">Some Mangaka</span>
  <p class="summary">A thrilling tale.</p>
  <ul class="chapter-list">
    <li class="chapter"><a href="/manga/alpha/ch-3">Chapter 3</a></li>
    <li class="chapter"><a href="/manga/alpha/ch-2">Chapter 2</a></li>
    <li class="chapter"><a href="/manga/alpha/ch-1">Chapter 1</a></li>
  </ul>
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
  },
  'details': {
    'titleSelector': 'h1.manga-title',
    'authorSelector': 'span.author',
    'descriptionSelector': 'p.summary',
  },
  'chapters': {
    'itemSelector': 'li.chapter',
    'nameSelector': 'a',
    'urlSelector': 'a',
  },
  'pages': {'imageSelector': 'div.reader img.page', 'imageAttr': 'src'},
});

/// [_config] plus a `tag` listing and a static `filters` group: [genreOnDetails]
/// toggles whether `details` also extracts a genre (the "discovered" tag
/// path); when false, `probeSource`'s only option is the filter fallback.
SourceConfig _configWithTag({bool genreOnDetails = true}) {
  final json = _config().toJson();
  json['details'] = {
    ...json['details'] as Map<String, dynamic>,
    if (genreOnDetails) 'genreSelector': 'a.genre',
  };
  // hasFilters requires a `search` block too (filters are conceptually
  // scoped to search), unused by these tests otherwise, but needed for
  // Source.filters() to consider the `filters` array below at all.
  json['search'] = {
    'path': '/search?q={query}',
    'itemSelector': 'div.item',
    'titleSelector': 'a.title',
    'urlSelector': 'a.title',
  };
  json['tag'] = {
    'path': '/tags/{query}',
    'itemSelector': 'div.item',
    'titleSelector': 'a.title',
    'urlSelector': 'a.title',
    'coverSelector': 'img',
  };
  json['filters'] = [
    {
      'id': 'genres',
      'name': 'Genres',
      'param': 'included_tag',
      'options': [
        {'value': 'Action', 'label': 'Action'},
      ],
    },
  ];
  return SourceConfig.fromJson(json);
}

http.Client _serverWith(
  Map<String, http.Response> routes, {
  void Function(String path)? onRequest,
}) => MockClient((request) async {
  final path = '${request.url.path}?${request.url.query}'.replaceAll(
    RegExp(r'\?$'),
    '',
  );
  onRequest?.call(path);
  return routes[path] ?? http.Response('not found', 404);
});

void main() {
  test('resolves the full reader path in one shot', () async {
    final source = htmlSource(
      _config(),
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtml, 200),
        '/manga/alpha': http.Response(_mangaHtml, 200),
        '/manga/alpha/ch-1': http.Response(_chapterHtml, 200),
      }),
    );

    final result = await probeSource(source);

    expect(result.passed, isTrue);
    expect(result.failedStage, isNull);
    expect(result.popular?.single.title, 'Alpha Adventure');
    expect(result.details?.title, 'Alpha Adventure: Deluxe');
    expect(result.chapters?.single.name, 'Chapter 1');
    expect(result.pages?.length, 3);
    // _mangaHtml has no cover of its own: probeSource threads the popular
    // candidate's thumbnail into the MangaRef as a fallback, since some
    // sites genuinely have no cover on the details page itself.
    expect(
      result.details?.thumbnailUrl,
      'https://example.com/covers/alpha.jpg',
    );
  });

  test('chaptersConfigured: false skips chapters and pages entirely — no '
      'failure, no request for either', () async {
    final blankConfig = SourceConfig.fromJson({
      ..._config().toJson(),
      'chapters': <String, dynamic>{},
      'pages': <String, dynamic>{},
    });
    final source = htmlSource(
      blankConfig,
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtml, 200),
        '/manga/alpha': http.Response(_mangaHtml, 200),
      }),
    );

    final result = await probeSource(source, chaptersConfigured: false);

    expect(result.passed, isTrue);
    expect(result.failedStage, isNull);
    expect(result.popular?.single.title, 'Alpha Adventure');
    expect(result.details?.title, 'Alpha Adventure: Deluxe');
    expect(result.chapters, isNull);
    expect(result.pages, isNull);
  });

  test('pagesConfigured: false resolves chapters but skips pages, no request '
      'for the chapter itself', () async {
    final noPagesConfig = SourceConfig.fromJson({
      ..._config().toJson(),
      'pages': <String, dynamic>{},
    });
    final source = htmlSource(
      noPagesConfig,
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtml, 200),
        '/manga/alpha': http.Response(_mangaHtml, 200),
      }),
    );

    final result = await probeSource(source, pagesConfigured: false);

    expect(result.passed, isTrue);
    expect(result.failedStage, isNull);
    expect(result.chapters?.single.name, 'Chapter 1');
    expect(result.pages, isNull);
  });

  test('detailsConfigured: false skips details even though it wouldn\'t throw '
      'on a blank selector — only popular is fetched when nothing else is '
      'configured', () async {
    final requested = <String>[];
    final blankConfig = SourceConfig.fromJson({
      ..._config().toJson(),
      'details': <String, dynamic>{},
      'chapters': <String, dynamic>{},
      'pages': <String, dynamic>{},
    });
    final source = htmlSource(
      blankConfig,
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtml, 200),
        '/manga/alpha': http.Response(_mangaHtml, 200),
      }, onRequest: requested.add),
    );

    final result = await probeSource(
      source,
      detailsConfigured: false,
      chaptersConfigured: false,
    );

    expect(result.passed, isTrue);
    expect(result.failedStage, isNull);
    expect(result.popular?.single.title, 'Alpha Adventure');
    expect(result.details, isNull);
    expect(requested, ['/popular?page=1']);
  });

  test('detailsConfigured: false and chaptersConfigured: true are independent '
      '— chapters still resolves without details', () async {
    final noDetailsConfig = SourceConfig.fromJson({
      ..._config().toJson(),
      'details': <String, dynamic>{},
    });
    final source = htmlSource(
      noDetailsConfig,
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtml, 200),
        '/manga/alpha': http.Response(_mangaHtml, 200),
      }),
    );

    final result = await probeSource(
      source,
      detailsConfigured: false,
      pagesConfigured: false,
    );

    expect(result.passed, isTrue);
    expect(result.details, isNull);
    expect(result.chapters?.single.name, 'Chapter 1');
  });

  test('stops at popular when it returns nothing', () async {
    final source = htmlSource(
      _config(),
      client: _serverWith({'/popular?page=1': http.Response(_emptyHtml, 200)}),
    );

    final result = await probeSource(source);

    expect(result.passed, isFalse);
    expect(result.failedStage, 'popular');
    expect(result.popular, isEmpty);
    expect(result.details, isNull);
    expect(result.chapters, isNull);
    expect(result.pages, isNull);
  });

  test(
    'stops at chapters when it returns nothing, keeping popular/details',
    () async {
      final source = htmlSource(
        _config(),
        client: _serverWith({
          '/popular?page=1': http.Response(_popularHtml, 200),
          '/manga/alpha': http.Response(_mangaHtmlNoChapters, 200),
        }),
      );

      final result = await probeSource(source);

      expect(result.passed, isFalse);
      expect(result.failedStage, 'chapters');
      expect(result.popular, isNotEmpty);
      expect(result.details, isNotNull);
      expect(result.chapters, isEmpty);
      expect(result.pages, isNull);
    },
  );

  test('falls through to the next popular candidate when the first has no '
      'chapters', () async {
    final source = htmlSource(
      _config(),
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtmlTwoItems, 200),
        '/manga/alpha': http.Response(_mangaHtmlNoChapters, 200),
        '/manga/beta': http.Response(_mangaHtmlBeta, 200),
        '/manga/beta/ch-1': http.Response(_chapterHtml, 200),
        // /manga/alpha/ch-1 is deliberately unstubbed: alpha has no
        // chapters, so nothing should ever try to fetch it.
      }),
    );

    final result = await probeSource(source);

    expect(result.passed, isTrue);
    expect(result.failedStage, isNull);
    expect(result.details?.title, 'Beta Journey');
    expect(result.chapters?.single.name, 'Chapter 1');
    expect(result.pages?.length, 3);
  });

  test('gives up after $maxMangaCandidates chapterless candidates rather than '
      'trying every popular item', () async {
    const dudCount = maxMangaCandidates + 1;
    final routes = {
      '/popular?page=1': http.Response(_popularHtmlManyItems(dudCount), 200),
      for (var i = 1; i <= dudCount; i++)
        '/manga/dud$i': http.Response(_mangaHtmlNoChapters, 200),
    };
    // details() and chapters() both fetch the manga URL itself (no
    // separate chapters endpoint in this config), so each tried candidate
    // shows up twice: dedupe to count *candidates*, not raw requests.
    final mangaRequests = <String>{};
    final source = htmlSource(
      _config(),
      client: _serverWith(
        routes,
        onRequest: (path) {
          if (path.startsWith('/manga/dud')) mangaRequests.add(path);
        },
      ),
    );

    final result = await probeSource(source);

    expect(result.passed, isFalse);
    expect(result.failedStage, 'chapters');
    expect(result.error, contains('tried $maxMangaCandidates candidates'));
    // Exactly the capped number of candidates were actually requested:
    // the (maxMangaCandidates + 1)th dud never got a details/chapters
    // request at all.
    expect(mangaRequests, hasLength(maxMangaCandidates));
    expect(mangaRequests, isNot(contains('/manga/dud$dudCount')));
  });

  test('pages samples middle/last chapters when the first is empty', () async {
    final source = htmlSource(
      _config(),
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtml, 200),
        '/manga/alpha': http.Response(_mangaHtmlThreeChapters, 200),
        // Newest chapter (list order first) serves no images; the middle
        // one resolves. This is why the stage samples more than the first.
        '/manga/alpha/ch-3': http.Response(_lockedChapterHtml, 200),
        '/manga/alpha/ch-2': http.Response(_chapterHtml, 200),
        '/manga/alpha/ch-1': http.Response(_lockedChapterHtml, 200),
      }),
    );

    final result = await probeSource(source);

    expect(result.passed, isTrue);
    expect(result.pages?.length, 3);
  });

  test('pages still fails when every sampled chapter is empty', () async {
    final source = htmlSource(
      _config(),
      client: _serverWith({
        '/popular?page=1': http.Response(_popularHtml, 200),
        '/manga/alpha': http.Response(_mangaHtmlThreeChapters, 200),
        '/manga/alpha/ch-3': http.Response(_lockedChapterHtml, 200),
        '/manga/alpha/ch-2': http.Response(_lockedChapterHtml, 200),
        '/manga/alpha/ch-1': http.Response(_lockedChapterHtml, 200),
      }),
    );

    final result = await probeSource(source);

    expect(result.passed, isFalse);
    expect(result.failedStage, 'pages');
    expect(result.chapters, hasLength(3));
  });

  test(
    'a per-chapter error is tolerated when another sampled chapter has pages',
    () async {
      final source = htmlSource(
        _config(),
        client: _serverWith({
          '/popular?page=1': http.Response(_popularHtml, 200),
          '/manga/alpha': http.Response(_mangaHtmlThreeChapters, 200),
          // ch-3 isn't stubbed -> 404 -> engine exception; ch-2 works.
          '/manga/alpha/ch-2': http.Response(_chapterHtml, 200),
        }),
      );

      final result = await probeSource(source);

      expect(result.passed, isTrue);
      expect(result.pages?.length, 3);
    },
  );

  test(
    'a request failure is captured, not thrown, with the stage attached',
    () async {
      final source = htmlSource(
        _config(),
        client: _serverWith({
          '/popular?page=1': http.Response(_popularHtml, 200),
        }),
        // /manga/alpha isn't stubbed -> 404, which the engine surfaces as an
        // exception rather than an empty result.
      );

      final result = await probeSource(source);

      expect(result.passed, isFalse);
      expect(result.failedStage, 'details');
      expect(result.error, isNotNull);
      expect(result.popular, isNotEmpty);
    },
  );

  group('tag probing', () {
    test('no tag config at all leaves tagTried/tag null', () async {
      // The plain _config() (used by every test above) has no `tag` block:
      // hasTagListing is false, so the probe never attempts it.
      final source = htmlSource(
        _config(),
        client: _serverWith({
          '/popular?page=1': http.Response(_popularHtml, 200),
          '/manga/alpha': http.Response(_mangaHtml, 200),
          '/manga/alpha/ch-1': http.Response(_chapterHtml, 200),
        }),
      );

      final result = await probeSource(source);

      expect(result.passed, isTrue);
      expect(result.tagTried, isNull);
      expect(result.tag, isNull);
    });

    test('a genre details actually carries drives the tag probe (the '
        '"discovered" path)', () async {
      final source = htmlSource(
        _configWithTag(),
        client: _serverWith({
          '/popular?page=1': http.Response(_popularHtml, 200),
          '/manga/alpha': http.Response(_mangaHtmlWithGenre, 200),
          '/manga/alpha/ch-1': http.Response(_chapterHtml, 200),
          '/tags/Action': http.Response(_popularHtml, 200),
        }),
      );

      final result = await probeSource(source);

      expect(result.passed, isTrue);
      expect(result.details?.genres, ['Action']);
      expect(result.tagTried, 'Action');
      expect(result.tag?.single.title, 'Alpha Adventure');
    });

    test('falls back to the source\'s own first filter option when details '
        'has no genres (the "enumerated" path)', () async {
      final source = htmlSource(
        _configWithTag(genreOnDetails: false),
        client: _serverWith({
          '/popular?page=1': http.Response(_popularHtml, 200),
          '/manga/alpha': http.Response(_mangaHtml, 200),
          '/manga/alpha/ch-1': http.Response(_chapterHtml, 200),
          '/tags/Action': http.Response(_popularHtml, 200),
        }),
      );

      final result = await probeSource(source);

      expect(result.passed, isTrue);
      expect(result.details?.genres, isEmpty);
      expect(result.tagTried, 'Action');
      expect(result.tag?.single.title, 'Alpha Adventure');
    });

    test(
      'a failing tag probe never fails the whole probe — best-effort only',
      () async {
        final source = htmlSource(
          _configWithTag(),
          client: _serverWith({
            '/popular?page=1': http.Response(_popularHtml, 200),
            '/manga/alpha': http.Response(_mangaHtmlWithGenre, 200),
            '/manga/alpha/ch-1': http.Response(_chapterHtml, 200),
            // /tags/Action deliberately unstubbed -> 404 -> exception,
            // swallowed rather than failing the overall probe.
          }),
        );

        final result = await probeSource(source);

        expect(result.passed, isTrue);
        expect(result.failedStage, isNull);
        expect(result.tagTried, 'Action');
        expect(result.tag, isNull);
        // Everything else the chain actually needs still resolved.
        expect(result.chapters, isNotEmpty);
        expect(result.pages, isNotEmpty);
      },
    );
  });
}
