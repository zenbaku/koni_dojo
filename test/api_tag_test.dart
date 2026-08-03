import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// A minimal API config for exercising `tag` browsing; `manga.url`/`title`
/// read straight off each feed item.
Map<String, dynamic> _baseJson() => {
  'type': 'api',
  'id': 't',
  'name': 'T',
  'lang': 'en',
  'baseUrl': 'https://t.example',
  'apiUrl': 'https://t.example',
  'manga': {'url': 'id', 'title': 'title'},
  'popular': {'path': '/popular', 'items': 'data'},
  'chapters': {
    'path': '/feed',
    'items': 'data',
    'chapter': {'url': 'id'},
  },
  'pages': {'items': 'images', 'template': '{value}'},
};

http.Client _echoRequestedUrl(List<String> requested) =>
    MockClient((request) async {
      requested.add(request.url.toString());
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'm1', 'title': 'Manga One'},
          ],
        }),
        200,
      );
    });

void main() {
  test('hasTagListing is false without a tag config', () {
    final source = apiSource(ApiSourceConfig.fromJson(_baseJson()));
    expect(source.hasTagListing, isFalse);
    expect(source.tagCapabilities.multiple, isFalse);
    expect(source.tagCapabilities.exclusion, isFalse);
  });

  test('tag config survives a JSON round trip', () {
    final json = _baseJson();
    json['tag'] = {
      'path': '/tags/{query}',
      'items': 'data',
      'tagParam': 'tag',
      'tagExcludeParam': 'exclude',
      'tagJoin': ',',
    };
    final restored = ApiSourceConfig.fromJson(json);
    expect(restored.tag?.path, '/tags/{query}');
    expect(restored.tag?.tagParam, 'tag');
    expect(restored.tag?.tagExcludeParam, 'exclude');
    expect(restored.tag?.tagJoin, ',');
    expect(ApiSourceConfig.fromJson(restored.toJson()).tag?.tagParam, 'tag');
  });

  test(
    'tag {query} is path-segment escaped (%20), not query-string (+)',
    () async {
      final requested = <String>[];
      final json = _baseJson();
      json['tag'] = {'path': '/tags/{query}', 'items': 'data'};
      final source = apiSource(
        ApiSourceConfig.fromJson(json),
        client: _echoRequestedUrl(requested),
      );

      expect(source.hasTagListing, isTrue);
      await source.tag({'Sci-Fi (Hard)'}, 1);

      expect(requested.single, 'https://t.example/tags/Sci-Fi%20(Hard)');
    },
  );

  // No bundled API-dialect config exercises multi-tag/exclusion yet
  // (the reference config's tags already fit `filters`/`optionsFrom`):
  // this is a synthetic config proving the *mechanism* works, not a
  // live-verified site.
  group('multi-tag + exclusion (synthetic — not live-verified)', () {
    ApiSourceConfig multiTagConfig() {
      final json = _baseJson();
      json['tag'] = {
        'path': '/browse',
        'items': 'data',
        'tagParam': 'tag',
        'tagExcludeParam': 'exclude',
      };
      return ApiSourceConfig.fromJson(json);
    }

    test('tagCapabilities reflects both tagParam and tagExcludeParam', () {
      final source = apiSource(multiTagConfig());
      expect(source.tagCapabilities.multiple, isTrue);
      expect(source.tagCapabilities.exclusion, isTrue);
    });

    test('included values become repeated tagParam params, excluded '
        'become tagExcludeParam', () async {
      final requested = <String>[];
      final source = apiSource(
        multiTagConfig(),
        client: _echoRequestedUrl(requested),
      );

      await source.tag({'horror', 'romance'}, 1, excluded: {'ecchi'});

      final uri = Uri.parse(requested.single);
      expect(uri.path, '/browse');
      expect(uri.queryParametersAll['tag']?.toSet(), {'horror', 'romance'});
      expect(uri.queryParametersAll['exclude'], ['ecchi']);
    });
  });
}
