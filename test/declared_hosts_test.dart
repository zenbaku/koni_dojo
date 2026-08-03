import 'package:test/test.dart';
import 'package:koni_dojo/koni_dojo.dart';

SourceConfig _htmlConfig({
  RequestTransform? chaptersRequest,
  Pipeline? pagesSteps,
  List<FilterConfig> filters = const [],
}) => SourceConfig(
  id: 'example',
  name: 'Example',
  lang: 'en',
  baseUrl: 'https://example.com',
  popular: const ListingConfig(itemSelector: 'div.item'),
  chapters: ChaptersConfig(request: chaptersRequest, itemSelector: 'li'),
  pages: PagesConfig(steps: pagesSteps, imageSelector: 'img'),
  filters: filters,
);

ApiSourceConfig _apiConfig({Pipeline? chaptersSteps}) => ApiSourceConfig(
  id: 'example-api',
  name: 'Example API',
  lang: 'en',
  baseUrl: 'https://example.com',
  apiUrl: 'https://api.example.com',
  popular: const ApiListingConfig(path: '/popular'),
  chapters: ApiChaptersConfig(path: '/chapters', steps: chaptersSteps),
  pages: const ApiPagesConfig(path: '/pages'),
);

void main() {
  group('HTML dialect', () {
    test('a plain config with no absolute overrides declares only baseUrl', () {
      expect(declaredHosts(_htmlConfig()), {'example.com'});
    });

    test('a relative RequestTransform.url does not add a host', () {
      final config = _htmlConfig(
        chaptersRequest: const RequestTransform(url: '/ajax/chapters.php'),
      );
      expect(declaredHosts(config), {'example.com'});
    });

    test('an absolute RequestTransform.url adds its host', () {
      final config = _htmlConfig(
        chaptersRequest: const RequestTransform(
          url: 'https://ajax.example.com/admin-ajax.php',
        ),
      );
      expect(declaredHosts(config), {'example.com', 'ajax.example.com'});
    });

    test('an absolute StepRequest.url inside pages steps adds its host', () {
      final config = _htmlConfig(
        pagesSteps: Pipeline.fromJson([
          {
            'request': {'url': 'https://cdn.other-host.com/reader'},
            'yield': {
              'list': {'selector': 'img'},
              'value': {'attr': 'src'},
            },
          },
        ]),
      );
      expect(declaredHosts(config), {'example.com', 'cdn.other-host.com'});
    });

    test('an absolute filter optionsFrom.path adds its host', () {
      final config = _htmlConfig(
        filters: [
          FilterConfig(
            id: 'genre',
            name: 'Genre',
            param: 'genre',
            optionsFrom: const OptionsFromConfig(
              path: 'https://tags.example.net/list',
              itemSelector: 'option',
            ),
          ),
        ],
      );
      expect(declaredHosts(config), {'example.com', 'tags.example.net'});
    });
  });

  group('API dialect', () {
    test('declares both baseUrl and apiUrl when they differ', () {
      expect(declaredHosts(_apiConfig()), {'example.com', 'api.example.com'});
    });

    test('an absolute StepRequest.url inside chapters steps adds its host', () {
      final config = _apiConfig(
        chaptersSteps: Pipeline.fromJson([
          {
            'request': {'url': 'https://other-api.example.org/feed'},
            'parse': 'json',
            'yield': {
              'list': {'path': 'data'},
              'value': {'path': 'id'},
            },
          },
        ]),
      );
      expect(declaredHosts(config), {
        'example.com',
        'api.example.com',
        'other-api.example.org',
      });
    });
  });
}
