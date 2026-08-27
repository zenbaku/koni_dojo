import 'package:test/test.dart';

import '../tool/schema_lint.dart';

/// The build's schema gate: what `docs/source-config.schema.json` says a
/// config may contain, checked against what one actually does.
///
/// Its whole reason to exist is the class of mistake the *engine* cannot see.
/// A `fromJson` never errors on a key it doesn't know — it simply never reads
/// it — so a misspelled selector key parses, round-trips, ships, and matches
/// nothing on a real page. Only the schema, which forbids unknown properties
/// at every level, turns that into a failed build.
void main() {
  // Compiled once, like the build does: it walks the whole schema document.
  final schema = ExtensionSchema.load('docs/source-config.schema.json');

  Map<String, dynamic> htmlExtension({
    Map<String, dynamic> extra = const {},
    Map<String, dynamic> popularExtra = const {},
  }) => {
    'name': 'Example',
    'pkg': 'app.example.x',
    'version': 'abcdef0123456789',
    'lang': 'en',
    'sources': [
      {
        'id': 'x',
        'name': 'Example',
        'baseUrl': 'https://example.test',
        'popular': {
          'path': '/popular?page={page}',
          'itemSelector': 'div.item',
          'titleSelector': 'a',
          'urlSelector': 'a',
          ...popularExtra,
        },
        'chapters': {'itemSelector': 'li', 'nameSelector': 'a'},
        'pages': {'imageSelector': 'img', 'imageAttr': 'src'},
        ...extra,
      },
    ],
  };

  Map<String, dynamic> apiExtension({Map<String, dynamic> extra = const {}}) =>
      {
        'name': 'Example API',
        'pkg': 'app.example.api',
        'version': 'abcdef0123456789',
        'lang': 'en',
        'sources': [
          {
            'type': 'api',
            'id': 'xapi',
            'name': 'Example API',
            'baseUrl': 'https://example.test',
            'apiUrl': 'https://api.example.test',
            'manga': {'url': 'slug'},
            'popular': {'path': '/query?page={page}', 'items': 'data'},
            'chapters': {'path': '/chapters', 'items': 'data'},
            'pages': {'path': '/pages', 'items': 'data'},
            ...extra,
          },
        ],
      };

  test('an ordinary config of either dialect has no issues', () {
    expect(lintExtensionSchema(htmlExtension(), 'x.json', schema), isEmpty);
    expect(lintExtensionSchema(apiExtension(), 'x.json', schema), isEmpty);
  });

  test('an unknown top-level key on a source is named', () {
    final issues = lintExtensionSchema(
      htmlExtension(extra: {'webviewOpps': <String>[]}),
      'x.json',
      schema,
    );
    expect(issues, isNotEmpty);
    expect(issues.join('\n'), contains('webviewOpps'));
  });

  test('an unknown key *inside* an operation block is named', () {
    /* The one the engine is blind to and the reason this gate exists: a
     * listing block with a misspelled selector key parses, ships, and returns
     * an empty catalogue with nothing anywhere to say why. */
    final issues = lintExtensionSchema(
      htmlExtension(popularExtra: {'itemSelctor': 'div.item'}),
      'x.json',
      schema,
    );
    expect(issues, isNotEmpty);
    expect(issues.join('\n'), contains('itemSelctor'));
    expect(
      issues.join('\n'),
      contains('popular'),
      reason: 'the message must say which block, not just which key',
    );
  });

  test('a block one dialect has and the other does not is named', () {
    /* `latest` is a real listing on the HTML dialect and nothing at all on the
     * API one, where it is read by nobody. Both are legal JSON and both parse;
     * only the schema knows which one means anything. */
    expect(
      lintExtensionSchema(
        htmlExtension(
          extra: {
            'latest': <String, dynamic>{'path': '/latest'},
          },
        ),
        'x.json',
        schema,
      ),
      isEmpty,
    );
    final issues = lintExtensionSchema(
      apiExtension(
        extra: {
          'latest': <String, dynamic>{'path': '/latest'},
        },
      ),
      'x.json',
      schema,
    );
    expect(issues, isNotEmpty);
    expect(issues.join('\n'), contains('latest'));
  });

  test(
    'a failure names the source it is in, and says something actionable',
    () {
      /* The top-level schema reaches a source through a `oneOf`, and a `oneOf`
     * that fails reports only that no branch matched — "violated No element",
     * which tells an author nothing at all. Re-validating against the dialect
     * the source declares is what recovers the real complaint. */
      final ext = htmlExtension();
      (ext['sources'] as List).add(
        (apiExtension(extra: {'nonsense': true})['sources'] as List).single,
      );
      final issues = lintExtensionSchema(ext, 'x.json', schema);
      expect(issues, hasLength(1));
      expect(issues.single, startsWith('sources[1]'));
      expect(issues.single, contains('nonsense'));
      expect(
        issues.single.toLowerCase(),
        isNot(contains('no element')),
        reason: 'the oneOf swallowed the real reason',
      );
    },
  );

  test('a problem in the envelope around the sources is reported too', () {
    final ext = htmlExtension()..remove('pkg');
    expect(lintExtensionSchema(ext, 'x.json', schema), isNotEmpty);
  });
}
