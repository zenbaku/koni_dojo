import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// A minimal API config whose chapter feed's `locked` path points at
/// whichever field the test wants to check truthiness against. Mirrors a
/// heancms-style feed where a chapter's payment-gate shows up as either a
/// boolean flag or a price.
ApiSourceConfig _config(String lockedPath) => ApiSourceConfig.fromJson({
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
    'chapter': {'url': 'id', 'number': 'chapter', 'locked': lockedPath},
  },
  'pages': {'items': 'images', 'template': '{value}'},
});

http.Client _feed(List<Map<String, Object?>> data) =>
    MockClient((req) async => http.Response(jsonEncode({'data': data}), 200));

void main() {
  test('a boolean flag (e.g. "premium": true) marks a chapter locked', () async {
    final source = apiSource(
      _config('premium'),
      client: _feed([
        {'id': 'ch1', 'chapter': '1', 'premium': false},
        {'id': 'ch2', 'chapter': '2', 'premium': true},
      ]),
    );
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.map((c) => c.locked).toList(), [false, true]);
  });

  test('a price field is truthy above zero, falsy at zero', () async {
    final source = apiSource(
      _config('price'),
      client: _feed([
        {'id': 'ch1', 'chapter': '1', 'price': 0},
        {'id': 'ch2', 'chapter': '2', 'price': 99},
      ]),
    );
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.map((c) => c.locked).toList(), [false, true]);
  });

  test('a missing field at the path reads as unlocked, not an error', () async {
    final source = apiSource(
      _config('price'),
      client: _feed([
        {'id': 'ch1', 'chapter': '1'},
      ]),
    );
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.single.locked, isFalse);
  });

  test('an empty locked path (the default) never flags a chapter', () async {
    final source = apiSource(
      _config(''),
      client: _feed([
        {'id': 'ch1', 'chapter': '1', 'premium': true, 'price': 99},
      ]),
    );
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.single.locked, isFalse);
  });

  test('ApiChapterSpec.locked survives a JSON round trip', () {
    final restored = ApiSourceConfig.fromJson(
      _config('premium').toJson(),
    );
    expect(restored.chapters.chapter.locked, 'premium');
  });
}
