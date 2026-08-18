// A source's declared `rateLimit` is a promise made to the *site*. Images —
// pages and covers, which routinely come from an unrelated CDN — take a
// concurrency cap instead. These tests pin that split, because it is not
// visible from either side on its own: the limiter still works, the images
// still arrive, and the only observable difference is the *shape* of the
// requests, which is precisely what costs a phone its battery.
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

const _period = Duration(milliseconds: 200);

/// A 1x1 GIF: enough of a real signature that `classifyPageBody` accepts it.
final _image = Uint8List.fromList([
  0x47,
  0x49,
  0x46,
  0x38,
  0x39,
  0x61,
  0x01,
  0x00,
  0x01,
  0x00,
  0x80,
  0x00,
  0x00,
  0xFF,
  0xFF,
  0xFF,
  0x00,
  0x00,
  0x00,
  0x21,
  0xF9,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x2C,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x00,
  0x02,
  0x02,
  0x44,
  0x01,
  0x00,
  0x3B,
]);

const _listingHtml = '''
<html><body>
  <div class="item"><a class="title" href="/manga/alpha">Alpha</a></div>
</body></html>
''';

Map<String, dynamic> _configJson({Map<String, dynamic>? imageRateLimit}) => {
  'id': 'shapes',
  'name': 'Shapes',
  'lang': 'en',
  'baseUrl': 'https://site.test',
  'rateLimit': {'requests': 1, 'perMs': _period.inMilliseconds},
  if (imageRateLimit != null) 'imageRateLimit': imageRateLimit,
  'popular': {
    'path': '/popular?page={page}',
    'itemSelector': 'div.item',
    'titleSelector': 'a.title',
    'urlSelector': 'a.title',
    'urlAttr': 'href',
  },
  'chapters': {'itemSelector': 'li', 'nameSelector': 'a', 'urlSelector': 'a'},
  'pages': {'imageSelector': 'img', 'imageAttr': 'src'},
};

/// Records when each image request starts, and how many were in flight.
class _Recorder {
  int inFlight = 0;
  int peakInFlight = 0;
  final List<Duration> imageStarts = [];
  final Stopwatch watch = Stopwatch()..start();

  http.Client client({Duration hold = const Duration(milliseconds: 20)}) =>
      MockClient((request) async {
        if (!request.url.path.contains('/img/')) {
          return http.Response(_listingHtml, 200);
        }
        imageStarts.add(watch.elapsed);
        inFlight++;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        await Future<void>.delayed(hold);
        inFlight--;
        return http.Response.bytes(_image, 200);
      });
}

void main() {
  test('images are not spaced by the site rate limit', () async {
    final rec = _Recorder();
    final source = htmlSource(
      SourceConfig.fromJson(_configJson()),
      client: rec.client(),
    );

    final watch = Stopwatch()..start();
    await Future.wait([
      for (var i = 0; i < 6; i++)
        source.imageBytes(Uri.parse('https://cdn.test/img/$i.gif')),
    ]);

    // Spaced by the site's 200ms limit, six images would take at least a
    // second. Capped-but-unspaced, they take two waves of the 20ms hold.
    expect(watch.elapsed, lessThan(_period * 3));
    expect(rec.imageStarts, hasLength(6));
  });

  test('images stay capped at the concurrency limit', () async {
    final rec = _Recorder();
    final source = htmlSource(
      SourceConfig.fromJson(_configJson()),
      client: rec.client(hold: const Duration(milliseconds: 50)),
    );

    await Future.wait([
      for (var i = 0; i < 9; i++)
        source.imageBytes(Uri.parse('https://cdn.test/img/$i.gif')),
    ]);

    expect(rec.peakInFlight, Source.defaultMaxConcurrentImages);
  });

  test('the site rate limit still spaces out non-image requests', () async {
    final rec = _Recorder();
    final source = htmlSource(
      SourceConfig.fromJson(_configJson()),
      client: rec.client(),
    );

    final watch = Stopwatch()..start();
    await source.popular(1);
    await source.popular(2);
    await source.popular(3);

    // Unchanged: three listings can't beat two full periods.
    expect(watch.elapsed, greaterThanOrEqualTo(_period * 2));
  });

  test('a source may still ask for image spacing explicitly', () async {
    final rec = _Recorder();
    final source = htmlSource(
      SourceConfig.fromJson(
        _configJson(imageRateLimit: {'requests': 1, 'perMs': 200}),
      ),
      client: rec.client(),
    );

    final watch = Stopwatch()..start();
    await Future.wait([
      for (var i = 0; i < 3; i++)
        source.imageBytes(Uri.parse('https://cdn.test/img/$i.gif')),
    ]);

    // The escape hatch for a CDN that genuinely wants a rate.
    expect(watch.elapsed, greaterThanOrEqualTo(_period * 2));
  });

  test('an abandoned image fetch gives its slot back', () async {
    // The reader abandons up to four preloads on every chapter switch. Each
    // one throws SourceImageAborted from inside the gate; a slot lost per
    // abandonment would shrink the cap to nothing over a session, and images
    // would simply stop arriving with nothing to show for it.
    final rec = _Recorder();
    final source = htmlSource(
      SourceConfig.fromJson(_configJson()),
      client: rec.client(hold: const Duration(milliseconds: 30)),
    );

    for (var round = 0; round < 4; round++) {
      final abandoned = Completer<void>()..complete();
      await Future.wait([
        for (var i = 0; i < 4; i++)
          source
              .imageBytes(
                Uri.parse('https://cdn.test/img/dead-$round-$i.gif'),
                abort: abandoned.future,
              )
              .then<void>(
                (_) {},
                onError: (Object e) {
                  expect(e, isA<SourceImageAborted>());
                },
              ),
      ]);
    }

    final watch = Stopwatch()..start();
    await Future.wait([
      for (var i = 0; i < Source.defaultMaxConcurrentImages; i++)
        source.imageBytes(Uri.parse('https://cdn.test/img/live-$i.gif')),
    ]);
    // One wave, not a queue behind sixteen leaked permits.
    expect(watch.elapsedMilliseconds, lessThan(120));
  });
}
