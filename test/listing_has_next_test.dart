// How a plain listing decides whether another page follows.
//
// Three shapes, because sites answer three ways — and the third exists for the
// site that answers by not answering: pagination is infinite scroll, so there
// is no next-page control in the markup at all, while `?page=N` works
// server-side. Without it every such listing silently stops at page one, which
// reads as "no more results" rather than "nothing here can ask".
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

String _grid(int n, {bool withNextButton = false}) =>
    '''
<html><body>
  <div class="list">
    ${List.generate(n, (i) => '<div class="item"><a href="/s/\$i">T\$i</a></div>').join()}
  </div>
  ${withNextButton ? '<a class="next" href="?page=2">Next</a>' : ''}
</body></html>
''';

Source build({
  int pageSize = 0,
  String nextPageSelector = '',
  required int itemsPerPage,
  bool withNextButton = false,
}) => htmlSource(
  SourceConfig.fromJson({
    'id': 'f',
    'name': 'F',
    'baseUrl': 'https://example.test',
    'popular': {
      'path': '/list?page={page}',
      'itemSelector': '.item',
      'titleSelector': 'a',
      'urlSelector': 'a',
      'urlAttr': 'href',
      if (pageSize > 0) 'pageSize': pageSize,
      if (nextPageSelector.isNotEmpty) 'nextPageSelector': nextPageSelector,
    },
    'chapters': {'itemSelector': 'li'},
    'pages': {'imageSelector': 'img'},
  }),
  client: MockClient(
    (_) async =>
        http.Response(_grid(itemsPerPage, withNextButton: withNextButton), 200),
  ),
);

void main() {
  test('a full page means another probably follows', () async {
    final page = await build(pageSize: 24, itemsPerPage: 24).popular(1);
    expect(page.items, hasLength(24));
    expect(page.hasNextPage, isTrue);
  });

  test('a short page ends it, so the walk terminates', () async {
    final page = await build(pageSize: 24, itemsPerPage: 9).popular(1);
    expect(page.hasNextPage, isFalse);
  });

  test('an empty page ends it too', () async {
    final page = await build(pageSize: 24, itemsPerPage: 0).popular(1);
    expect(page.items, isEmpty);
    expect(page.hasNextPage, isFalse);
  });

  test('without `pageSize` nothing is inferred', () async {
    // Opt-in: a config that never declared a page size has not told us what
    // "full" means, and guessing from whatever the first page returned would
    // paginate forever on a site with none.
    final page = await build(itemsPerPage: 24).popular(1);
    expect(page.hasNextPage, isFalse);
  });

  test('a real next-page control still decides, full page or not', () async {
    /* The guard that matters. A site *with* a next-page button has already
     * answered the question, and its last page is allowed to be exactly full —
     * inferring from fullness there would paginate past the end forever. */
    final ended = await build(
      pageSize: 24,
      nextPageSelector: 'a.next',
      itemsPerPage: 24,
      withNextButton: false,
    ).popular(1);
    expect(
      ended.hasNextPage,
      isFalse,
      reason: 'a full last page overrode the site saying there is no next',
    );

    final more = await build(
      pageSize: 24,
      nextPageSelector: 'a.next',
      itemsPerPage: 24,
      withNextButton: true,
    ).popular(1);
    expect(more.hasNextPage, isTrue);
  });
}
