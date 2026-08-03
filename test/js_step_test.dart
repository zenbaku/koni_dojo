import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// A stand-in for QuickJS. It doesn't run the site's JS; it reads the `$` args
/// the engine injected and derives a deterministic answer from them, which is
/// enough to prove the whole data path: the regex-captured `seed` reaches
/// the runtime as an arg, and the returned answer threads onward into the POST.
class _FakeJs implements JsRunner {
  String? lastCode;

  @override
  Future<String> eval(String code) async {
    lastCode = code;
    final m = RegExp(r'const \$ = (\{.*\});', dotAll: true).firstMatch(code);
    final args = jsonDecode(m!.group(1)!) as Map<String, dynamic>;
    final seed = String.fromCharCodes(
      (args['seed'] as String).split(',').map((s) => int.parse(s.trim())),
    );
    return 'answer-for-$seed'; // seed = "hi" → "answer-for-hi"
  }
}

/// A fictional JS-gated reader's flow expressed as an explicit `steps:`
/// pages pipeline: series → challenge → JS solve → token → reader →
/// generated image URLs. See `docs/js-step-proposal.md`'s worked example.
SourceConfig _zetaPages() => SourceConfig.fromJson({
  'id': 'zetatest',
  'name': 'ZetaTest',
  'lang': 'es',
  'baseUrl': 'https://zeta.test',
  'js': true,
  'popular': {'path': '/top', 'itemSelector': 'div.card'},
  'chapters': {'itemSelector': 'div.card'},
  'pages': {
    'steps': [
      // Split the composite chapter ref `chapterId#seriesId` (regex-from-var).
      {
        'capture': {
          'chapterId': {'regex': r'^([^#]*)', 'from': 'chapterId'},
          'seriesId': {'regex': r'([^#]*)$', 'from': 'chapterId'},
        },
      },
      // series page → seed char-codes (regex scalar capture).
      {
        'request': {'url': '/series.php?id={seriesId}'},
        'capture': {
          'seed': {'regex': r'fromCharCode\(([\d,]+)\)'},
        },
      },
      // challenge JSON.
      {
        'request': {
          'url': '/ajax/get_challenge.php?chapter={chapterId}&s={seriesId}',
          'headers': {'X-Requested-With': 'XMLHttpRequest'},
        },
        'parse': 'json',
        'capture': {
          'challengeJs': {'path': 'challenge_js'},
          'challengeId': {'path': 'challenge_id'},
        },
      },
      // JS step → answer. The fetched script is a function *body* (it uses
      // a top-level `return`), so it must run via `new Function`, never a
      // bare `eval`: QuickJS rejects top-level return in program text.
      {
        'js': {
          'code': r'(new Function($.challengeJs))()',
          'args': {'seed': '{seed}', 'challengeJs': '{challengeJs}'},
          'capture': 'answer',
        },
      },
      // POST answer → reader token.
      {
        'request': {
          'url': '/ajax/get_reader_token.php',
          'method': 'POST',
          'body':
              'chapter={chapterId}&challenge_id={challengeId}&answer={answer}',
        },
        'parse': 'json',
        'capture': {
          'token': {'path': 'token', 'encode': true},
          'realChapter': {'path': 'chapterId'},
        },
      },
      // reader → totalPages (count regex), generate image URLs.
      {
        'request': {
          'url': '/reader_v2.php?chapter={realChapter}&token={token}&page=1',
        },
        'yield': {
          'count': {'regex': r'totalPages:\s*(\d+)'},
          'value': {
            'template':
                '{baseUrl}/image-proxy-v2.php?chapter={realChapter}&page={n}&token={token}&context=reader',
          },
        },
      },
    ],
  },
});

http.Client _zetaServer({List<String>? postBodies}) => MockClient((req) async {
  final path = '${req.url.path}?${req.url.query}'.replaceAll(
    RegExp(r'\?$'),
    '',
  );
  if (req.method == 'POST' && req.url.path == '/ajax/get_reader_token.php') {
    postBodies?.add(req.body);
    return http.Response(
      jsonEncode({'success': true, 'token': 'TOK/99', 'chapterId': 'REAL7'}),
      200,
    );
  }
  return switch (path) {
    '/series.php?id=SER9' => http.Response(
      '<script>seed.value = String.fromCharCode(104,105)</script>',
      200,
    ),
    '/ajax/get_challenge.php?chapter=CH1&s=SER9' => http.Response(
      jsonEncode({
        'success': true,
        'challenge_js': "return 'x';",
        'challenge_id': 'CID42',
      }),
      200,
    ),
    '/reader_v2.php?chapter=REAL7&token=TOK%2F99&page=1' => http.Response(
      '<script>var totalPages: 3;</script>',
      200,
    ),
    _ => http.Response('not found: $path', 404),
  };
});

