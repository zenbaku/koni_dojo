import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// A minimal API config whose chapter feed pages `/feed?offset={offset}` two
/// items at a time. [maxItems] caps a totalless runaway.
ApiSourceConfig _config({int maxItems = 1000}) => ApiSourceConfig.fromJson({
  'type': 'api',
  'id': 't',
  'name': 'T',
  'lang': 'en',
  'baseUrl': 'https://t.example',
  'apiUrl': 'https://t.example',
  'popular': {'path': '/popular', 'items': 'data'},
  'chapters': {
    'path': '/feed?offset={offset}',
    'pageSize': 2,
    'maxItems': maxItems,
    'items': 'data',
    'totalPath': 'total',
    'chapter': {'url': 'id', 'number': 'chapter'},
  },
  'pages': {'items': 'images', 'template': '{value}'},
});

/// Serves a chapter feed of [count] chapters (numbered 0..count-1, ascending),
/// two per page, reporting [total] (which may be an int, a numeric string, or
/// null to omit the field entirely).
http.Client _feed({required int count, required Object? total}) => MockClient((
  req,
) async {
  final offset = int.tryParse(req.url.queryParameters['offset'] ?? '0') ?? 0;
  final slice = [
    for (var i = offset; i < offset + 2 && i < count; i++)
      {'id': 'ch$i', 'chapter': '$i'},
  ];
  return http.Response(
    jsonEncode({'data': slice, if (total != null) 'total': total}),
    200,
  );
});

void main() {
  test('a numeric total pages through every chapter', () async {
    final source = apiSource(_config(), client: _feed(count: 5, total: 5));
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.map((c) => c.number), [0, 1, 2, 3, 4]);
  });

  test(
    'a string-valued total no longer cuts the feed off after page one',
    () async {
      // Regression: `total is num` was false for a quoted total, collapsing it to
      // 0 and breaking after the first page.
      final source = apiSource(_config(), client: _feed(count: 5, total: '5'));
      final chapters = await source.chapters(const MangaRef('m'));
      expect(chapters.map((c) => c.number), [0, 1, 2, 3, 4]);
    },
  );

  test(
    'a reported total is honoured past maxItems (newest chapters kept)',
    () async {
      // Regression: an ascending feed truncated at maxItems dropped its NEWEST
      // chapters (they sit on the last pages). With a total reported, page all of
      // it despite the small cap.
      final source = apiSource(
        _config(maxItems: 3),
        client: _feed(count: 5, total: 5),
      );
      final chapters = await source.chapters(const MangaRef('m'));
      expect(chapters.map((c) => c.number), [0, 1, 2, 3, 4]);
      expect(chapters.last.number, 4, reason: 'the newest chapter was dropped');
    },
  );

  test('a totalless feed pages until a short (last) page', () async {
    final source = apiSource(_config(), client: _feed(count: 5, total: null));
    final chapters = await source.chapters(const MangaRef('m'));
    expect(chapters.map((c) => c.number), [0, 1, 2, 3, 4]);
  });
}
