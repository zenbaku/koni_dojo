import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:koni_dojo/koni_dojo.dart';

/// Reads docs/source-config.schema.json: the same authoritative doc a
/// config author reads, checked here against what the models actually
/// produce rather than trusted to have been kept in sync by hand.
Map<String, dynamic> _schema() =>
    jsonDecode(File('docs/source-config.schema.json').readAsStringSync())
        as Map<String, dynamic>;

Set<String> _defProperties(Map<String, dynamic> schema, String defName) {
  final defs = schema[r'$defs'] as Map<String, dynamic>;
  final def = defs[defName] as Map<String, dynamic>;
  return (def['properties'] as Map<String, dynamic>).keys.toSet();
}

/// Fails with the offending keys listed, not just a bare boolean: a
/// mismatch here means either a Dart field shipped with no matching schema
/// entry (add one to docs/source-config.schema.json) or a schema entry with
/// no matching field left behind after a rename/removal (delete it there).
void _expectKeysDeclared(Set<String> actual, Set<String> declared, String label) {
  final missing = actual.difference(declared);
  expect(
    missing,
    isEmpty,
    reason:
        '$label produced keys not declared in the schema: $missing — update '
        'docs/source-config.schema.json (bump x-engineVersion too).',
  );
  /* And the other way, which is the direction that actually failed: the
   * fixtures below are hand-written, so a field nobody remembered to set is a
   * field this test never sees — `imageRateLimit` shipped in a published config
   * the schema rejected (`additionalProperties: false`) with this suite green.
   * Requiring every declared property to be *exercised* is what keeps the
   * fixtures honest: a new schema entry fails here until something sets it, and
   * a config author's editor stops disagreeing with the engine. */
  final unexercised = declared.difference(actual);
  expect(
    unexercised,
    isEmpty,
    reason:
        'the schema declares properties $label never produced: $unexercised — '
        'either the field is gone (delete it from the schema) or this test\'s '
        'fixture does not set it, in which case nothing is checking that the '
        'schema and the model agree about it.',
  );
}

void main() {
  final schema = _schema();

  test(
    'SourceConfig.toJson() keys are all declared in the schema\'s '
    'sourceConfig properties',
    () {
      final config = SourceConfig(
        id: 'x',
        name: 'X',
        lang: 'en',
        baseUrl: 'https://x.example',
        icon: 'data:image/png;base64,',
        webview: true,
        // Narrowed, and disagreeing with `webview`, because `toJson` omits
        // both when they say nothing new — a fixture at the defaults would
        // exercise neither.
        webviewOps: {SourceOp.chapters},
        challengesPlainClients: false,
        warmImageByUrl: true,
        warmImageViaImgTag: true,
        loginUrl: 'https://x.example/login',
        localStorageSeed: {'a': true},
        localStoragePreferences: [
          LocalStoragePreferenceConfig(
            id: 'p',
            label: 'P',
            seedKey: 'a',
            path: ['b'],
          ),
        ],
        js: true,
        headers: {'Referer': 'https://x.example/'},
        rateLimit: RateLimitConfig(requests: 1, perMs: 1000),
        imageRateLimit: RateLimitConfig(requests: 3, perMs: 1000),
        popular: ListingConfig(itemSelector: '.item'),
        latest: ListingConfig(itemSelector: '.item'),
        search: ListingConfig(itemSelector: '.item'),
        tag: ListingConfig(itemSelector: '.item'),
        details: DetailsConfig(titleSelector: 'h1'),
        chapters: ChaptersConfig(itemSelector: '.chapter'),
        pages: PagesConfig(imageSelector: 'img'),
        filters: [FilterConfig(id: 'f', name: 'F', param: 'f')],
      );
      _expectKeysDeclared(
        config.toJson().keys.toSet(),
        _defProperties(schema, 'sourceConfig'),
        'SourceConfig.toJson()',
      );
    },
  );

  test(
    'ApiSourceConfig.toJson() keys are all declared in the schema\'s '
    'apiSourceConfig properties',
    () {
      const config = ApiSourceConfig(
        id: 'x',
        name: 'X',
        lang: 'en',
        baseUrl: 'https://x.example',
        apiUrl: 'https://api.x.example',
        icon: 'data:image/png;base64,',
        headers: {'Referer': 'https://x.example/'},
        imageHeaders: {'Referer': 'https://x.example/'},
        rateLimit: RateLimitConfig(requests: 1, perMs: 1000),
        imageRateLimit: RateLimitConfig(requests: 3, perMs: 1000),
        popular: ApiListingConfig(path: '/popular'),
        search: ApiListingConfig(path: '/search'),
        tag: ApiListingConfig(path: '/tag'),
        details: ApiDetailsConfig(),
        chapters: ApiChaptersConfig(path: '/chapters'),
        pages: ApiPagesConfig(path: '/pages'),
        filters: [FilterConfig(id: 'f', name: 'F', param: 'f')],
      );
      _expectKeysDeclared(
        config.toJson().keys.toSet(),
        _defProperties(schema, 'apiSourceConfig'),
        'ApiSourceConfig.toJson()',
      );
    },
  );

  test(
    'ExtensionInfo.toJson() keys are all declared in the schema\'s '
    'top-level properties',
    () {
      final info = ExtensionInfo(
        name: 'X',
        pkg: 'app.example.x',
        version: 'abc123',
        lang: 'en',
        nsfw: true,
        sources: const [],
        updatedAt: '2026-01-01',
      );
      _expectKeysDeclared(
        info.toJson().keys.toSet(),
        (schema['properties'] as Map<String, dynamic>).keys.toSet(),
        'ExtensionInfo.toJson()',
      );
    },
  );

  test(
    'FilterConfig.toJson() keys are all declared in the schema\'s filter '
    'properties',
    () {
      const filter = FilterConfig(
        id: 'f',
        name: 'F',
        param: 'f',
        excludeParam: 'f_exclude',
        join: ',',
        options: [FilterOptionConfig(value: 'v', label: 'V')],
        optionsFrom: OptionsFromConfig(path: '/opts'),
      );
      _expectKeysDeclared(
        filter.toJson().keys.toSet(),
        _defProperties(schema, 'filter'),
        'FilterConfig.toJson()',
      );
    },
  );
}