void main() {
  test('JS step drives a JS-gated reader flow end to end', () async {
    final posts = <String>[];
    final source = htmlSource(
      _zetaPages(),
      client: _zetaServer(postBodies: posts),
      jsRunner: _FakeJs(),
    );

    final pages = await source.pages(ChapterRef('CH1#SER9'));

    // Three image URLs, generated from the reader's totalPages count, each
    // carrying the real chapter and the URL-encoded token.
    expect(pages, hasLength(3));
    expect(
      pages.first.url.toString(),
      'https://zeta.test/image-proxy-v2.php?chapter=REAL7&page=1&token=TOK%2F99&context=reader',
    );
    expect(pages.last.url.toString(), contains('page=3'));

    // The JS answer (derived from the regex-captured seed = "hi") threaded
    // into the token POST: proof the whole capture chain flows through the
    // JS step.
    expect(posts.single, contains('answer=answer-for-hi'));
    expect(posts.single, contains('challenge_id=CID42'));
  });

  test('a JS step with no runtime throws JsUnavailable', () async {
    final source = htmlSource(_zetaPages(), client: _zetaServer());
    await expectLater(
      source.pages(ChapterRef('CH1#SER9')),
      throwsA(isA<JsUnavailable>()),
    );
  });

  test(
    'jsonHtml chapters lift HTML from a JSON envelope, packing the id',
    () async {
      final config = SourceConfig.fromJson({
        'id': 'zetatest',
        'name': 'ZetaTest',
        'lang': 'es',
        'baseUrl': 'https://zeta.test',
        'popular': {'path': '/top', 'itemSelector': 'div.card'},
        'chapters': {
          'steps': [
            {
              'request': {
                'url': '/ajax/load_chapters.php?series_id={mangaUrl}',
                'headers': {'X-Requested-With': 'XMLHttpRequest'},
              },
              'parse': 'jsonHtml',
              'htmlFrom': 'html',
              'yield': {
                'list': {'selector': 'div.comic-card'},
                'fields': {
                  // Pack the series id after '#' so pages() can recover it.
                  'url': {
                    'selector': 'a[data-chapter]',
                    'attr': 'data-chapter',
                    'template': '{value}#{mangaUrl}',
                  },
                  'name': {'selector': 'h3'},
                },
              },
            },
          ],
        },
        'pages': {'imageSelector': 'img'},
      });
      final server = MockClient((req) async {
        if (req.url.path == '/ajax/load_chapters.php') {
          return http.Response(
            jsonEncode({
              'html':
                  '<div class="comic-card"><a data-chapter="CH1"></a>'
                  '<h3>Chapter 1</h3></div>'
                  '<div class="comic-card"><a data-chapter="CH2"></a>'
                  '<h3>Chapter 2</h3></div>',
              'currentPage': 1,
              'totalPages': 1,
            }),
            200,
          );
        }
        return http.Response('nope', 404);
      });
      final source = htmlSource(config, client: server);

      final chapters = await source.chapters(MangaRef('SER9'));
      expect(chapters, hasLength(2));
      // Each chapter url carries the packed series id (extracted attr + var).
      expect(chapters.first.url, contains('CH'));
      expect(chapters.first.url, contains('#'));
      expect(
        chapters.map((c) => c.name),
        containsAll(['Chapter 1', 'Chapter 2']),
      );
    },
  );

  test('config with a js step survives a JSON round trip', () {
    final restored = SourceConfig.fromJson(_zetaPages().toJson());
    final steps = restored.pages.steps!.steps;
    final jsStep = steps.firstWhere((s) => s.js != null);
    expect(jsStep.js!.code, r'(new Function($.challengeJs))()');
    expect(jsStep.js!.args['seed'], '{seed}');
    expect(jsStep.js!.capture, 'answer');
  });
}
