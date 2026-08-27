import 'dart:convert';

import 'package:test/test.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:koni_dojo/src/crypto_decrypt.dart';

/// The pipeline engine (`lib/sources/pipeline.dart`) is the unifying model the
/// spike introduces. These tests pin its two claims:
///  1. today's [PagesConfig] shapes desugar onto a faithful one-step pipeline
///     (the `fetchPages` behaviour, proven indirectly in config_source_test);
///  2. a hand-authored *explicit* two-step pipeline expresses the cross-format
///     hop the old two-engine split could not (HTML page → capture an id →
///     JSON ajax), which is the mangareader/zeistmanga cluster's blocker.
void main() {
  group('desugared pages pipeline', () {
    test('<img> scraping → one html step with a data-src fallback', () {
      final p = pagesPipeline(
        PagesConfig(imageSelector: 'div.reader img', imageAttr: 'src'),
      );
      expect(p.steps, hasLength(1));
      final step = p.steps.single;
      expect(step.parse, StepParse.html);
      expect(step.output!.list.selector, 'div.reader img');
      expect(step.output!.value.attr, 'src');
      expect(step.output!.value.imageFallback, isTrue);
    });

    test('script blob → one regexJson step', () {
      final p = pagesPipeline(
        const PagesConfig(
          script: ScriptPagesConfig(
            pattern: r'ts_reader.run\((.*?)\);',
            itemsPath: 'sources[0].images',
          ),
        ),
      );
      final step = p.steps.single;
      expect(step.parse, StepParse.regexJson);
      expect(step.regex, r'ts_reader.run\((.*?)\);');
      expect(step.output!.list.path, 'sources[0].images');
    });
  });

  group('explicit two-phase (HTML → capture id → JSON ajax)', () {
    // The shape mangareader-cluster sites use: the chapter page carries a
    // numeric reading id, and the real page list comes from an AJAX endpoint
    // that answers JSON.
    Pipeline mangareaderPipeline() => Pipeline.fromJson([
      {
        'request': {'url': '{chapterUrl}'},
        'parse': 'html',
        'capture': {
          'id': {'selector': '#wrapper', 'attr': 'data-reading-id'},
        },
      },
      {
        'request': {
          'url': '{baseUrl}/ajax/image/list/chapter/{id}',
          'headers': {'X-Requested-With': 'XMLHttpRequest'},
        },
        'parse': 'json',
        'yield': {
          'list': {'path': 'images'},
          'value': {'template': '{url}'},
        },
      },
    ]);

    test('parses and round-trips through JSON', () {
      final p = mangareaderPipeline();
      expect(p.steps, hasLength(2));
      expect(p.steps[0].capture['id']!.attr, 'data-reading-id');
      expect(p.steps[1].parse, StepParse.json);
      expect(p.steps[1].output!.value.template, '{url}');
      // Lossless round trip.
      expect(Pipeline.fromJson(p.toJson()).toJson(), p.toJson());
    });

    test(
      'threads the captured id into the ajax request and yields pages',
      () async {
        final requested = <String>[];
        final headersSeen = <Map<String, String>>[];

        Future<String> fakeFetch(
          String url, {
          String method = 'GET',
          String body = '',
          Map<String, String> headers = const {},
          bool document = true,
        }) async {
          requested.add(url);
          headersSeen.add(headers);
          if (url == 'https://mr.example/series/x/ch-1') {
            return '<html><body>'
                '<div id="wrapper" data-reading-id="98765">reader</div>'
                '</body></html>';
          }
          if (url == 'https://mr.example/ajax/image/list/chapter/98765') {
            return '{"status":true,"images":['
                '{"url":"https://cdn.mr/98765/1.webp","order":1},'
                '{"url":"https://cdn.mr/98765/2.webp","order":2}'
                ']}';
          }
          fail('unexpected request: $url');
        }

        final pages = await runFlatListPipeline(
          mangareaderPipeline(),
          {
            'baseUrl': 'https://mr.example',
            'chapterUrl': 'https://mr.example/series/x/ch-1',
          },
          baseUrl: 'https://mr.example',
          fetch: fakeFetch,
        );

        // Phase 1 hit the chapter page; phase 2 hit the ajax URL with the id
        // captured from the HTML substituted in.
        expect(requested, [
          'https://mr.example/series/x/ch-1',
          'https://mr.example/ajax/image/list/chapter/98765',
        ]);
        // The ajax step's declared header rode along.
        expect(headersSeen[1]['X-Requested-With'], 'XMLHttpRequest');
        // The JSON image list became the page URLs.
        expect(pages, [
          'https://cdn.mr/98765/1.webp',
          'https://cdn.mr/98765/2.webp',
        ]);
      },
    );

    test('a missing id still produces a well-formed (empty) request', () async {
      Future<String> fakeFetch(
        String url, {
        String method = 'GET',
        String body = '',
        Map<String, String> headers = const {},
        bool document = true,
      }) async {
        if (url.contains('/series/')) {
          return '<html><body><div>no id here</div></body></html>';
        }
        // id captured as '' → ajax url ends with /chapter/
        expect(url, 'https://mr.example/ajax/image/list/chapter/');
        return '{"images":[]}';
      }

      final pages = await runFlatListPipeline(
        mangareaderPipeline(),
        {
          'baseUrl': 'https://mr.example',
          'chapterUrl': 'https://mr.example/series/x/ch-1',
        },
        baseUrl: 'https://mr.example',
        fetch: fakeFetch,
      );
      expect(pages, isEmpty);
    });
  });

  group('record outputs', () {
    Future<String> serve(String body) => Future.value(body);

    test(
      'html record list extracts per-element fields (values stay raw)',
      () async {
        final pipeline = Pipeline([
          Step(
            request: const StepRequest(base: 'mangaUrl'),
            output: StepOutput(
              list: const Locator(selector: 'li.chapter'),
              fields: {
                'url': const Locator(selector: 'a', attr: 'href'),
                'name': const Locator(selector: 'a'),
              },
            ),
          ),
        ]);
        final result = await runRecordListPipeline(
          pipeline,
          {'baseUrl': 'https://s.example', 'mangaUrl': 'https://s.example/m'},
          baseUrl: 'https://s.example',
          fetch:
              (
                url, {
                method = 'GET',
                body = '',
                headers = const {},
                document = true,
              }) => serve(
                '<ul>'
                '<li class="chapter"><a href="/m/ch-2">Chapter 2</a></li>'
                '<li class="chapter"><a href="/m/ch-1">Chapter 1</a></li>'
                '</ul>',
              ),
        );
        // URLs are returned raw: the adapter resolves them against the base.
        expect(result.records, [
          {'url': '/m/ch-2', 'name': 'Chapter 2'},
          {'url': '/m/ch-1', 'name': 'Chapter 1'},
        ]);
      },
    );

    test(
      'a locator falls back through candidates and applies a rewrite',
      () async {
        final pipeline = Pipeline([
          Step(
            request: const StepRequest(base: 'baseUrl'),
            output: StepOutput(
              list: const Locator(selector: 'div.item'),
              fields: {
                // First candidate (data-x) is absent; falls back to src, then
                // rewrites small→normal.
                'cover': const Locator(
                  selector: 'img',
                  attr: 'data-x',
                  fallbacks: [
                    Locator(
                      selector: 'img',
                      attr: 'src',
                      rewrite: ValueRewrite(find: 'small', replace: 'normal'),
                    ),
                  ],
                ),
              },
            ),
          ),
        ]);
        final result = await runRecordListPipeline(
          pipeline,
          const {'baseUrl': 'https://s.example'},
          baseUrl: 'https://s.example',
          fetch:
              (
                url, {
                method = 'GET',
                body = '',
                headers = const {},
                document = true,
              }) => serve('<div class="item"><img src="/c-small.jpg"></div>'),
        );
        expect(result.records.single['cover'], '/c-normal.jpg');
      },
    );

    test('json record list reads fields by path', () async {
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(url: '{baseUrl}/api'),
          parse: StepParse.json,
          output: StepOutput(
            list: const Locator(path: 'data'),
            fields: {
              'url': const Locator(path: 'id'),
              'name': const Locator(path: 'attributes.title'),
            },
          ),
        ),
      ]);
      final result = await runRecordListPipeline(
        pipeline,
        const {'baseUrl': 'https://s.example'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) => serve('{"data":[{"id":"a1","attributes":{"title":"One"}}]}'),
      );
      expect(result.records.single, {'url': 'a1', 'name': 'One'});
    });

    test(
      'json record field templates can pull in captured pipeline vars',
      () async {
        // Regression: a chapters API often returns only a per-chapter slug;
        // the manga's own slug isn't in the JSON at all, it lives in mangaUrl
        // and has to be captured by an earlier step. Field templates must be
        // able to reach a captured var, not just the item/response JSON,
        // the same way the API dialect's JsonValueSpec already can.
        final pipeline = Pipeline([
          Step(
            capture: {
              'slug': const Locator(
                regex: r'/manga/([^/]+)/?$',
                from: 'mangaUrl',
              ),
            },
          ),
          Step(
            request: const StepRequest(
              url: '{baseUrl}/api/comics/{slug}/chapters',
            ),
            parse: StepParse.json,
            output: StepOutput(
              list: const Locator(path: 'data.chapters'),
              fields: {
                'url': const Locator(
                  path: 'chapter_slug',
                  template: '{baseUrl}/manga/{slug}/{value}',
                ),
                'name': const Locator(path: 'chapter_name'),
              },
            ),
          ),
        ]);
        final result = await runRecordListPipeline(
          pipeline,
          const {
            'baseUrl': 'https://s.example',
            'mangaUrl': 'https://s.example/manga/kingdom',
          },
          baseUrl: 'https://s.example',
          fetch:
              (
                url, {
                method = 'GET',
                body = '',
                headers = const {},
                document = true,
              }) {
                expect(url, 'https://s.example/api/comics/kingdom/chapters');
                return serve(
                  '{"data":{"chapters":[{"chapter_slug":"chapter-1",'
                  '"chapter_name":"Chapter 1"}]}}',
                );
              },
        );
        expect(result.records.single, {
          'url': 'https://s.example/manga/kingdom/chapter-1',
          'name': 'Chapter 1',
        });
      },
    );

    test(
      'paginate re-fetches and merges pages until current == last',
      () async {
        // A server-paginated chapters API (Laravel-style current_page/
        // last_page envelope) with no single "everything" request: the
        // engine has to drive the page loop itself.
        final pages = <String, String>{
          '1':
              '{"chapters":[{"n":"a"},{"n":"b"}],'
              '"current_page":1,"last_page":3}',
          '2':
              '{"chapters":[{"n":"c"},{"n":"d"}],'
              '"current_page":2,"last_page":3}',
          '3': '{"chapters":[{"n":"e"}],"current_page":3,"last_page":3}',
        };
        final requested = <String>[];
        final pipeline = Pipeline([
          Step(
            request: const StepRequest(url: '{baseUrl}/api?page={page}'),
            parse: StepParse.json,
            output: StepOutput(
              list: const Locator(path: 'chapters'),
              fields: {'name': const Locator(path: 'n')},
              meta: const {
                'currentPage': Locator(path: 'current_page'),
                'lastPage': Locator(path: 'last_page'),
              },
              paginate: const Pagination(
                currentPageMeta: 'currentPage',
                lastPageMeta: 'lastPage',
              ),
            ),
          ),
        ]);
        final result = await runRecordListPipeline(
          pipeline,
          const {'baseUrl': 'https://s.example'},
          baseUrl: 'https://s.example',
          fetch:
              (
                url, {
                method = 'GET',
                body = '',
                headers = const {},
                document = true,
              }) {
                requested.add(url);
                final page = Uri.parse(url).queryParameters['page']!;
                return serve(pages[page]!);
              },
        );
        expect(requested, [
          'https://s.example/api?page=1',
          'https://s.example/api?page=2',
          'https://s.example/api?page=3',
        ]);
        expect(result.records.map((r) => r['name']), ['a', 'b', 'c', 'd', 'e']);
      },
    );

    test('paginate stops at maxPages against a stuck API', () async {
      // A pathological/misconfigured API that never advances current_page:
      // maxPages is the backstop against looping forever.
      var calls = 0;
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(url: '{baseUrl}/api?page={page}'),
          parse: StepParse.json,
          output: StepOutput(
            list: const Locator(path: 'chapters'),
            fields: {'name': const Locator(path: 'n')},
            meta: const {
              'currentPage': Locator(path: 'current_page'),
              'lastPage': Locator(path: 'last_page'),
            },
            paginate: const Pagination(
              currentPageMeta: 'currentPage',
              lastPageMeta: 'lastPage',
              maxPages: 3,
            ),
          ),
        ),
      ]);
      final result = await runRecordListPipeline(
        pipeline,
        const {'baseUrl': 'https://s.example'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) {
              calls++;
              return serve(
                '{"chapters":[{"n":"x"}],"current_page":1,"last_page":99}',
              );
            },
      );
      expect(calls, 3);
      expect(result.records, hasLength(3));
    });

    test('object-keyed json list iterates map values in order', () async {
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(url: '{baseUrl}/api'),
          parse: StepParse.json,
          output: StepOutput(
            list: const Locator(path: 'chapters', values: true),
            fields: {'url': const Locator(path: 'id')},
          ),
        ),
      ]);
      final result = await runRecordListPipeline(
        pipeline,
        const {'baseUrl': 'https://s.example'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) => serve('{"chapters":{"1":{"id":"c1"},"2":{"id":"c2"}}}'),
      );
      expect(result.records.map((r) => r['url']), ['c1', 'c2']);
    });

    test('a list step reads document-level meta (has-next presence)', () async {
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'baseUrl'),
          output: StepOutput(
            list: const Locator(selector: 'div.item'),
            fields: {'url': const Locator(selector: 'a', attr: 'href')},
            meta: {'hasNext': const Locator(selector: 'a.next', exists: true)},
          ),
        ),
      ]);
      Future<RecordList> run(String html) => runRecordListPipeline(
        pipeline,
        const {'baseUrl': 'https://s.example'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) => serve(html),
      );
      final withNext = await run(
        '<div class="item"><a href="/m">M</a></div><a class="next">»</a>',
      );
      expect(withNext.meta['hasNext'], '1');
      final noNext = await run('<div class="item"><a href="/m">M</a></div>');
      expect(noNext.meta['hasNext'], '');
    });

    test(
      'body pipeline returns the terminal body, threading captures',
      () async {
        // A two-step details-style pipeline: capture an id from the first page,
        // then fetch the real document; the runner hands back its raw body.
        final pipeline = Pipeline([
          Step(
            request: const StepRequest(base: 'mangaUrl'),
            capture: {'id': const Locator(selector: '#x', attr: 'data-id')},
          ),
          const Step(request: StepRequest(url: '{baseUrl}/real/{id}')),
        ]);
        final requested = <String>[];
        final body = await runBodyPipeline(
          pipeline,
          {'baseUrl': 'https://s.example', 'mangaUrl': 'https://s.example/m'},
          baseUrl: 'https://s.example',
          fetch:
              (
                url, {
                method = 'GET',
                body = '',
                headers = const {},
                document = true,
              }) {
                requested.add(url);
                if (url.endsWith('/m')) {
                  return serve('<div id="x" data-id="42"></div>');
                }
                return serve('<h1>Real</h1>');
              },
        );
        expect(requested, ['https://s.example/m', 'https://s.example/real/42']);
        expect(body, '<h1>Real</h1>');
      },
    );

    test('json pipeline threads a captured id into a second request', () async {
      // The API multi-step shape (multi-id cluster): a JSON response yields an
      // id that the next JSON request needs.
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'mangaUrl'),
          parse: StepParse.json,
          capture: {'id': const Locator(path: 'result.id')},
        ),
        const Step(
          request: StepRequest(url: '{baseUrl}/chapter/{id}'),
          parse: StepParse.json,
        ),
      ]);
      final requested = <String>[];
      final json = await runJsonPipeline(
        pipeline,
        {
          'baseUrl': 'https://api.example',
          'mangaUrl': 'https://api.example/manga/x',
        },
        baseUrl: 'https://api.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) {
              requested.add(url);
              if (url.endsWith('/manga/x')) {
                return serve('{"result":{"id":"777"}}');
              }
              return serve('{"pages":["a.jpg","b.jpg"]}');
            },
      );
      expect(requested, [
        'https://api.example/manga/x',
        'https://api.example/chapter/777',
      ]);
      expect((json! as Map)['pages'], ['a.jpg', 'b.jpg']);
    });

    test('a capture url-encodes its value for a later request path', () async {
      // The ZeistManga shape: a chapter-feed label with a space lifted from the
      // manga page must be path-encoded before it builds the feed URL.
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'mangaUrl'),
          capture: {
            'label': const Locator(
              selector: '#w',
              attr: 'data-label',
              encode: true,
            ),
          },
        ),
        const Step(
          request: StepRequest(url: '{baseUrl}/feeds/-/{label}'),
          parse: StepParse.json,
          output: StepOutput(
            list: Locator(path: 'entry'),
            fields: {'name': Locator(path: 'title')},
          ),
        ),
      ]);
      final requested = <String>[];
      final result = await runRecordListPipeline(
        pipeline,
        {'baseUrl': 'https://s.example', 'mangaUrl': 'https://s.example/m'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) {
              requested.add(url);
              if (url.endsWith('/m')) {
                return serve('<div id="w" data-label="BEN 10"></div>');
              }
              return serve('{"entry":[{"title":"c1"}]}');
            },
      );
      expect(requested[1], 'https://s.example/feeds/-/BEN%2010');
      expect(result.records.single['name'], 'c1');
    });
  });

  group('chapters pipeline desugars', () {
    test('plain config → one record step over the manga url', () {
      final p = chaptersPipeline(
        const ChaptersConfig(itemSelector: 'li.chapter'),
      );
      expect(p.steps, hasLength(1));
      final out = p.steps.single.output!;
      expect(out.list.selector, 'li.chapter');
      expect(out.fields.keys, containsAll(['url', 'name']));
    });

    test('two-phase id lookup → a capture step then a record step', () {
      final p = chaptersPipeline(
        const ChaptersConfig(
          itemSelector: 'li.wp-manga-chapter',
          request: RequestTransform(
            url: '/wp-admin/admin-ajax.php',
            method: 'POST',
            idSelector: '#manga-chapters-holder',
            idAttr: 'data-id',
            body: 'action=manga_get_chapters&manga={id}',
          ),
        ),
      );
      expect(p.steps, hasLength(2));
      expect(p.steps.first.capture['id']!.attr, 'data-id');
      expect(p.steps[1].request!.transform!.method, 'POST');
    });

    test('name field is omitted when its selector and attr are both empty', () {
      final p = chaptersPipeline(
        const ChaptersConfig(
          itemSelector: 'li',
          nameSelector: '',
          nameAttr: '',
        ),
      );
      expect(p.steps.single.output!.fields.containsKey('name'), isFalse);
    });
  });

  group('listing pipeline desugars', () {
    test(
      'cover chain → a fallback locator; POST carries the body template',
      () {
        final p = listingPipeline(
          ListingConfig(
            path: '/x',
            method: 'POST',
            itemSelector: 'div.item',
            cover: const [
              CoverSource(selector: 'img', attr: 'data-src'),
              CoverSource(selector: 'img', attr: 'src'),
            ],
            nextPageSelector: 'a.next',
          ),
        );
        final req = p.steps.single.request!;
        expect(req.method, 'POST');
        expect(req.body, '{listingBody}');
        final out = p.steps.single.output!;
        final cover = out.fields['cover']!;
        expect(cover.attr, 'data-src');
        expect(cover.fallbacks.single.attr, 'src');
        expect(out.meta['hasNext']!.exists, isTrue);
      },
    );

    test('GET listing sends no body and no listing headers', () {
      final p = listingPipeline(
        const ListingConfig(
          path: '/x',
          itemSelector: 'div.item',
          headers: {'X-Only-For-Post': '1'},
        ),
      );
      final req = p.steps.single.request!;
      expect(req.method, 'GET');
      expect(req.body, '');
      expect(req.headers, isEmpty);
    });
  });

  group('count-generate pages', () {
    test('a page count + URL template synthesize the page list', () async {
      // Readers that expose a count and a {n}-templated URL, no per-page tags.
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'chapterUrl'),
          output: StepOutput(
            count: const Locator(selector: '#reader', attr: 'data-pages'),
            value: const Locator(template: '{baseUrl}/ch/{chapterId}/{n}.jpg'),
          ),
        ),
      ]);
      final pages = await runFlatListPipeline(
        pipeline,
        {
          'baseUrl': 'https://s.example',
          'chapterUrl': 'https://s.example/ch/x',
          'chapterId': '42',
        },
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async => '<div id="reader" data-pages="3">reader</div>',
      );
      expect(pages, [
        'https://s.example/ch/42/1.jpg',
        'https://s.example/ch/42/2.jpg',
        'https://s.example/ch/42/3.jpg',
      ]);
    });

    test('`pad` zero-pads {n} to the width the host writes', () async {
      /* A host that names its files `p0001.jpg` will not answer `p1.jpg`, and
       * a reader whose page list exists *only* as a count plus a URL shape is
       * then unscrapable without a browser — which for a lazy-loading reader
       * means getting whatever was near the viewport rather than the chapter.
       * Found on a real source whose raw response carries all 91 page paths
       * while its rendered DOM holds six. */
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'chapterUrl'),
          output: StepOutput(
            count: const Locator(regex: r'"pageCount":(\d+)'),
            value: const Locator(template: '{baseUrl}/c/p{n}.jpg'),
            pad: 4,
          ),
        ),
      ]);
      final pages = await runFlatListPipeline(
        pipeline,
        const {
          'baseUrl': 'https://s.example',
          'chapterUrl': 'https://s.example/ch/x',
        },
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async => '<script>{"pageCount":3}</script>',
      );
      expect(pages, [
        'https://s.example/c/p0001.jpg',
        'https://s.example/c/p0002.jpg',
        'https://s.example/c/p0003.jpg',
      ]);
    });

    test('a number wider than `pad` is left alone, not truncated', () async {
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'chapterUrl'),
          output: StepOutput(
            count: const Locator(regex: r'"pageCount":(\d+)'),
            value: const Locator(template: '{baseUrl}/p{n}.jpg'),
            start: 999,
            pad: 2,
          ),
        ),
      ]);
      final pages = await runFlatListPipeline(
        pipeline,
        const {
          'baseUrl': 'https://s.example',
          'chapterUrl': 'https://s.example/ch/x',
        },
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async => '<script>{"pageCount":2}</script>',
      );
      expect(pages, [
        'https://s.example/p999.jpg',
        'https://s.example/p1000.jpg',
      ]);
    });

    test('no `pad` leaves every existing config untouched', () async {
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'chapterUrl'),
          output: StepOutput(
            count: const Locator(regex: r'"pageCount":(\d+)'),
            value: const Locator(template: '{baseUrl}/p{n}.jpg'),
          ),
        ),
      ]);
      final pages = await runFlatListPipeline(
        pipeline,
        const {
          'baseUrl': 'https://s.example',
          'chapterUrl': 'https://s.example/ch/x',
        },
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async => '<script>{"pageCount":2}</script>',
      );
      expect(pages, ['https://s.example/p1.jpg', 'https://s.example/p2.jpg']);
    });

    test('json count + 0-based start', () async {
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(url: '{baseUrl}/api'),
          parse: StepParse.json,
          output: StepOutput(
            count: const Locator(path: 'pages'),
            value: const Locator(template: '{baseUrl}/p/{n}.webp'),
            start: 0,
          ),
        ),
      ]);
      final pages = await runFlatListPipeline(
        pipeline,
        const {'baseUrl': 'https://s.example'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async => '{"pages":2}',
      );
      expect(pages, [
        'https://s.example/p/0.webp',
        'https://s.example/p/1.webp',
      ]);
    });
  });

  group('paginated flat list', () {
    test('hasNextMeta drives a flat-list pipeline across pages', () async {
      // Laravel-style paginators (confirmed live on a real source) don't
      // reliably expose a true last-page number, only a presence signal
      // (a `rel="next"` anchor) that another page follows.
      final pages = <String, String>{
        '1':
            '<img class="pic" src="/p/1.jpg"><img class="pic" src="/p/2.jpg">'
            '<a rel="next" href="?page=2"></a>',
        '2': '<img class="pic" src="/p/3.jpg">',
      };
      final requested = <String>[];
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(url: '{baseUrl}/album?page={page}'),
          output: StepOutput(
            list: const Locator(selector: 'img.pic'),
            value: const Locator(attr: 'src'),
            meta: {
              'hasNext': const Locator(selector: 'a[rel=next]', exists: true),
            },
            paginate: const Pagination(hasNextMeta: 'hasNext'),
          ),
        ),
      ]);
      final result = await runFlatListPipeline(
        pipeline,
        const {'baseUrl': 'https://s.example'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async {
              requested.add(url);
              final page = Uri.parse(url).queryParameters['page']!;
              return pages[page]!;
            },
      );
      expect(requested, [
        'https://s.example/album?page=1',
        'https://s.example/album?page=2',
      ]);
      expect(result, [
        'https://s.example/p/1.jpg',
        'https://s.example/p/2.jpg',
        'https://s.example/p/3.jpg',
      ]);
    });

    test('paginate stops at maxPages against a stuck flat list', () async {
      var calls = 0;
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(url: '{baseUrl}/album?page={page}'),
          output: StepOutput(
            list: const Locator(selector: 'img.pic'),
            value: const Locator(attr: 'src'),
            meta: {
              'hasNext': const Locator(selector: 'a[rel=next]', exists: true),
            },
            paginate: const Pagination(hasNextMeta: 'hasNext', maxPages: 3),
          ),
        ),
      ]);
      final result = await runFlatListPipeline(
        pipeline,
        const {'baseUrl': 'https://s.example'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async {
              calls++;
              return '<img class="pic" src="/p/x.jpg"><a rel="next" href="?page=2"></a>';
            },
      );
      expect(calls, 3);
      expect(result, hasLength(3));
    });
  });

  group('decrypt step', () {
    // Fixture generated with a throwaway encryptor matching decryptAesJson's
    // scheme exactly (OpenSSL EVP_BytesToKey/MD5, AES-256-CBC, PKCS7), so this
    // pins the real algorithm rather than a hand-waved shape. The double
    // jsonEncode (a JSON string wrapping a JSON array) mirrors what the real
    // site (a WP "chapter images protection" plugin) actually ships. See
    // sources-catalog.md's jinmangas writeup.
    const dataJson =
        '{"ct":"xbD8+9rQD6hho8UMnrLkSwvsoXOZq1AMkMXRT1Uxp5qwZ/RFY4v3gvk+LpNLOfcAF9KpQ24xFdbffMCVHYQPZcS0dzxRi7yOdEqD0DaZphN+3tTKIzNlsnyiMIDpmGb3",'
        '"iv":"6465666768696a6b6c6d6e6f70717273","s":"0102030405060708"}';
    const password = 'testnonce123';
    const urls = [
      'https://example.test/manga/x/1.webp',
      'https://example.test/manga/x/2.webp',
    ];

    test('decryptAesJson recovers the double-JSON-encoded plaintext', () {
      final plaintext = decryptAesJson(dataJson, password);
      expect(jsonDecode(jsonDecode(plaintext) as String), urls);
    });

    test('a wrong password yields empty rather than throwing', () {
      expect(
        decryptAesJson(dataJson, 'wrong'),
        isNot(equals(jsonEncode(urls))),
      );
      expect(() => decryptAesJson(dataJson, 'wrong'), returnsNormally);
    });

    test('malformed envelope JSON returns empty, not a throw', () {
      expect(decryptAesJson('not json', password), '');
      expect(decryptAesJson('{"ct":"","iv":"","s":""}', password), '');
    });

    test('a full pages pipeline: capture the envelope + password from HTML, '
        'decrypt, yield the URL list', () async {
      final pipeline = Pipeline.fromJson([
        {
          'request': {'url': '{chapterUrl}'},
          'parse': 'html',
          'capture': {
            'chapterData': {'regex': "chapter_data='(\\{.*?\\})';"},
            'nonce': {'regex': "nonce='([^']+)';"},
          },
        },
        {
          'decrypt': {'data': '{chapterData}', 'password': '{nonce}'},
          'parse': 'json',
          'yield': <String, dynamic>{},
        },
      ]);

      final pages = await runFlatListPipeline(
        pipeline,
        const {
          'baseUrl': 'https://jm.example',
          'chapterUrl': 'https://jm.example/manga/x/chapter-1/',
        },
        baseUrl: 'https://jm.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async {
              expect(url, 'https://jm.example/manga/x/chapter-1/');
              return "<script>var chapter_data='$dataJson';"
                  "var nonce='$password';</script>";
            },
      );

      expect(pages, urls);
    });
  });

  group('step trace', () {
    test('runWithTrace records each step request + captures', () async {
      final pipeline = Pipeline([
        Step(
          request: const StepRequest(base: 'mangaUrl'),
          capture: {'id': const Locator(selector: '#x', attr: 'data-id')},
        ),
        const Step(
          request: StepRequest(url: '{baseUrl}/real/{id}'),
          output: StepOutput(
            list: Locator(selector: 'li'),
            fields: {'url': Locator(selector: 'a', attr: 'href')},
          ),
        ),
      ]);
      final traces = <StepTrace>[];
      final result = await runWithTrace(
        traces.add,
        () => runRecordListPipeline(
          pipeline,
          {'baseUrl': 'https://s.example', 'mangaUrl': 'https://s.example/m'},
          baseUrl: 'https://s.example',
          fetch:
              (
                url, {
                method = 'GET',
                body = '',
                headers = const {},
                document = true,
              }) async => url.endsWith('/m')
              ? '<div id="x" data-id="9"></div>'
              : '<li><a href="/c1">C1</a></li>',
        ),
      );
      expect(result.records.single['url'], '/c1');
      expect(traces, hasLength(2));
      expect(traces[0].requestUrl, 'https://s.example/m');
      expect(traces[0].captured['id'], '9');
      expect(traces[0].terminal, isFalse);
      expect(traces[1].requestUrl, 'https://s.example/real/9');
      expect(traces[1].terminal, isTrue);
    });

    test('no sink installed → tracing is a silent no-op', () async {
      final pages = await runFlatListPipeline(
        Pipeline([
          Step(
            request: const StepRequest(base: 'chapterUrl'),
            output: StepOutput(
              list: const Locator(selector: 'img'),
              value: const Locator(attr: 'src'),
            ),
          ),
        ]),
        {'baseUrl': 'https://s.example', 'chapterUrl': 'https://s.example/c'},
        baseUrl: 'https://s.example',
        fetch:
            (
              url, {
              method = 'GET',
              body = '',
              headers = const {},
              document = true,
            }) async => '<img src="/p1.jpg">',
      );
      expect(pages, ['https://s.example/p1.jpg']);
    });
  });
}
