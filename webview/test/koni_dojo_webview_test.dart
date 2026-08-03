import 'package:flutter_test/flutter_test.dart';
import 'package:koni_dojo_webview/koni_dojo_webview.dart';

void main() {
  group('cf log', () {
    test('cfLog reaches a sink installed by runWithCfLog', () async {
      final lines = <String>[];
      await runWithCfLog((line) => lines.add(line), () async {
        cfLog('first');
        cfLog('second');
      });
      expect(lines, ['first', 'second']);
    });

    test('cfLog outside any runWithCfLog scope is a silent no-op', () {
      // Must not throw: most calls happen outside a solve (e.g. cookie
      // warming at startup), where nothing has installed a sink.
      expect(() => cfLog('unwatched'), returnsNormally);
    });

    test('concurrent runWithCfLog scopes stay isolated', () async {
      final a = <String>[];
      final b = <String>[];
      await Future.wait([
        runWithCfLog((line) => a.add(line), () async {
          cfLog('a1');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          cfLog('a2');
        }),
        runWithCfLog((line) => b.add(line), () async {
          cfLog('b1');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          cfLog('b2');
        }),
      ]);
      expect(a, ['a1', 'a2']);
      expect(b, ['b1', 'b2']);
    });
  });

  group('cloudflareSolveSupported', () {
    test('is a plain bool, readable without a plugin host', () {
      // No assertion on the value itself (platform-dependent under `flutter
      // test`): just confirms the getter doesn't touch the plugin channel.
      expect(cloudflareSolveSupported, isA<bool>());
    });
  });

  group('FieldStep.attrKey', () {
    // Regression: every attr-capturing step across every step list used to
    // produce '${key}Attr' (e.g. 'coverSelectorAttr'), which matches no
    // field in the engine's actual schema (ListingConfig/ChaptersConfig/
    // PagesConfig/DetailsConfig all use 'coverAttr'/'urlAttr'/'imageAttr').
    // Silent: the picker always wrote a real-looking key, the engine just
    // never read it, so every picked cover/url/image attr stayed at the
    // engine's own default — invisible until a site actually needed a
    // non-default one (e.g. a lazy-loaded 'data-src' cover).
    const expected = {
      'itemSelector': null, // never attr-capturing
      'titleSelector': null,
      'coverSelector': 'coverAttr',
      'urlSelector': 'urlAttr',
      'nameSelector': null,
      'dateSelector': null,
      'imageSelector': 'imageAttr',
      'authorSelector': null,
      'descriptionSelector': null,
      'genreSelector': null,
    };

    test('matches the engine\'s real schema field name, not "<key>Attr"', () {
      for (final steps in [
        popularSteps,
        chaptersSteps,
        pagesSteps,
        detailsFields,
      ]) {
        for (final step in steps) {
          if (step.attr.isEmpty) continue;
          final want = expected[step.key];
          expect(
            want,
            isNotNull,
            reason:
                '${step.key} captures an attr but has no expected '
                'mapping in this test — add one',
          );
          expect(
            step.attrKey,
            want,
            reason:
                '${step.key}.attrKey should be "$want", not '
                '"${step.attrKey}"',
          );
          // The literal old bug, pinned directly: attrKey must never equal
          // the naive '${key}Attr' concatenation once key != its own stem.
          expect(step.attrKey, isNot('${step.key}Attr'));
        }
      }
    });
  });

  group('FieldStep.previewIsImage', () {
    test('defaults to false', () {
      const step = FieldStep(
        key: 'x',
        instruction: 'x',
        fieldLabel: 'X',
        mode: StepMode.relative,
      );
      expect(step.previewIsImage, isFalse);
    });

    test(
      'only detailsFields\' coverSelector opts in — the picker\'s '
      'live-sync/thumbnail work is scoped to the Details palette this '
      'round; popularSteps\' structurally-identical cover step is a '
      'deliberate one-word follow-up, not an oversight, if extended later',
      () {
        for (final steps in [popularSteps, chaptersSteps, pagesSteps]) {
          for (final step in steps) {
            expect(
              step.previewIsImage,
              isFalse,
              reason: '${step.key} should not opt into image previews yet',
            );
          }
        }
        for (final step in detailsFields) {
          expect(
            step.previewIsImage,
            step.key == 'coverSelector',
            reason: '${step.key}.previewIsImage',
          );
        }
      },
    );
  });
}
