import 'package:test/test.dart';
import 'package:koni_dojo/koni_dojo.dart';

class _FakeStore implements LocalStoragePreferenceStore {
  _FakeStore(this._values);
  final Map<String, bool> _values;

  @override
  Future<void> load() async {}

  @override
  Map<String, bool> valuesFor(String sourceId) => _values;
}

SourceConfig _config({
  Map<String, dynamic> localStorageSeed = const {},
  List<LocalStoragePreferenceConfig> localStoragePreferences = const [],
}) => SourceConfig(
  id: 'test-source',
  name: 'Test Source',
  lang: 'en',
  baseUrl: 'https://example.com',
  localStorageSeed: localStorageSeed,
  localStoragePreferences: localStoragePreferences,
  popular: const ListingConfig(itemSelector: '.item'),
  chapters: const ChaptersConfig(itemSelector: '.chapter'),
  pages: const PagesConfig(imageSelector: 'img'),
);

void main() {
  group('effectiveLocalStorageSeed', () {
    test('no declared preferences returns the seed unchanged', () {
      final config = _config(
        localStorageSeed: {
          'filterPreferences': {
            'matureContent': {'acceptErotic': true},
          },
        },
      );
      expect(effectiveLocalStorageSeed(config, null), config.localStorageSeed);
    });

    test('a declared preference with no store falls back to its default', () {
      final config = _config(
        localStorageSeed: {
          'filterPreferences': {
            'matureContent': {'acceptErotic': true, 'acceptGore': false},
          },
        },
        localStoragePreferences: const [
          LocalStoragePreferenceConfig(
            id: 'acceptGore',
            label: 'Show gore',
            seedKey: 'filterPreferences',
            path: ['matureContent', 'acceptGore'],
          ),
        ],
      );
      final seed = effectiveLocalStorageSeed(config, null);
      expect(seed['filterPreferences']['matureContent']['acceptGore'], false);
      // Untouched sibling values survive the patch.
      expect(seed['filterPreferences']['matureContent']['acceptErotic'], true);
    });

    test('a store override wins over both the default and the base seed '
        '(bidirectional — can turn something the seed had on back off)', () {
      final config = _config(
        localStorageSeed: {
          'filterPreferences': {
            'matureContent': {'acceptErotic': true, 'acceptGore': false},
          },
        },
        localStoragePreferences: const [
          LocalStoragePreferenceConfig(
            id: 'acceptGore',
            label: 'Show gore',
            seedKey: 'filterPreferences',
            path: ['matureContent', 'acceptGore'],
          ),
        ],
      );
      final seed = effectiveLocalStorageSeed(
        config,
        _FakeStore({'acceptGore': true}),
      );
      expect(seed['filterPreferences']['matureContent']['acceptGore'], true);

      final reverted = effectiveLocalStorageSeed(
        _config(
          localStorageSeed: {
            'filterPreferences': {
              'matureContent': {'acceptErotic': true, 'acceptGore': true},
            },
          },
          localStoragePreferences: config.localStoragePreferences,
        ),
        _FakeStore({'acceptGore': false}),
      );
      expect(
        reverted['filterPreferences']['matureContent']['acceptGore'],
        false,
      );
    });

    test('a missing seedKey is created rather than throwing', () {
      final config = _config(
        localStoragePreferences: const [
          LocalStoragePreferenceConfig(
            id: 'acceptGore',
            label: 'Show gore',
            seedKey: 'filterPreferences',
            path: ['matureContent', 'acceptGore'],
            defaultValue: true,
          ),
        ],
      );
      final seed = effectiveLocalStorageSeed(config, null);
      expect(seed['filterPreferences']['matureContent']['acceptGore'], true);
    });

    test('never mutates the config\'s own seed map, even across repeated '
        'calls with different overrides', () {
      final baseSeed = <String, dynamic>{
        'filterPreferences': <String, dynamic>{
          'matureContent': <String, dynamic>{'acceptGore': false},
        },
      };
      final config = _config(
        localStorageSeed: baseSeed,
        localStoragePreferences: const [
          LocalStoragePreferenceConfig(
            id: 'acceptGore',
            label: 'Show gore',
            seedKey: 'filterPreferences',
            path: ['matureContent', 'acceptGore'],
          ),
        ],
      );

      final first = effectiveLocalStorageSeed(
        config,
        _FakeStore({'acceptGore': true}),
      );
      expect(first['filterPreferences']['matureContent']['acceptGore'], true);
      // The config's own seed (and the local `baseSeed` it was built from)
      // must be untouched by that patch.
      expect(
        config
            .localStorageSeed['filterPreferences']['matureContent']['acceptGore'],
        false,
      );
      expect(
        (baseSeed['filterPreferences']['matureContent'] as Map)['acceptGore'],
        false,
      );

      final second = effectiveLocalStorageSeed(
        config,
        _FakeStore({'acceptGore': false}),
      );
      expect(second['filterPreferences']['matureContent']['acceptGore'], false);
      // The first call's result must not have been retroactively mutated by
      // the second call sharing the same config.
      expect(first['filterPreferences']['matureContent']['acceptGore'], true);
    });

    test('multiple preferences patch independently, including different '
        'seedKeys', () {
      final config = _config(
        localStorageSeed: {
          'filterPreferences': {
            'matureContent': {'acceptGore': false},
          },
          'otherPrefs': {'enabled': false},
        },
        localStoragePreferences: const [
          LocalStoragePreferenceConfig(
            id: 'acceptGore',
            label: 'Show gore',
            seedKey: 'filterPreferences',
            path: ['matureContent', 'acceptGore'],
          ),
          LocalStoragePreferenceConfig(
            id: 'otherToggle',
            label: 'Other toggle',
            seedKey: 'otherPrefs',
            path: ['enabled'],
          ),
        ],
      );
      final seed = effectiveLocalStorageSeed(
        config,
        _FakeStore({'acceptGore': true, 'otherToggle': true}),
      );
      expect(seed['filterPreferences']['matureContent']['acceptGore'], true);
      expect(seed['otherPrefs']['enabled'], true);
    });
  });
}
