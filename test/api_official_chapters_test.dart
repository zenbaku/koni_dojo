import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// A minimal API config whose chapter feed's `official` path points at
/// whichever field the test wants to check truthiness against. Mirrors an
/// API that flags a licensed translation with a boolean field.
ApiSourceConfig _config(String officialPath) => ApiSourceConfig.fromJson({
  'type': 'api',
  'id': 't',
  'name': 'T',
  'lang': 'en',
  'baseUrl': 'https://t.example',
  'apiUrl': 'https://t.example',
  'popular': {'path': '/popular', 'items': 'data'},
  'chapters': {
    'path': '/feed',
    'items': 'data',
    'chapter': {'url': 'id', 'number': 'chapter', 'official': officialPath},
  },
  'pages': {'items': 'images', 'template': '{value}'},
});

http.Client _feed(List<Map<String, Object?>> data) =>
    MockClient((req) async => http.Response(jsonEncode({'data': data}), 200));

void main() {
  test(
    'a boolean flag (e.g. "isOfficial": true) marks a chapter official',
    () async {
      final source = apiSource(
        _config('isOfficial'),
        client: _feed([
          {'id': 'ch1', 'chapter': '1', 'isOfficial': false},
          {'id': 'ch2', 'chapter': '2', 'isOfficial': true},
        ]),
      );
      final chapters = await source.chapters(const MangaRef('m'));
      expect(chapters.map((c) => c.official).toList(), [false, true]);
    },
  );

  test('a missing field at the path reads as unofficial, not an error', () async {
    final source = apiSource(
      _config('isOfficial'),
      client: _feed([
        {'id': 'ch1', 'chapter': '1'},
      ]),
    );
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.single.official, isFalse);
  });

  test('an empty official path (the default) never flags a chapter', () async {
    final source = apiSource(
      _config(''),
      client: _feed([
        {'id': 'ch1', 'chapter': '1', 'isOfficial': true},
      ]),
    );
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.single.official, isFalse);
  });

  test('ApiChapterSpec.official survives a JSON round trip', () {
    final restored = ApiSourceConfig.fromJson(_config('isOfficial').toJson());
    expect(restored.chapters.chapter.official, 'isOfficial');
  });
}
