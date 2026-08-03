import 'package:test/test.dart';
import 'package:koni_dojo/src/json_path.dart';

void main() {
  final doc = {
    'data': [
      {
        'id': 'm-1',
        'attributes': {
          'title': {'ja': 'タイトル', 'en': 'Title'},
          'tags': [
            {
              'attributes': {
                'name': {'en': 'Horror'},
              },
            },
          ],
        },
        'relationships': [
          {
            'type': 'author',
            'attributes': {'name': 'Mangaka'},
          },
          {
            'type': 'cover_art',
            'attributes': {'fileName': 'cover.jpg'},
          },
        ],
      },
    ],
    'total': 42,
  };

  test('reads nested keys, indexes and key=value list filters', () {
    expect(readJsonPath(doc, 'total'), 42);
    expect(readJsonPath(doc, 'data[0].id'), 'm-1');
    expect(readJsonPath(doc, 'data[0].attributes.title.en'), 'Title');
    expect(
      readJsonPath(doc, 'data[0].relationships[type=author].attributes.name'),
      'Mangaka',
    );
    expect(
      readJsonPath(
        doc,
        'data[0].relationships[type=cover_art].attributes.fileName',
      ),
      'cover.jpg',
    );
  });

  test('star takes the first map value or list element', () {
    expect(readJsonPath(doc, 'data[0].attributes.title.*'), 'タイトル');
    expect(readJsonPath(doc, 'data.*.id'), 'm-1');
  });

  test('misses resolve to null instead of throwing', () {
    expect(readJsonPath(doc, 'nope'), isNull);
    expect(readJsonPath(doc, 'data[5].id'), isNull);
    expect(readJsonPath(doc, 'data[0].relationships[type=artist]'), isNull);
    expect(readJsonPath(doc, 'total.deeper'), isNull);
    expect(readJsonPath(null, 'anything'), isNull);
  });

  test('templates substitute value, vars, item and root paths', () {
    final item = (doc['data'] as List).first;
    expect(
      renderJsonTemplate(
        'https://covers.example/{id}/{value}.256.jpg',
        value: 'cover.jpg',
        item: item,
      ),
      'https://covers.example/m-1/cover.jpg.256.jpg',
    );
    expect(
      renderJsonTemplate('{base}/x/{total}', vars: {'base': 'b'}, root: doc),
      'b/x/42',
    );
  });

  test('an unresolvable template placeholder throws', () {
    expect(
      () => renderJsonTemplate('{missing}', root: doc),
      throwsFormatException,
    );
  });
}
