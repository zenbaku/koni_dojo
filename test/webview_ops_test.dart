// Which operations go through a browser, and which take the HTTP client.
//
// `webview` used to be one bool for the whole source, so declaring it for the
// one endpoint that needs script put a browser page load on *every* request —
// including the reader's page list, which is the hottest path there is. On
// one real source, measured 2026-08-26, the chapter list is the only thing a
// plain fetch gets wrong (2 `<option>` entries against 2754 in the live DOM)
// while the reader's page list comes back identical either way.
//
// Cheap on native and ruinous on web, where the renderer is a background tab:
// its timers are clamped to one per second and `requestAnimationFrame` never
// fires at all.
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// The markup a plain fetch gets: everything but the chapter list.
const _fetched = '''
<html><body>
  <h1 class="title">A Series</h1>
  <div class="pages"><img src="/p/1.jpg"><img src="/p/2.jpg"></div>
  <ul></ul>
</body></html>
''';

/// What the same URL looks like once its script has run.
const _rendered = '''
<html><body>
  <h1 class="title">A Series</h1>
  <div class="pages"><img src="/p/1.jpg"><img src="/p/2.jpg"></div>
  <ul>
    <li class="chapter"><a href="/read/1">Chapter 1</a></li>
    <li class="chapter"><a href="/read/2">Chapter 2</a></li>
  </ul>
</body></html>
''';

/// Records which transport served what, and nothing else.
class _RecordingFetcher implements WebViewFetcher {
  final rendered = <String>[];

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? localStorageSeed,
  }) async {
    rendered.add(Uri.parse(url).path);
    return _rendered;
  }

  @override
  Future<Uint8List> fetchBytes(
    String url, {
    Map<String, String>? headers,
    bool warmByUrl = false,
    bool viaImgTag = false,
    String? baseUrl,
  }) async => Uint8List(0);
}

/// `true` for every operation, or a list for the ones named.
///
/// Spelled out here because the wire format deliberately keeps `webview` a
/// bool and puts the narrowing in `webviewOps` — an engine that predates that
/// key drops any extension whose `webview` is a list, so a narrowed config has
/// to stay readable by one.
Map<String, Object?> webviewJson(Object webview) => webview is List
    ? {'webview': true, 'webviewOps': webview}
    : {'webview': webview};

void main() {
  late List<String> fetched;
  late _RecordingFetcher fetcher;

  Source build(
    Object? webview, {
    bool? challengesPlainClients,
    bool clientIsBrowserSession = false,
  }) {
    fetched = [];
    fetcher = _RecordingFetcher();
    return htmlSource(
      SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        if (webview != null) ...webviewJson(webview),
        if (challengesPlainClients != null)
          'challengesPlainClients': challengesPlainClients,
        'details': {'titleSelector': 'h1.title'},
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {
          'itemSelector': 'li.chapter',
          'nameSelector': 'a',
          'urlSelector': 'a',
          'urlAttr': 'href',
        },
        'pages': {'imageSelector': '.pages img'},
      }),
      client: MockClient((request) async {
        fetched.add(request.url.path);
        return http.Response(_fetched, 200);
      }),
      webViewFetcher: fetcher,
      clientIsBrowserSession: () => clientIsBrowserSession,
    );
  }

  /// One config, with whatever webview keys are given.
  SourceConfig parse(Map<String, Object?> webviewKeys) =>
      SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        ...webviewKeys,
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'li'},
        'pages': {'imageSelector': 'img'},
      });

  group('parsing', () {
    test('`true` alone still means every operation', () {
      final config = parse({'webview': true});
      expect(config.webviewOps, SourceOp.values.toSet());
      expect(config.webview, isTrue);
      for (final op in SourceOp.values) {
        expect(config.webviewFor(op), isTrue, reason: '$op');
      }
    });

    test('`webviewOps` narrows it, and it stays a webview source', () {
      final config = parse(webviewJson(['chapters']));
      expect(config.webviewFor(SourceOp.chapters), isTrue);
      expect(config.webviewFor(SourceOp.pages), isFalse);
      expect(
        config.webview,
        isTrue,
        reason: 'capability gating asks "does this source need a renderer at '
            'all" — a narrowed source still does, and a build without one '
            'must still refuse before the request',
      );
    });

    test('absent and false both mean no renderer', () {
      expect(parse(const {}).webview, isFalse);
      expect(parse({'webview': false}).webview, isFalse);
      expect(parse({'webview': false}).webviewOps, isEmpty);
    });

    test('an unknown operation name costs only itself', () {
      // The repo index is as often written by a newer build than the one
      // reading it as the other way round.
      expect(parse(webviewJson(['nonesuch'])).webviewOps, isEmpty);
      expect(
        parse(webviewJson(['nonesuch', 'chapters'])).webviewOps,
        {SourceOp.chapters},
        reason: 'one unreadable entry must not cost the readable ones',
      );
    });

    test('an empty `webviewOps` is an answer, not an absence', () {
      /* "Nothing here is script-built, but the host still walls a plain
       * client" is a real and common shape — it is what every `webview: true`
       * source set for Cloudflare alone actually is. */
      final config = parse({'webview': true, 'webviewOps': const <String>[]});
      expect(config.webviewOps, isEmpty);
      expect(config.challengesPlainClients, isTrue);
      expect(config.webview, isTrue);
    });

    test('a narrowed config stays readable by an engine without the key', () {
      /* The compatibility contract, asserted rather than described. An older
       * engine parses `webview` with a hard `as bool?` cast and *drops the
       * whole extension* when it throws — so the narrowing must never be the
       * value of that key, and `webview` must stay true so those builds keep
       * rendering everything (the old behaviour: slow, never wrong). */
      final json = parse(webviewJson(['chapters'])).toJson();
      expect(json['webview'], isTrue);
      expect(json['webviewOps'], ['chapters']);
    });

    test('round-trips without widening', () {
      Map<String, dynamic> roundTrip(Map<String, Object?> keys) =>
          parse(keys).toJson();

      expect(roundTrip({'webview': true})['webview'], true);
      expect(
        roundTrip({'webview': true}).containsKey('webviewOps'),
        isFalse,
        reason: 'a config that never narrowed must round-trip unchanged',
      );
      expect(roundTrip(webviewJson(['chapters']))['webviewOps'], ['chapters']);
      expect(roundTrip(webviewJson(['pages', 'chapters']))['webviewOps'], [
        'chapters',
        'pages',
      ]);
      expect(roundTrip(const {})['webview'], isNull);
    });
  });

  /* This group isolates the *operations* dimension, so its configs say the
   * host does not wall plain clients. A narrowed source that does is the whole
   * subject of the next group, and mixing the two here would mean every
   * assertion answered "rendered" for a reason it wasn't testing. */
  group('routing', () {
    test('`true` renders every operation, as it always did', () async {
      final source = build(true);
      await source.popular(1);
      await source.details(MangaRef('/manga/one'));
      await source.chapters(MangaRef('/manga/one'));
      await source.pages(ChapterRef('/read/1'));

      expect(fetched, isEmpty, reason: 'nothing should reach the HTTP client');
      expect(fetcher.rendered, hasLength(4));
    });

    test('a narrowed source renders only what it named', () async {
      final source = build(['chapters'], challengesPlainClients: false);

      final chapters = await source.chapters(MangaRef('/manga/one'));
      expect(chapters, hasLength(2), reason: 'the rendered list must parse');
      expect(fetcher.rendered, ['/manga/one']);

      final pages = await source.pages(ChapterRef('/read/1'));
      expect(pages, hasLength(2), reason: 'the fetched page list must parse');
      expect(
        fetcher.rendered,
        ['/manga/one'],
        reason: 'the reader\'s page list must not touch the browser',
      );
      expect(fetched, ['/read/1']);
    });

    test('details and chapters on one URL take different transports', () async {
      final source = build(['chapters'], challengesPlainClients: false);
      final ref = MangaRef('/manga/one');

      final result = await source.withSharedRequests(() async {
        final details = await source.details(ref);
        final chapters = await source.chapters(ref);
        return (details, chapters);
      });

      expect(result.$1.title, 'A Series');
      expect(
        result.$2,
        hasLength(2),
        reason: 'sharing handed chapters the un-rendered body — the exact '
            'failure `webview: [chapters]` exists to prevent',
      );
      expect(fetched, ['/manga/one'], reason: 'details went out plain');
      expect(fetcher.rendered, ['/manga/one'], reason: 'chapters rendered');
    });

    test('two renders of one URL still share inside a scope', () async {
      final source = build(true);
      final ref = MangaRef('/manga/one');

      await source.withSharedRequests(() async {
        await source.details(ref);
        await source.chapters(ref);
      });

      expect(
        fetcher.rendered,
        ['/manga/one'],
        reason: 'same URL, same transport — splitting the share key by '
            'transport must not split it by operation',
      );
    });
  });

  /* The half a bare `webview: true` never said out loud.
   *
   * A host can need a browser for two unrelated reasons: its content is built
   * by script (no client fixes that), or it refuses anything that isn't a real
   * browser session (a client with the user's own cookies does fix that). They
   * were indistinguishable, so narrowing a config would have quietly moved a
   * Cloudflare-hard source onto the plain client — fixing web by breaking
   * every native build.
   */
  group('challengesPlainClients', () {
    test('a bare `webview: true` still implies it', () {
      final config = SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        'webview': true,
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'li'},
        'pages': {'imageSelector': 'img'},
      });
      expect(config.challengesPlainClients, isTrue);
    });

    test('a plain client renders everything, narrowed or not', () async {
      final source = build(['chapters'], challengesPlainClients: true);

      await source.popular(1);
      await source.pages(ChapterRef('/read/1'));

      expect(
        fetched,
        isEmpty,
        reason: 'a plain HTTP client is behind the wall — narrowing must not '
            'move native onto it',
      );
      expect(fetcher.rendered, hasLength(2));
    });

    test('a browser-session client renders only the script-built ones', () async {
      final source = build(
        ['chapters'],
        challengesPlainClients: true,
        clientIsBrowserSession: true,
      );

      await source.popular(1);
      final pages = await source.pages(ChapterRef('/read/1'));
      await source.chapters(MangaRef('/manga/one'));

      expect(pages, hasLength(2));
      expect(
        fetcher.rendered,
        ['/manga/one'],
        reason: 'only the chapter list is script-built; the wall is already '
            'behind this client',
      );
      expect(fetched, ['/p', '/read/1']);
    });

    test('a browser session does not excuse script-built content', () async {
      final source = build(
        ['chapters'],
        challengesPlainClients: true,
        clientIsBrowserSession: true,
      );
      final chapters = await source.chapters(MangaRef('/manga/one'));

      expect(chapters, hasLength(2));
      expect(
        fetcher.rendered,
        ['/manga/one'],
        reason: 'no session, however good, puts content in a response that '
            'never carried it',
      );
    });

    test('it alone still makes this a webview source for capability gates', () {
      final config = SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        'challengesPlainClients': true,
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'li'},
        'pages': {'imageSelector': 'img'},
      });
      expect(config.webviewOps, isEmpty);
      expect(config.webview, isTrue);
    });

    test('round-trips beside a narrowed webview', () {
      final json = parse({
        ...webviewJson(['chapters']),
        'challengesPlainClients': true,
      }).toJson();
      expect(json['webview'], isTrue);
      expect(json['webviewOps'], ['chapters']);
      expect(
        json.containsKey('challengesPlainClients'),
        isFalse,
        reason: 'true is what `webview: true` already implies; writing it out '
            'again is noise a rebuilt index would carry forever',
      );
    });

    test('a narrowed source that does NOT wall plain clients says so', () {
      final json = parse({
        ...webviewJson(['chapters']),
        'challengesPlainClients': false,
      }).toJson();
      expect(json['challengesPlainClients'], isFalse);
      expect(
        parse(json).challengesPlainClients,
        isFalse,
        reason: 'the exception to the default has to survive a round trip, or '
            'a rebuild of the index silently re-walls the source',
      );
    });

    test('is not written out when `webview: true` already implies it', () {
      final json = SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        'webview': true,
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {'itemSelector': 'li'},
        'pages': {'imageSelector': 'img'},
      }).toJson();
      expect(json['webview'], true);
      expect(
        json.containsKey('challengesPlainClients'),
        isFalse,
        reason: 'a config that never narrowed must round-trip unchanged',
      );
    });
  });

  /* The one thing a browser cannot be asked for.
   *
   * A navigation always produces a document: open a JSON endpoint in a tab and
   * it comes back wrapped in `<html><body><pre>`, which no decoder can read.
   * So the runner tells the engine what a step's body is meant to be, and a
   * `parse: json` step takes the HTTP client whatever the config says.
   *
   * Not a nicety — it is what lets a config move an endpoint onto its site's
   * own JSON API without breaking the platforms where `webview` is doing real
   * work. One real source's chapter list is exactly that: a JSON API that
   * answers a plain client with 200 while its HTML pages answer 403.
   */
  group('a JSON step is never rendered', () {
    /// A source whose chapters come from a JSON endpoint, on a host that walls
    /// plain clients — i.e. everything about it says "render", except the one
    /// thing that decides.
    Source jsonChapters() {
      fetched = [];
      fetcher = _RecordingFetcher();
      return htmlSource(
        SourceConfig.fromJson({
          'id': 'f',
          'name': 'F',
          'baseUrl': 'https://example.test',
          'webview': true,
          'popular': {'path': '/p', 'itemSelector': 'a'},
          'pages': {'imageSelector': 'img'},
          'chapters': {
            'steps': [
              {
                // No request at all: the slug is already in a threaded var.
                'capture': {
                  'slug': {'regex': r'/manga/([^/?#]+)', 'from': 'mangaUrl'},
                },
              },
              {
                'request': {'url': '{baseUrl}/api/manga/{slug}/chapters'},
                'parse': 'json',
                'yield': {
                  'list': {'path': 'data.chapters'},
                  'fields': {
                    'name': {'path': 'chapter_name'},
                    'url': {
                      'path': 'chapter_slug',
                      'template': '{mangaUrl}/{value}',
                    },
                  },
                },
              },
            ],
          },
        }),
        client: MockClient((request) async {
          fetched.add(request.url.toString());
          return http.Response(
            '{"data":{"chapters":[{"chapter_name":"One",'
            '"chapter_slug":"chapter-1"}]}}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        webViewFetcher: fetcher,
      );
    }

    test('it takes the HTTP client even on a full `webview: true` source', () async {
      final source = jsonChapters();
      final chapters = await source.chapters(
        MangaRef('https://example.test/manga/one-piece'),
      );

      expect(chapters, hasLength(1));
      expect(chapters.single.url, 'https://example.test/manga/one-piece/chapter-1');
      expect(
        fetcher.rendered,
        isEmpty,
        reason: 'rendered, this would have returned the JSON wrapped in '
            '<html><body><pre> and the decoder would have thrown',
      );
      expect(fetched, ['https://example.test/api/manga/one-piece/chapters']);
    });

    test('and the whole chapter list costs exactly one request', () async {
      /* The step that derives the slug has no `request`, so it fetches
       * nothing. That is the difference between "one JSON call" and "a page
       * load first, to read a value already in hand". */
      final source = jsonChapters();
      await source.chapters(MangaRef('https://example.test/manga/one-piece'));
      expect(fetched, hasLength(1));
    });
  });

  test('with no renderer on this build, everything falls back to HTTP', () async {
    fetched = [];
    final source = htmlSource(
      SourceConfig.fromJson({
        'id': 'f',
        'name': 'F',
        'baseUrl': 'https://example.test',
        'webview': true,
        'webviewOps': ['chapters'],
        'popular': {'path': '/p', 'itemSelector': 'a'},
        'chapters': {
          'itemSelector': 'li.chapter',
          'nameSelector': 'a',
          'urlSelector': 'a',
          'urlAttr': 'href',
        },
        'pages': {'imageSelector': '.pages img'},
      }),
      client: MockClient((request) async {
        fetched.add(request.url.path);
        return http.Response(_fetched, 200);
      }),
    );

    await source.chapters(MangaRef('/manga/one'));
    expect(fetched, ['/manga/one']);
  });
}
