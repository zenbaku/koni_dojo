import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konimanga_playground/blur_toggle.dart';
import 'package:konimanga_playground/cloudflare.dart';
import 'package:konimanga_playground/config_form.dart';
import 'package:konimanga_playground/detail_screen.dart';
import 'package:konimanga_playground/inline_markdown.dart';
import 'package:konimanga_playground/json_view.dart';
import 'package:konimanga_playground/main.dart';
import 'package:konimanga_playground/probe.dart';
import 'package:konimanga_playground/probe_store.dart';
import 'package:konimanga_playground/results_pane.dart';
import 'package:konimanga_playground/sample_config.dart';
import 'package:konimanga_playground/source_image.dart';
import 'package:konimanga_playground/workspace.dart';
import 'package:koni_dojo/koni_dojo.dart';

const _catalogFixture = '''
## Tier 1 — Active sources

| Source | id | Engine | Lang | 18+ | How it's built in | Status | Caveats / notes |
|---|---|---|---|---|---|---|---|
| **Eta** | `eta` | HTML config | en | no | repo | ✅ Working | Madara theme. |
| **NoNotes** | `nonotes` | HTML config | en | no | repo |  |  |
''';

/// A minimal koni_dojo checkout: one active extension (the sample
/// config), one dormant index entry, and a catalog with notes for the sample.
Directory _fixtureWorkspace() {
  final dir = Directory.systemTemp.createTempSync('playground_ws');
  Directory('${dir.path}/extensions').createSync();
  Directory('${dir.path}/repo').createSync();
  File(
    '${dir.path}/workspace.json',
  ).writeAsStringSync(jsonEncode({'name': 'fixture'}));
  File('${dir.path}/extensions/eta.json').writeAsStringSync(
    jsonEncode({
      'name': 'Eta',
      'pkg': 'app.konimanga.extension.en.eta',
      'version': '1.0.0',
      'lang': 'en',
      'nsfw': 0,
      'sources': [jsonDecode(sampleConfig)],
    }),
  );
  final noNotesSource = jsonDecode(sampleConfig) as Map<String, dynamic>;
  noNotesSource['id'] = 'nonotes';
  noNotesSource['name'] = 'NoNotes';
  File('${dir.path}/extensions/nonotes.json').writeAsStringSync(
    jsonEncode({
      'name': 'NoNotes',
      'pkg': 'app.konimanga.extension.en.nonotes',
      'version': '1.0.0',
      'lang': 'en',
      'nsfw': 0,
      'sources': [noNotesSource],
    }),
  );
  File('${dir.path}/sources-catalog.md').writeAsStringSync(_catalogFixture);
  final dormantSource = jsonDecode(sampleConfig) as Map<String, dynamic>;
  dormantSource['id'] = 'dormantone';
  dormantSource['name'] = 'Dormant One';
  File('${dir.path}/repo/generated-index.min.json').writeAsStringSync(
    jsonEncode([
      {
        'name': 'Dormant One',
        'pkg': 'app.konimanga.extension.en.dormantone',
        'version': '1.0.0',
        'lang': 'en',
        'nsfw': 1,
        'sources': [dormantSource],
      },
    ]),
  );
  return dir;
}

void main() {
  // Redirect registry persistence to a temp file so tests never touch the
  // developer's real ~/.konimanga_playground.json.
  setUp(() {
    final f = File(
      '${Directory.systemTemp.createTempSync('pg_state').path}/state.json',
    );
    debugStatePathOverride = f.path;
    addTearDown(() {
      debugStatePathOverride = null;
      if (f.parent.existsSync()) f.parent.deleteSync(recursive: true);
    });
  });

  group('workspace', () {
    test('loads active and dormant tiers with catalog info', () {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);

      expect(ws.loadError, isNull);
      final active = ws.rows.where((r) => r.tier == Tier.active).toList();
      final dormant = ws.rows.where((r) => r.tier == Tier.dormant).toList();
      expect(active, hasLength(2));
      expect(dormant, hasLength(1));

      final sushi = active.singleWhere((r) => r.id == 'eta');
      expect(sushi.id, 'eta');
      expect(sushi.engine, 'html');
      expect(sushi.rateLimitLabel, '1/s');
      expect(sushi.catalog?.status, 'Working'); // leading emoji stripped
      expect(sushi.catalog?.notes, 'Madara theme.');
      expect(sushi.file, isNotNull);

      expect(dormant.single.nsfw, isTrue);
      expect(dormant.single.file, isNull);
      expect(dormant.single.editorText(), contains('"pkg"'));
    });

    test('a broken extension file becomes a visible error row', () {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/extensions/broken.json').writeAsStringSync('{nope');
      final ws = Workspace()..open(dir.path);

      final broken = ws.rows.where((r) => r.parseError != null).toList();
      expect(broken, hasLength(1));
      expect(broken.single.extName, 'broken');
    });

    test('a dormant source promoted to active is not shown twice', () {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      // Re-add a dormant entry that collides with the active 'eta' id
      // (the real generated-index still carries curated sources).
      final collide = jsonDecode(sampleConfig) as Map<String, dynamic>;
      File('${dir.path}/repo/generated-index.min.json').writeAsStringSync(
        jsonEncode([
          {
            'name': 'Eta',
            'pkg': 'app.konimanga.extension.en.eta',
            'version': '1.0.0',
            'lang': 'en',
            'nsfw': 0,
            'sources': [collide], // id: eta, already active
          },
        ]),
      );
      final ws = Workspace()..open(dir.path);

      final eta = ws.rows.where((r) => r.id == 'eta').toList();
      expect(eta, hasLength(1)); // not duplicated
      expect(eta.single.tier, Tier.active); // the active one wins
      expect(ws.rows.where((r) => r.tier == Tier.dormant), isEmpty);
    });

    test('refresh keeps probe state for surviving rows', () {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);
      final before = ws.rows.firstWhere((r) => r.id == 'eta').probe;
      before.phase = ProbePhase.done;
      ws.refresh();
      final after = ws.rows.firstWhere((r) => r.id == 'eta').probe;
      expect(identical(before, after), isTrue);
    });

    test('a directory without extensions/ reports a load error', () {
      final dir = Directory.systemTemp.createTempSync('playground_bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);
      expect(ws.loadError, contains('extensions/'));
    });

    test('registers several workspaces and switches between them', () {
      final a = _fixtureWorkspace();
      final b = _fixtureWorkspace();
      addTearDown(() => a.deleteSync(recursive: true));
      addTearDown(() => b.deleteSync(recursive: true));
      // b's manifest name distinguishes it from a's ('fixture').
      File(
        '${b.path}/workspace.json',
      ).writeAsStringSync(jsonEncode({'name': 'beta'}));

      final ws = Workspace()..loadRegistry();
      ws.open(a.path);
      ws.open(b.path);

      // Both registered, most-recent (b) first; name from b's manifest.
      expect(ws.registered, [b.path, a.path]);
      expect(ws.root, b.path);
      expect(ws.name, 'beta');

      // Switching back re-opens a and its manifest name.
      ws.switchTo(a.path);
      expect(ws.root, a.path);
      expect(ws.name, 'fixture');

      // A fresh instance restores the registry + last current from disk.
      final reopened = Workspace()..loadRegistry();
      expect(reopened.registered, containsAll([a.path, b.path]));
      expect(loadCurrentWorkspace(), a.path);
    });

    test(
      'archived status loads from curation/archived.json and round-trips',
      () {
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        Directory('${dir.path}/curation').createSync();
        File(
          '${dir.path}/curation/archived.json',
        ).writeAsStringSync(jsonEncode({'dormantone': 'site is dead'}));
        final ws = Workspace()..open(dir.path);

        expect(
          ws.rows.firstWhere((r) => r.id == 'dormantone').archivedReason,
          'site is dead',
        );
        expect(ws.rows.firstWhere((r) => r.id == 'eta').archived, isFalse);

        // Archive another id: rows update in place and the file persists it.
        ws.setArchived('eta', 'not worth the hassle');
        expect(
          ws.rows.firstWhere((r) => r.id == 'eta').archivedReason,
          'not worth the hassle',
        );
        final onDisk =
            jsonDecode(
                  File('${dir.path}/curation/archived.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
        expect(onDisk, {
          'dormantone': 'site is dead',
          'eta': 'not worth the hassle',
        });

        // Un-archive: removed from rows and from disk, and survives a refresh.
        ws.setArchived('dormantone', null);
        ws.refresh();
        expect(
          ws.rows.firstWhere((r) => r.id == 'dormantone').archived,
          isFalse,
        );
        expect(
          ws.rows.firstWhere((r) => r.id == 'eta').archivedReason,
          'not worth the hassle',
        );
      },
    );

    test('setArchived creates curation/ when it does not exist yet', () {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);

      ws.setArchived('nonotes', 'broken site');
      expect(File('${dir.path}/curation/archived.json').existsSync(), isTrue);
      expect(ws.rows.firstWhere((r) => r.id == 'nonotes').archived, isTrue);
    });

    test(
      'candidates load from curation/candidates.json as an inert, unprobed tier',
      () {
        // Stubs a workspace's candidate lister writes: a name/lang/baseUrl only,
        // never a real config, so they must skip AnySourceConfig.fromJson
        // (it would throw: nothing here has popular/details/chapters/pages)
        // rather than surface as a broken row.
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        Directory('${dir.path}/curation').createSync();
        File('${dir.path}/curation/candidates.json').writeAsStringSync(
          jsonEncode([
            {
              'id': 'unconverted-site',
              'name': 'Unconverted Site',
              'lang': 'en',
              'nsfw': false,
              'baseUrl': 'https://example.com',
              'pkg': 'eu.kanade.tachiyomi.extension.en.unconverted',
            },
          ]),
        );
        final ws = Workspace()..open(dir.path);

        final candidate = ws.rows.firstWhere((r) => r.tier == Tier.candidate);
        expect(candidate.id, 'unconverted-site');
        expect(candidate.name, 'Unconverted Site');
        expect(candidate.lang, 'en');
        expect(candidate.config, isNull);
        // parseError is what already excludes a row from probeAll, reused
        // here rather than adding a second "don't probe this" mechanism.
        expect(candidate.parseError, isNotNull);
      },
    );

    test('priority loads from curation/candidate_priority.json and joins onto '
        'the matching candidate row', () {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/curation').createSync();
      File('${dir.path}/curation/candidates.json').writeAsStringSync(
        jsonEncode([
          {
            'id': 'unconverted-site',
            'name': 'Unconverted Site',
            'lang': 'en',
            'nsfw': false,
            'baseUrl': 'https://example.com',
            'pkg': 'eu.kanade.tachiyomi.extension.en.unconverted',
          },
        ]),
      );
      File('${dir.path}/curation/candidate_priority.json').writeAsStringSync(
        jsonEncode({
          'unconverted-site': {
            'score': 75,
            'tier': 'highest',
            'reasons': ['+40 theme: madara', '+35 reachable'],
          },
        }),
      );
      final ws = Workspace()..open(dir.path);

      final candidate = ws.rows.firstWhere((r) => r.id == 'unconverted-site');
      expect(candidate.priority?.score, 75);
      expect(candidate.priority?.tier, PriorityTier.highest);
      expect(candidate.priority?.reasons, [
        '+40 theme: madara',
        '+35 reachable',
      ]);
      // A row with no matching id in the priority file stays unranked (a
      // null field, not PriorityTier.unranked: that value only ever comes
      // from a JSON entry the tool itself never writes as a tier).
      expect(ws.rows.firstWhere((r) => r.id == 'eta').priority, isNull);
    });

    test(
      'loads prototypes/*.json as Tier.prototyping, file-backed like active',
      () {
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        Directory('${dir.path}/prototypes').createSync();
        final protoSource = jsonDecode(sampleConfig) as Map<String, dynamic>;
        protoSource['id'] = 'protoone';
        protoSource['name'] = 'Proto One';
        File('${dir.path}/prototypes/protoone.json').writeAsStringSync(
          jsonEncode({
            'name': 'Proto One',
            'pkg': 'app.konimanga.extension.en.protoone',
            'version': '0.1.0',
            'lang': 'en',
            'nsfw': 0,
            'sources': [protoSource],
          }),
        );
        final ws = Workspace()..open(dir.path);

        final proto = ws.rows.where((r) => r.tier == Tier.prototyping);
        expect(proto, hasLength(1));
        expect(proto.single.id, 'protoone');
        // File-backed like an active row, unlike dormant — a prototype is
        // editable/re-savable in place.
        expect(proto.single.file, isNotNull);
        expect(
          ws.rows.where((r) => r.tier == Tier.active),
          hasLength(2), // eta + nonotes, unaffected
        );
      },
    );

    test('a prototype id already active is skipped, not shown twice', () {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/prototypes').createSync();
      // A stale prototype file for an id that has since been promoted to
      // active by hand (outside the app) — the exact scenario
      // Workspace._loadPrototypes' skipIds guard exists for.
      final collide = jsonDecode(sampleConfig) as Map<String, dynamic>;
      File('${dir.path}/prototypes/eta.json').writeAsStringSync(
        jsonEncode({
          'name': 'Eta',
          'pkg': 'app.konimanga.extension.en.eta',
          'version': '0.1.0',
          'lang': 'en',
          'nsfw': 0,
          'sources': [collide], // id: eta, already active
        }),
      );
      final ws = Workspace()..open(dir.path);

      final eta = ws.rows.where((r) => r.id == 'eta').toList();
      expect(eta, hasLength(1));
      expect(eta.single.tier, Tier.active);
      expect(ws.rows.where((r) => r.tier == Tier.prototyping), isEmpty);
    });
  });

  group('catalog parser', () {
    test('extracts status and notes keyed by id, skipping headers', () {
      final infos = parseCatalog(_catalogFixture);
      expect(infos, hasLength(1)); // nonotes has empty status+notes → skipped
      expect(infos['eta']?.status, 'Working'); // leading emoji stripped
      expect(infos['eta']?.notes, 'Madara theme.');
    });
  });

  test('parseConfig accepts bare source, extension file, and index list', () {
    expect(parseConfig(sampleConfig), isA<SourceConfig>());
    expect(parseConfig('{"sources": [$sampleConfig]}'), isA<SourceConfig>());
    expect(parseConfig('[{"sources": [$sampleConfig]}]'), isA<SourceConfig>());
  });

  group('popularConfigured / detailsConfigured / chaptersConfigured / '
      'pagesConfigured', () {
    Map<String, dynamic> scaffoldShaped() => {
      'id': 'examplesite2',
      'name': 'Example Site',
      'lang': 'en',
      'baseUrl': 'https://example.com',
      'popular': {'itemSelector': 'article'},
      'chapters': <String, dynamic>{},
      'pages': <String, dynamic>{},
    };

    test('a fully-authored config (sampleConfig) reads as configured', () {
      final config = parseConfig(sampleConfig);
      expect(popularConfigured(config), isTrue);
      expect(detailsConfigured(config), isTrue);
      expect(chaptersConfigured(config), isTrue);
      expect(pagesConfigured(config), isTrue);
    });

    test('a brand-new prototype\'s blank {} popular block reads as not '
        'configured — the exact shape _scaffoldConfigFromUrl writes before '
        'anything is picked', () {
      final json = scaffoldShaped();
      json['popular'] = <String, dynamic>{};
      final config = AnySourceConfig.fromJson(json);
      expect(popularConfigured(config), isFalse);
    });

    test('a popular block with an explicit steps: block counts as '
        'configured despite a blank itemSelector', () {
      final json = scaffoldShaped();
      json['popular'] = {
        'steps': [
          {
            'request': {'url': '/api/popular'},
            'parse': 'json',
            'yield': {
              'list': {'path': 'data'},
              'fields': {
                'url': {'path': 'id'},
              },
            },
          },
        ],
      };
      final config = AnySourceConfig.fromJson(json);
      expect(popularConfigured(config), isTrue);
    });

    test('a brand-new prototype\'s blank/absent details and blank {} '
        'chapters/pages block reads as not configured — the exact shape '
        '_scaffoldConfigFromUrl writes', () {
      // No "details" key at all, same as the real examplesite2 config
      // that motivated this: DetailsConfig() defaults when absent.
      final config = AnySourceConfig.fromJson(scaffoldShaped());
      expect(detailsConfigured(config), isFalse);
      expect(chaptersConfigured(config), isFalse);
      expect(pagesConfigured(config), isFalse);
    });

    test('an explicit rows: block counts details as configured despite a '
        'blank titleSelector', () {
      final json = scaffoldShaped();
      json['details'] = {
        'rows': {
          'itemSelector': 'div.info',
          'labelSelector': 'span.label',
          'fields': {
            'author': {
              'label': ['Author'],
              'valueSelector': 'span.value',
            },
          },
        },
      };
      final config = AnySourceConfig.fromJson(json);
      expect(detailsConfigured(config), isTrue);
    });

    test('an explicit steps: block counts as configured despite a blank '
        'itemSelector/imageSelector', () {
      final json = scaffoldShaped();
      json['chapters'] = {
        'steps': [
          {
            'request': {'url': '/api/chapters'},
            'parse': 'json',
            'yield': {
              'list': {'path': 'data'},
              'fields': {
                'url': {'path': 'id'},
              },
            },
          },
        ],
      };
      json['pages'] = {
        'steps': [
          {
            'request': {'url': '/api/pages'},
            'parse': 'json',
            'yield': {
              'list': {'path': 'data'},
              'fields': {
                'url': {'path': 'id'},
              },
            },
          },
        ],
      };
      final config = AnySourceConfig.fromJson(json);
      expect(chaptersConfigured(config), isTrue);
      expect(pagesConfigured(config), isTrue);
    });

    test('an API-dialect source always reads as configured — no blank '
        'scaffold flow exists for it', () {
      final config = AnySourceConfig.fromJson({
        'id': 'apiexample',
        'name': 'Api Example',
        'lang': 'en',
        'baseUrl': 'https://example.com',
        'apiUrl': 'https://example.com/api',
        'type': 'api',
        'popular': {'path': '/popular', 'items': 'data'},
        'chapters': <String, dynamic>{},
        'pages': <String, dynamic>{},
      });
      expect(config, isA<ApiSourceConfig>());
      expect(detailsConfigured(config), isTrue);
      expect(chaptersConfigured(config), isTrue);
      expect(pagesConfigured(config), isTrue);
    });
  });

  group('compareRenderedElementCounts (diagnoseWebviewNeed\'s pure part)', () {
    String repeatedTags(String tag, int count) =>
        '<html><body>${'<$tag>x</$tag>' * count}</body></html>';

    test('a webview render with substantially more elements looks '
        'hydrated', () {
      final result = compareRenderedElementCounts(
        repeatedTags('p', 5), // ~7 elements (html, body, 5 p)
        repeatedTags('p', 100), // ~102 elements
      );
      expect(result.looksHydrated, isTrue);
      expect(result.plainCount, lessThan(result.webviewCount));
    });

    test('near-identical element counts do not look hydrated — most sites '
        'are server-rendered and shouldn\'t get flagged', () {
      final result = compareRenderedElementCounts(
        repeatedTags('p', 40),
        repeatedTags('p', 41), // one extra element, e.g. an injected script tag
      );
      expect(result.looksHydrated, isFalse);
    });

    test('a small absolute difference on a small page does not look '
        'hydrated, even if the relative jump is large', () {
      // 2 -> 5 elements is a 2.5x relative jump but only +3 elements --
      // exactly the noise-on-tiny-pages case the absolute margin guards.
      final result = compareRenderedElementCounts(
        repeatedTags('p', 0),
        repeatedTags('p', 3),
      );
      expect(result.looksHydrated, isFalse);
    });

    test('a large absolute difference that\'s only a small relative jump '
        'does not look hydrated', () {
      // +40 elements is well past the absolute margin, but only a ~1.13x
      // relative jump on an already-large page -- not the JS-hydration
      // shape, more likely just page-to-page variance.
      final result = compareRenderedElementCounts(
        repeatedTags('p', 300),
        repeatedTags('p', 340),
      );
      expect(result.looksHydrated, isFalse);
    });
  });

  group('UI', () {
    testWidgets('welcome screen shows without a workspace', (tester) async {
      await tester.pumpWidget(PlaygroundApp(workspace: Workspace()));
      expect(find.text('Open workspace…'), findsOneWidget);
    });

    testWidgets('table lists workspace rows and search filters them', (
      tester,
    ) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PlaygroundApp(workspace: ws));
      expect(find.text('Eta'), findsOneWidget);
      expect(find.text('NoNotes'), findsOneWidget);
      expect(find.text('Dormant One'), findsNothing); // dormant off by default

      await tester.enterText(find.byType(TextField), 'nonotes');
      await tester.pump();
      expect(find.text('Eta'), findsNothing);
      expect(find.text('NoNotes'), findsOneWidget);
    });

    testWidgets(
      'a _FilterDropdown can be reset back to "any" after picking a value',
      (tester) async {
        // Regression test: PopupMenuButton resolves its selection through
        // showMenu<T>, which returns null both when an item whose value is
        // null was tapped *and* when the menu was dismissed without a
        // selection, indistinguishable without _Choice's non-null wrapper,
        // so the "any" entry (this file's null-means-any convention) could
        // never actually be selected again once a real value was chosen.
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        final ws = Workspace()..open(dir.path);

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(PlaygroundApp(workspace: ws));

        // Open the Priority filter and pick "highest": items[0] is "any"
        // (null), items[1] is PriorityTier.highest.
        await tester.tap(find.byTooltip('Filter by priority'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate((w) => w is PopupMenuItem).at(1),
        );
        await tester.pumpAndSettle();
        expect(find.text('highest'), findsWidgets);

        // Reopen and pick "any" again.
        await tester.tap(find.byTooltip('Filter by priority'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate((w) => w is PopupMenuItem).at(0),
        );
        await tester.pumpAndSettle();
        expect(find.text('highest'), findsNothing);
      },
    );

    testWidgets('archived sources hide by default; the chip reveals them', (
      tester,
    ) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/curation').createSync();
      File(
        '${dir.path}/curation/archived.json',
      ).writeAsStringSync(jsonEncode({'nonotes': 'dead site'}));
      final ws = Workspace()..open(dir.path);

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PlaygroundApp(workspace: ws));
      expect(find.text('Eta'), findsOneWidget);
      expect(find.text('NoNotes'), findsNothing); // archived → hidden

      await tester.tap(find.text('archived 1'));
      await tester.pump();
      expect(find.text('NoNotes'), findsOneWidget);
    });

    testWidgets('candidate rows are hidden by default; the chip reveals them', (
      tester,
    ) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/curation').createSync();
      File('${dir.path}/curation/candidates.json').writeAsStringSync(
        jsonEncode([
          {
            'id': 'unconverted-site',
            'name': 'Unconverted Site',
            'lang': 'en',
            'nsfw': false,
            'baseUrl': 'https://example.com',
            'pkg': '',
          },
        ]),
      );
      final ws = Workspace()..open(dir.path);

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PlaygroundApp(workspace: ws));
      expect(find.text('Unconverted Site'), findsNothing);

      await tester.tap(find.text('candidate 1'));
      await tester.pump();
      expect(find.text('Unconverted Site'), findsOneWidget);
    });

    testWidgets(
      'the archived chip reveals a row even when no tier chip is selected',
      (tester) async {
        // Regression: an archived row keeps its original tier (here,
        // dormant), and the tier chips default to {active} only. Deselecting
        // every tier chip to isolate "just archived" used to leave nothing
        // for the archived row to match. The archived toggle must bypass
        // the tier gate, not layer on top of it.
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        Directory('${dir.path}/curation').createSync();
        File(
          '${dir.path}/curation/archived.json',
        ).writeAsStringSync(jsonEncode({'dormantone': 'dead site'}));
        final ws = Workspace()..open(dir.path);

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(PlaygroundApp(workspace: ws));
        expect(find.text('Dormant One'), findsNothing);

        await tester.tap(find.text('active 2')); // deselect the only tier
        await tester.pump();
        await tester.tap(find.text('archived 1'));
        await tester.pump();

        expect(find.text('Dormant One'), findsOneWidget);
        expect(find.text('Eta'), findsNothing);
        expect(find.text('NoNotes'), findsNothing);
      },
    );

    testWidgets(
      'editing the reason of an already-archived source updates it without '
      'un-archiving',
      (tester) async {
        // Regression: tapping the archive icon on an already-archived row
        // used to un-archive it immediately with no dialog at all. The
        // reason could only be set at the moment of initial archiving, with
        // no way to add to or correct it later.
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        final ws = Workspace()..open(dir.path);
        ws.setArchived('eta', 'old reason');

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(PlaygroundApp(workspace: ws));
        await tester.tap(find.text('archived 1'));
        await tester.pump();
        await tester.tap(find.text('Eta'));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.unarchive_outlined));
        await tester.pumpAndSettle();

        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        expect(field, findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, 'old reason');

        await tester.enterText(field, 'new reason');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        final row = ws.rows.firstWhere((r) => r.id == 'eta');
        expect(row.archived, isTrue);
        expect(row.archivedReason, 'new reason');
      },
    );

    testWidgets('tapping a row opens the detail editor', (tester) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PlaygroundApp(workspace: ws));
      await tester.tap(find.text('Eta'));
      await tester.pumpAndSettle();

      // 'Full probe' labels both the app-bar button and the stage dropdown's
      // default item; the unique 'Run chain' button confirms the runner.
      expect(find.text('Full probe'), findsWidgets);
      expect(find.text('Run chain'), findsOneWidget);
      // Notes are collapsed behind a toggle chip by default (a long catalog
      // writeup would otherwise push the editor/results below the fold).
      // Expand it to reach the actual prose.
      await tester.tap(find.widgetWithText(ActionChip, 'Notes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Madara theme.'), findsOneWidget);
      // The live parse-status line under the editor.
      expect(find.textContaining('Eta · eta · en'), findsOneWidget);
    });

    testWidgets(
      'a dormant row has no Save button but a Promote one, which writes '
      "the editor's current (edited) text to extensions/<id>.json",
      (tester) async {
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        final ws = Workspace()..open(dir.path);

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(PlaygroundApp(workspace: ws));
        // Dormant rows are hidden by default, same as candidate/archived.
        await tester.tap(find.text('dormant 1'));
        await tester.pump();
        await tester.tap(find.text('Dormant One'));
        await tester.pumpAndSettle();

        expect(find.text('Save'), findsNothing);
        expect(find.text('Promote'), findsOneWidget);

        // Edit in place, the fix a user would actually make (turning on
        // webview), before promoting.
        final editedSource = jsonDecode(sampleConfig) as Map<String, dynamic>;
        editedSource['id'] = 'dormantone';
        editedSource['name'] = 'Dormant One';
        editedSource['webview'] = true;
        final editedEntry = {
          'name': 'Dormant One',
          'pkg': 'app.konimanga.extension.en.dormantone',
          'version': '1.0.0',
          'lang': 'en',
          'nsfw': 1,
          'sources': [editedSource],
        };
        await tester.enterText(
          find.byType(TextField).first,
          jsonEncode(editedEntry),
        );
        await tester.pump();

        await tester.tap(find.text('Promote'));
        await tester.pump();

        final written = File('${dir.path}/extensions/dormantone.json');
        expect(written.existsSync(), isTrue);
        final saved = jsonDecode(written.readAsStringSync());
        expect(saved['sources'][0]['webview'], isTrue);
        expect(find.textContaining('Promoted to active'), findsOneWidget);
      },
    );

    testWidgets(
      "promoting is refused when the row's pkg is already active under a "
      'different id',
      (tester) async {
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        // A second dormant entry sharing eta's already-active pkg:
        // the multi-language-extension collision a promote step must guard.
        final collidingSource =
            jsonDecode(sampleConfig) as Map<String, dynamic>;
        collidingSource['id'] = 'eta-es';
        collidingSource['name'] = 'Eta (ES)';
        File('${dir.path}/repo/generated-index.min.json').writeAsStringSync(
          jsonEncode([
            {
              'name': 'Dormant One',
              'pkg': 'app.konimanga.extension.en.dormantone',
              'version': '1.0.0',
              'lang': 'en',
              'nsfw': 1,
              'sources': [
                (jsonDecode(sampleConfig) as Map<String, dynamic>)
                  ..['id'] = 'dormantone',
              ],
            },
            {
              'name': 'Eta (ES)',
              'pkg': 'app.konimanga.extension.en.eta',
              'version': '1.0.0',
              'lang': 'es',
              'nsfw': 0,
              'sources': [collidingSource],
            },
          ]),
        );
        final ws = Workspace()..open(dir.path);

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(PlaygroundApp(workspace: ws));
        await tester.tap(find.text('dormant 2'));
        await tester.pump();
        await tester.tap(find.text('Eta (ES)'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Promote'));
        await tester.pump();

        expect(
          File('${dir.path}/extensions/eta-es.json').existsSync(),
          isFalse,
        );
        expect(find.textContaining('already active as "eta"'), findsOneWidget);
      },
    );

    testWidgets('New source from URL → Save as prototype → Promote to active, '
        'end to end', (tester) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PlaygroundApp(workspace: ws));
      await tester.pumpAndSettle();

      // "New source from URL": prompts for a URL, scaffolds a minimal
      // (bare-source-shaped, same convention as sampleConfig) config from
      // it, and opens the detail screen on that.
      await tester.tap(find.byIcon(Icons.add_link));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'https://newsite.example/',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      // A brand-new scratch config (no row yet) offers "Save as
      // prototype", not "Save"/"Promote".
      expect(find.text('Save'), findsNothing);
      expect(find.text('Save as prototype'), findsOneWidget);

      await tester.tap(find.text('Save as prototype'));
      await tester.pumpAndSettle();

      // Written to prototypes/, wrapped into the extension-entry shape
      // even though the scaffolded buffer was a bare source
      // (_asExtensionEntry's job) -- otherwise
      // Workspace._loadPrototypes' _addEntryRows would silently produce
      // zero rows for it (it reads sources out of an entry's `sources`
      // list).
      final written = File('${dir.path}/prototypes/newsite.json');
      expect(written.existsSync(), isTrue);
      final saved =
          jsonDecode(written.readAsStringSync()) as Map<String, dynamic>;
      expect(saved['sources'], isA<List>());
      expect(saved['sources'][0]['id'], 'newsite');
      expect(saved['sources'][0]['baseUrl'], 'https://newsite.example');

      expect(find.textContaining('Saved as prototype'), findsOneWidget);
      // Navigated to the now-real, file-backed prototyping row: Save
      // works in place, and Promote to active becomes available.
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Promote to active'), findsOneWidget);
      expect(
        ws.rows.singleWhere((r) => r.id == 'newsite').tier,
        Tier.prototyping,
      );

      await tester.tap(find.text('Promote to active'));
      await tester.pumpAndSettle();

      // Graduated: now in extensions/, prototype file cleaned up so it
      // doesn't linger as a stale duplicate, and popped back to the table
      // (not left on a screen whose row.file points at a deleted path).
      expect(File('${dir.path}/extensions/newsite.json').existsSync(), isTrue);
      expect(written.existsSync(), isFalse);
      expect(ws.rows.singleWhere((r) => r.id == 'newsite').tier, Tier.active);
      expect(find.text('Promote to active'), findsNothing);
    });

    testWidgets(
      'Promote to active uses the *edited* id, not the prototype row\'s '
      'original one — regression: it used to write extensions/<old-id>.json '
      'with content whose own "id" field said something else entirely',
      (tester) async {
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        final ws = Workspace()..open(dir.path);

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        Directory('${dir.path}/prototypes').createSync(recursive: true);
        File('${dir.path}/prototypes/oldid.json').writeAsStringSync(
          jsonEncode({
            'name': 'Old Id',
            'pkg': 'app.konimanga.extension.en.oldid',
            'version': '0.1.0',
            'lang': 'en',
            'nsfw': 0,
            'sources': [
              {
                'id': 'oldid',
                'name': 'Old Id',
                'lang': 'en',
                'baseUrl': 'https://oldid.example',
                'popular': <String, dynamic>{},
                'chapters': <String, dynamic>{},
                'pages': <String, dynamic>{},
              },
            ],
          }),
        );
        ws.refresh();

        await tester.pumpWidget(PlaygroundApp(workspace: ws));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Old Id'));
        await tester.pumpAndSettle();

        // Still in JSON mode (the editor's default) -- rename the id
        // in-place, the way a user would before promoting.
        final editor = find.byType(TextField).first;
        final current = tester.widget<TextField>(editor).controller!.text;
        await tester.enterText(
          editor,
          current.replaceAll('"oldid"', '"renamedid"'),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Promote to active'));
        await tester.pumpAndSettle();

        final promoted = File('${dir.path}/extensions/renamedid.json');
        expect(
          promoted.existsSync(),
          isTrue,
          reason:
              'should be named after the edited id, not the original '
              'row id ("oldid")',
        );
        expect(File('${dir.path}/extensions/oldid.json').existsSync(), isFalse);
        final content =
            jsonDecode(promoted.readAsStringSync()) as Map<String, dynamic>;
        expect((content['sources'] as List)[0]['id'], 'renamedid');
        expect(
          File('${dir.path}/prototypes/oldid.json').existsSync(),
          isFalse,
          reason: 'the prototype file should still be cleaned up',
        );
      },
    );

    testWidgets('stage runner shows an input field for ref stages', (
      tester,
    ) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(PlaygroundApp(workspace: ws));
      await tester.tap(find.text('Eta'));
      await tester.pumpAndSettle();

      // Switch the stage dropdown to Details → the ref input + "Run stage"
      // button appear (no network touched).
      await tester.tap(find.byType(DropdownButton<ProbeStage>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details').last);
      await tester.pumpAndSettle();

      expect(find.text('Run stage'), findsOneWidget);
      expect(find.text('manga url / id'), findsOneWidget); // the input hint
    });

    testWidgets(
      'switching stage clears a leftover value from a different stage '
      '(a ref url must never sit in the search query box)',
      (tester) async {
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        final ws = Workspace()..open(dir.path);

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(PlaygroundApp(workspace: ws));
        await tester.tap(find.text('Eta'));
        await tester.pumpAndSettle();

        // Details: type a ref manually (no probe results yet to auto-fill).
        await tester.tap(find.byType(DropdownButton<ProbeStage>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Details').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'manga url / id'),
          'https://example.com/manga/some-series',
        );
        await tester.pump();
        expect(
          find.text('https://example.com/manga/some-series'),
          findsOneWidget,
        );

        // Switching to Search must not carry that url into the query box.
        await tester.tap(find.byType(DropdownButton<ProbeStage>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Search').last);
        await tester.pumpAndSettle();

        expect(
          find.text('https://example.com/manga/some-series'),
          findsNothing,
        );
        expect(find.widgetWithText(TextField, 'query'), findsOneWidget);
      },
    );

    testWidgets(
      'stage runner shows a query input + page field for Tag, like Search',
      (tester) async {
        final dir = _fixtureWorkspace();
        addTearDown(() => dir.deleteSync(recursive: true));
        final ws = Workspace()..open(dir.path);

        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(PlaygroundApp(workspace: ws));
        await tester.tap(find.text('Eta'));
        await tester.pumpAndSettle();

        await tester.tap(find.byType(DropdownButton<ProbeStage>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tag').last);
        await tester.pumpAndSettle();

        expect(find.text('Run stage'), findsOneWidget);
        expect(find.text('tag (comma for multiple)'), findsOneWidget);
        expect(find.text('page'), findsOneWidget); // the page field's label
        expect(find.byIcon(Icons.sell_outlined), findsOneWidget);
      },
    );

    testWidgets(
      'a completed Tag run actually renders its results, not just "ran"',
      (tester) async {
        // Regression: runStage(ProbeStage.tag) populates state.popular (same
        // field Search reuses), but _stageCards' card-render condition had
        // its own hardcoded isSearch check with no isTag counterpart. The
        // request succeeded and state.popular had real items, yet no card
        // ever appeared. Caught live against epsilon; this pins it
        // without touching the network.
        final state = ProbeState()
          ..phase = ProbePhase.done
          ..ranStage = ProbeStage.tag
          ..sourceInfo = const SourceInfo(
            id: 'epsilon',
            name: 'Weeb Central',
            lang: 'en',
            baseUrl: 'https://epsilon.example',
          )
          ..popular = [
            SourceManga(
              url: 'https://epsilon.example/series/1',
              title: 'Skyward Blade',
            ),
          ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ResultsPane(state: state)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Tag results'), findsOneWidget);
        expect(find.text('1 items'), findsOneWidget);
      },
    );

    testWidgets('Full probe shows a Tag probe card when the source has one, '
        'distinct from a dedicated Tag-stage run\'s "Tag results" card', (
      tester,
    ) async {
      final state = ProbeState()
        ..phase = ProbePhase.done
        ..ranStage = ProbeStage.full
        ..sourceInfo = const SourceInfo(
          id: 'epsilon',
          name: 'Weeb Central',
          lang: 'en',
          baseUrl: 'https://epsilon.example',
        )
        ..popular = [
          SourceManga(
            url: 'https://epsilon.example/series/1',
            title: 'Skyward Blade',
          ),
        ]
        ..tagTried = 'Action'
        ..tag = [
          SourceManga(
            url: 'https://epsilon.example/series/1',
            title: 'Skyward Blade',
          ),
          SourceManga(
            url: 'https://epsilon.example/series/2',
            title: 'Crimson Tide',
          ),
        ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ResultsPane(state: state)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tag probe'), findsOneWidget);
      expect(find.text('tried "Action" — 2 items'), findsOneWidget);
      expect(find.text('Crimson Tide'), findsOneWidget);
    });

    testWidgets('Full probe\'s Tag probe card reports a failed browse without '
        'marking the whole probe failed', (tester) async {
      final state = ProbeState()
        ..phase = ProbePhase.done
        ..ranStage = ProbeStage.full
        ..sourceInfo = const SourceInfo(
          id: 'epsilon',
          name: 'Weeb Central',
          lang: 'en',
          baseUrl: 'https://epsilon.example',
        )
        ..popular = [
          SourceManga(
            url: 'https://epsilon.example/series/1',
            title: 'Skyward Blade',
          ),
        ]
        ..tagTried = 'Action'
        ..tag = null; // the tag browse itself failed, best-effort

      expect(state.passed, isTrue); // never fails the overall probe

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ResultsPane(state: state)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tag probe'), findsOneWidget);
      expect(find.text('tried "Action" — no results'), findsOneWidget);
    });

    testWidgets(
      '"target this" on a Popular result reports the manga URL/title, not '
      'the thumbnail URL — the seed-from-result primitive the picker '
      'wizards use to target Details/Chapters',
      (tester) async {
        final state = ProbeState()
          ..phase = ProbePhase.done
          ..ranStage = ProbeStage.full
          ..sourceInfo = const SourceInfo(
            id: 'epsilon',
            name: 'Weeb Central',
            lang: 'en',
            baseUrl: 'https://epsilon.example',
          )
          ..popular = [
            SourceManga(
              url: 'https://epsilon.example/series/1',
              title: 'Skyward Blade',
              thumbnailUrl: 'https://epsilon.example/covers/1.jpg',
            ),
          ];

        String? targetedUrl;
        String? targetedLabel;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ResultsPane(
                state: state,
                onTargetPicked: (url, label) {
                  targetedUrl = url;
                  targetedLabel = label;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.ads_click), findsOneWidget);
        await tester.tap(find.byIcon(Icons.ads_click));
        await tester.pump();

        expect(targetedUrl, 'https://epsilon.example/series/1');
        expect(targetedLabel, 'Skyward Blade');
      },
    );

    testWidgets(
      'without onTargetPicked, a Popular result shows no "target this" icon',
      (tester) async {
        final state = ProbeState()
          ..phase = ProbePhase.done
          ..ranStage = ProbeStage.full
          ..sourceInfo = const SourceInfo(
            id: 'epsilon',
            name: 'Weeb Central',
            lang: 'en',
            baseUrl: 'https://epsilon.example',
          )
          ..popular = [
            SourceManga(
              url: 'https://epsilon.example/series/1',
              title: 'Skyward Blade',
            ),
          ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ResultsPane(state: state)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.ads_click), findsNothing);
      },
    );

    testWidgets('the verdict banner reflects details/chapters as independently '
        'skipped — not a strict ladder that wrongly claims chapters/pages '
        'are unconfigured just because details is', (tester) async {
      final state = ProbeState()
        ..phase = ProbePhase.done
        ..ranStage = ProbeStage.full
        ..sourceInfo = const SourceInfo(
          id: 'epsilon',
          name: 'Weeb Central',
          lang: 'en',
          baseUrl: 'https://epsilon.example',
        )
        ..popular = [
          SourceManga(
            url: 'https://epsilon.example/series/1',
            title: 'Skyward Blade',
          ),
        ]
        ..chapters = [
          SourceChapter(url: 'https://epsilon.example/ch-1', name: 'Chapter 1'),
        ]
        ..detailsConfigured = false
        ..chaptersConfigured = true
        ..pagesConfigured = false; // no pages block picked yet either

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ResultsPane(state: state)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Popular → chapters passed'), findsOneWidget);
      expect(find.textContaining('details/pages'), findsOneWidget);
    });

    testWidgets('the verdict banner credits pages as skipped when chapters is '
        'unconfigured, even if pagesConfigured itself is true — pages never '
        'actually gets a chapter to fetch in that case', (tester) async {
      final state = ProbeState()
        ..phase = ProbePhase.done
        ..ranStage = ProbeStage.full
        ..sourceInfo = const SourceInfo(
          id: 'epsilon',
          name: 'Weeb Central',
          lang: 'en',
          baseUrl: 'https://epsilon.example',
        )
        ..popular = [
          SourceManga(
            url: 'https://epsilon.example/series/1',
            title: 'Skyward Blade',
          ),
        ]
        ..detailsConfigured = true
        ..chaptersConfigured = false
        ..pagesConfigured = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ResultsPane(state: state)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Popular → details passed'), findsOneWidget);
      expect(find.textContaining('chapters/pages'), findsOneWidget);
    });

    testWidgets('the picker toolbar button disables while a probe is running — '
        'regression: opening the picker mid-probe used to silently skip its '
        'own "probe first" step, since runStage no-ops while one is already '
        'in flight', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final row = SourceRow(
        tier: Tier.prototyping,
        extName: 'Test',
        pkg: 'app.konimanga.extension.en.test',
        version: '0.1.0',
        nsfw: false,
        rawSource: const {'id': 'test'},
      )..probe.phase = ProbePhase.running;

      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            row: row,
            title: 'Test',
            initialText: jsonEncode({
              'id': 'test',
              'name': 'Test',
              'lang': 'en',
              'baseUrl': 'https://test.example',
              // A real itemSelector: an unconfigured popular would also
              // trigger _maybeCheckWebviewNeed's background diagnostic
              // fetch, unrelated to what this test is actually checking.
              'popular': {'itemSelector': 'div.item'},
              'chapters': <String, dynamic>{},
              'pages': <String, dynamic>{},
            }),
          ),
        ),
      );
      await tester.pump();

      final button = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      expect(button.enabled, isFalse);
    });
  });

  group('filter picker (Tag + Search stages)', () {
    // Mirrors epsilon.json's real shape: `tag.tagParam`/`tagExcludeParam`
    // are the exact same query params as its own "tags" filter group's
    // `param`/`excludeParam`: the signal that group's already-known options
    // are valid tag values, not a guess. "type" shares neither, so it must
    // NOT be offered as a tag picker even though it's also a filter group.
    Map<String, dynamic> epsilonShaped() => {
      'id': 'wc',
      'name': 'WC',
      'lang': 'en',
      'baseUrl': 'https://wc.example',
      'popular': {'itemSelector': 'div.item'},
      'search': {'path': '/search?text={query}', 'itemSelector': 'div.item'},
      'tag': {
        'path': '/search?page={page}',
        'itemSelector': 'div.item',
        'tagParam': 'included_tag',
        'tagExcludeParam': 'excluded_tag',
      },
      'chapters': {'itemSelector': 'li.chapter'},
      'pages': {'imageSelector': 'img.page'},
      'filters': [
        {
          'id': 'tags',
          'name': 'Tags',
          'param': 'included_tag',
          'excludeParam': 'excluded_tag',
          'options': [
            {'value': 'Action', 'label': 'Action'},
            {'value': 'Comedy', 'label': 'Comedy'},
          ],
        },
        {
          'id': 'type',
          'name': 'Series Type',
          'param': 'included_type',
          'options': [
            {'value': 'Manga', 'label': 'Manga'},
          ],
        },
      ],
    };

    test('tagRelevantFilters matches only the group sharing tag.tagParam', () {
      final config = AnySourceConfig.fromJson(epsilonShaped());
      final relevant = tagRelevantFilters(config);
      expect(relevant.map((f) => f.id), ['tags']);
    });

    test('tagRelevantFilters is empty when tag has no tagParam (single-tag '
        'sources with no shared param keep the free-text field)', () {
      final json = epsilonShaped();
      (json['tag'] as Map<String, dynamic>).remove('tagParam');
      (json['tag'] as Map<String, dynamic>).remove('tagExcludeParam');
      final config = AnySourceConfig.fromJson(json);
      expect(tagRelevantFilters(config), isEmpty);
    });

    test(
      'tagRelevantFilters is empty when no filter group shares tag\'s param',
      () {
        final json = epsilonShaped();
        (json['filters'] as List).removeWhere((f) => f['id'] == 'tags');
        final config = AnySourceConfig.fromJson(json);
        expect(tagRelevantFilters(config), isEmpty);
      },
    );

    test(
      'loadTagFilterGroups returns the matching group with its real options '
      'and exclusion support — no network touched (static options only)',
      () async {
        final groups = await loadTagFilterGroups(jsonEncode(epsilonShaped()));
        expect(groups, hasLength(1));
        expect(groups.single.id, 'tags');
        expect(groups.single.supportsExclusion, isTrue);
        expect(groups.single.options.map((o) => o.id), ['Action', 'Comedy']);
      },
    );

    testWidgets(
      'switching to Tag replaces free text with tappable chips, cycling '
      'off → included → excluded',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              title: 'WC',
              initialText: jsonEncode(epsilonShaped()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(DropdownButton<ProbeStage>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tag').last);
        await tester.pumpAndSettle(); // loadTagFilterGroups resolves

        // The free-text field is gone; the real known options show as chips.
        expect(find.text('tag (comma for multiple)'), findsNothing);
        expect(find.text('Action'), findsOneWidget);
        expect(find.text('Comedy'), findsOneWidget);
        // "type" doesn't share tag's param: not offered as a tag chip.
        expect(find.text('Manga'), findsNothing);

        await tester.tap(find.text('Action'));
        await tester.pump();
        expect(find.text('1 included'), findsOneWidget);

        await tester.tap(find.text('Action'));
        await tester.pump();
        // included → excluded, per FilterSelection.cycle: no longer counted
        // as included once it's excluded.
        expect(find.text('0 included, 1 excluded'), findsOneWidget);

        await tester.tap(find.text('Action'));
        await tester.pump();
        // excluded → off, back to the initial "nothing selected" prompt.
        expect(
          find.text(
            'Tap tags below — from this source\'s own filters, not free text',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the Raw checkbox swaps the picker back for free text, for a tag '
      'the source doesn\'t declare in its own filters',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              title: 'WC',
              initialText: jsonEncode(epsilonShaped()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(DropdownButton<ProbeStage>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tag').last);
        await tester.pumpAndSettle();

        // Picker showing, no free-text field yet.
        expect(find.text('Action'), findsOneWidget);
        expect(find.text('tag (comma for multiple)'), findsNothing);

        // Pick something via the managed picker before opting out, to prove
        // opting out doesn't discard it.
        await tester.tap(find.text('Action'));
        await tester.pump();
        expect(find.text('1 included'), findsOneWidget);

        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();

        // Free text is back; the picker (and its known-only options) is gone.
        // A secret/undocumented tag can be typed directly.
        expect(find.text('tag (comma for multiple)'), findsOneWidget);
        expect(find.text('Action'), findsNothing);

        await tester.enterText(
          find.widgetWithText(TextField, 'tag (comma for multiple)'),
          'SecretTag',
        );
        await tester.pump();
        expect(find.text('SecretTag'), findsOneWidget);

        // Toggling back off restores the picker, with the prior selection
        // (Action, still included) intact rather than reset.
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(find.text('Action'), findsOneWidget);
        expect(find.text('1 included'), findsOneWidget);
      },
    );

    testWidgets(
      'Search shows every declared filter group (not just tag-relevant '
      'ones) alongside the query field, not instead of it',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              title: 'WC',
              initialText: jsonEncode(epsilonShaped()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Search is the default second stage in the dropdown, but switch
        // explicitly rather than relying on ordering.
        await tester.tap(find.byType(DropdownButton<ProbeStage>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Search').last);
        await tester.pumpAndSettle(); // loadFilterGroups resolves

        // Unlike Tag, the query field stays: search combines text + filters.
        expect(find.text('query'), findsOneWidget);
        // Both groups show here: "type" isn't excluded the way it is for
        // the Tag picker, since Search isn't scoped to tag.tagParam.
        expect(find.text('Action'), findsOneWidget);
        expect(find.text('Comedy'), findsOneWidget);
        expect(find.text('Manga'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextField, 'query'),
          'shonen',
        );
        await tester.tap(find.text('Manga'));
        await tester.tap(find.text('Action'));
        await tester.pump();

        // Both the typed query and the tapped filters coexist.
        expect(find.text('shonen'), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing); // no Raw toggle here
      },
    );
  });

  group('config form', () {
    testWidgets('renders structured fields and round-trips an edit to JSON', (
      tester,
    ) async {
      String? emitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(text: sampleConfig, onChanged: (t) => emitted = t),
          ),
        ),
      );
      // Structured fields from the sample (Eta) are present.
      expect(find.widgetWithText(TextField, 'Eta'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'https://eta.example'),
        findsOneWidget,
      );

      // Editing the ID field emits valid JSON carrying the new value, with the
      // rest of the config preserved.
      await tester.enterText(find.widgetWithText(TextField, 'eta'), 'renamed');
      expect(emitted, isNotNull);
      final source = parseConfig(emitted!) as SourceConfig;
      expect(source.id, 'renamed');
      expect(source.baseUrl, 'https://eta.example'); // untouched
      expect(source.popular.itemSelector, 'div.page-item-detail'); // preserved
    });

    testWidgets(
      'onPickRequested shows a pick icon on popular/details/chapters/pages '
      'sections (not search, which the picker doesn\'t cover yet), wired '
      'to the right opKey',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final requested = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConfigForm(
                text: sampleConfig,
                onChanged: (_) {},
                onPickRequested: requested.add,
              ),
            ),
          ),
        );

        // sampleConfig has popular/search/details/chapters/pages; only the
        // first four are in _pickableOps, so exactly 4 icons, not 5.
        expect(find.byIcon(Icons.ads_click_outlined), findsNWidgets(4));

        await tester.tap(find.byIcon(Icons.ads_click_outlined).first);
        expect(requested, ['popular']);
      },
    );

    testWidgets('without onPickRequested, no section shows a pick icon', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(text: sampleConfig, onChanged: (_) {}),
          ),
        ),
      );

      expect(find.byIcon(Icons.ads_click_outlined), findsNothing);
    });

    testWidgets('unparseable JSON shows a fix-in-JSON hint', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(text: '{ not json', onChanged: (_) {}),
          ),
        ),
      );
      expect(find.textContaining('doesn\'t parse'), findsOneWidget);
    });

    testWidgets(
      'operation sections badge progress: not started / in progress / '
      'configured',
      (tester) async {
        // A brand-new source scaffold: popular untouched, chapters has a
        // field but not the one that makes it do anything (itemSelector),
        // pages has exactly that key field.
        const config = '''
{
  "id": "wip",
  "name": "WIP",
  "lang": "en",
  "baseUrl": "https://wip.example",
  "popular": {},
  "chapters": { "nameSelector": "a" },
  "pages": { "imageSelector": "img" }
}
''';
        // A tall viewport, not the default 800x600: the sections under
        // test (chapters/pages) sit below the Source card + popular, and a
        // ListView (even with a literal children: list) only builds
        // Elements near the viewport -- find() can't see what was never
        // built, regardless of scroll position on a short surface.
        tester.view.physicalSize = const Size(1200, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConfigForm(text: config, onChanged: (_) {}),
            ),
          ),
        );

        expect(find.text('Not started'), findsOneWidget); // popular
        expect(
          find.textContaining('in progress'),
          findsOneWidget,
        ); // chapters: has a field, but not itemSelector
        expect(
          find.text('1 field set'),
          findsOneWidget,
        ); // pages: has imageSelector, its key field -> configured
      },
    );

    testWidgets('selector tester matches against the probed HTML', (
      tester,
    ) async {
      const html =
          '<html><body>'
          '<div class="page-item-detail">'
          '<div class="post-title"><a href="/manga/foo">Foo Title</a></div>'
          '</div>'
          '</body></html>';
      // The default 800x600 test surface isn't tall enough for the whole
      // form (Source card + operations) to mount within the ListView's
      // viewport + cache extent: 'popular' would need a scroll to even
      // exist in the tree, let alone be tappable. Taller surface avoids
      // scrolling altogether instead of chasing the exact pixel needed.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(
              text: sampleConfig,
              testHtml: html,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      // Expand the popular section to reveal its selector fields + indicators.
      await tester.tap(find.text('popular'));
      await tester.pumpAndSettle();

      // itemSelector "div.page-item-detail" matches once; titleSelector
      // "div.post-title a" (scoped to the item) previews "Foo Title". Both the
      // item div (whose text is the title) and the title anchor preview it.
      expect(find.textContaining('1 match'), findsWidgets);
      expect(find.textContaining('Foo Title'), findsWidgets);
    });

    testWidgets('selector tester flags a selector that matches nothing', (
      tester,
    ) async {
      const html = '<html><body><p>nothing here</p></body></html>';
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(
              text: sampleConfig,
              testHtml: html,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('popular'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no match'), findsWidgets);
    });
  });

  group('probe store', () {
    test('records a run + examples and reloads status across a restart', () {
      final store = ProbeStore.memory();

      // Simulate a finished full probe that failed at chapters, with one traced
      // request/response.
      final state = ProbeState()
        ..phase = ProbePhase.done
        ..ranStage = ProbeStage.full
        ..sourceInfo = const SourceInfo(
          id: 'demo',
          name: 'Demo',
          lang: 'en',
          baseUrl: 'https://demo.test',
        )
        ..failedStage = 'chapters'
        ..stageError = 'chapters returned nothing'
        ..elapsed = const Duration(milliseconds: 1234);
      state.traces.add(
        StepTrace(
          index: 0,
          requestUrl: 'https://demo.test/manga/1',
          method: 'GET',
          body: '<html>hi</html>',
          captured: const {'id': '1'},
        ),
      );

      store.record(state, tier: 'active');

      // A fresh read (the "restart") sees the persisted status …
      final last = store.lastRun('demo')!;
      expect(last.passed, isFalse);
      expect(last.failedStage, 'chapters');
      expect(last.elapsedMs, 1234);
      expect(last.tier, 'active');

      // … and it rebuilds into a display state for the table.
      final seeded = probeStateFromRun(last);
      expect(seeded.phase, ProbePhase.done);
      expect(seeded.label, 'fail@chapters');
      expect(seeded.recordedAt, isNotNull);

      // The captured example round-trips.
      final examples = store.examplesFor('demo');
      expect(examples, hasLength(1));
      expect(examples.single.requestUrl, 'https://demo.test/manga/1');
      expect(examples.single.body, contains('hi'));
      expect(examples.single.captured['id'], '1');

      store.close();
    });

    test('examples reflect only the latest run; history accumulates', () {
      final store = ProbeStore.memory();
      ProbeState run(String bodyText, bool pass) => ProbeState()
        ..phase = ProbePhase.done
        ..ranStage = ProbeStage.popular
        ..sourceInfo = const SourceInfo(
          id: 'x',
          name: 'X',
          lang: 'en',
          baseUrl: 'https://x.test',
        )
        ..failedStage = pass ? null : 'popular'
        ..traces.add(
          StepTrace(index: 0, requestUrl: 'https://x.test/', body: bodyText),
        );

      store.record(run('first', false));
      store.record(run('second', true));

      // Two runs in history, newest first; examples show only the latest.
      final history = store.history('x');
      expect(history, hasLength(2));
      expect(history.first.passed, isTrue); // most recent
      expect(store.examplesFor('x').single.body, 'second');
      store.close();
    });
  });

  group('clearance persistence', () {
    test('saved clearance survives a reload (the restart path)', () async {
      final dir = Directory.systemTemp.createTempSync('pg_clr');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/clearance.json';

      PlaygroundClearanceStore(path: path).save(
        'Example.com', // saved case-insensitively
        cookie: 'cf_clearance=abc123; __cf_bm=xyz',
        userAgent: 'UA/1.0',
      );

      // A fresh store (a new app launch) reloads it from disk.
      final reloaded = PlaygroundClearanceStore(path: path);
      await reloaded.load();
      expect(reloaded.hasFor('https://example.com/manga/1'), isTrue);
      expect(reloaded.entries.single.cookie, contains('cf_clearance=abc123'));
      // Replayed on HTTP requests as the Cookie + matching UA.
      final headers = reloaded.headersFor('https://example.com/x');
      expect(headers['Cookie'], contains('cf_clearance=abc123'));
      expect(headers['User-Agent'], 'UA/1.0');
    });
  });

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
      // Must not throw: most calls happen outside a probe run (e.g. cookie
      // warming at startup), where nothing has installed a sink.
      expect(() => cfLog('unwatched'), returnsNormally);
    });

    test('nested runWithCfLog + runWithTrace both stay reachable', () async {
      final lines = <String>[];
      final traceIndices = <int>[];
      await runWithCfLog((line) => lines.add(line), () async {
        cfLog('outer');
        await runWithTrace((t) => traceIndices.add(t.index), () async {
          cfLog('inner'); // still reaches the outer log sink
        });
      });
      expect(lines, ['outer', 'inner']);
    });
  });

  group('inline markdown', () {
    testWidgets('renders backtick code and bold spans distinctly', (
      tester,
    ) async {
      // Catalog notes/archive reasons are hand-written with backtick code
      // spans and occasional bold; they were rendering as literal asterisks
      // and backticks in a plain Text widget instead of being formatted.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InlineMarkdown('plain `code here` and **bold here** end'),
          ),
        ),
      );

      final span = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!;
      expect(span.toPlainText(), 'plain code here and bold here end');

      final children = span.children!.cast<TextSpan>();
      expect(
        children.firstWhere((s) => s.text == 'code here').style?.fontFamily,
        'monospace',
      );
      expect(
        children.firstWhere((s) => s.text == 'bold here').style?.fontWeight,
        FontWeight.bold,
      );
    });
  });

  group('raw data dialog', () {
    testWidgets('opens without a "Scrollbar has no ScrollPosition" assertion — '
        'regression for two nested SingleChildScrollViews with no explicit '
        'controller, which fall back to a PrimaryScrollController a Dialog '
        'overlay can\'t reliably attach', (tester) async {
      // NOTE: this does NOT reliably discriminate the actual bug. The
      // auto-Scrollbar wrap that causes it only triggers on desktop/web
      // platforms (MaterialScrollBehavior.buildScrollbar), and flutter_test
      // defaults to mobile. Flipping debugDefaultTargetPlatformOverride
      // hangs the harness outright (it also engages real platform channels
      // this app's plugins expect to service, unrelated to scrolling).
      // _DesktopScrollbarBehavior below avoids that hang by overriding just
      // getPlatform() on a scoped ScrollBehavior, reaching the same desktop
      // switch branch in buildScrollbar, confirmed against the Flutter SDK
      // source that this is the exact branch that wraps a vertical
      // scrollable in a Scrollbar. It doesn't hang, but it *also* passes
      // against the pre-fix code (verified via git stash on json_view.dart).
      // PrimaryScrollController is apparently still reachable in this
      // synthetic single-Navigator harness even when the branch is forced,
      // unlike whatever's different about the real app that the user's
      // stack trace came from. Kept as a smoke test (the dialog must
      // render without error) but the fix's real verification is the live
      // app, not this.
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: _DesktopScrollbarBehavior(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      // Not awaited: showRawDataDialog's Future only completes when the
      // dialog is popped, which this test never does: awaiting it here
      // would hang forever.
      unawaited(
        showRawDataDialog(
          capturedContext,
          title: 'Step 0 · body',
          text: '{"a": 1, "b": [1, 2, 3]}',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Step 0 · body'), findsOneWidget);
      expect(errors, isEmpty);

      // Close it: completes the un-awaited Future above cleanly instead
      // of leaving a dangling route at test teardown.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
    });
  });

  group('NSFW blur toggle', () {
    testWidgets('is visible on the workspace table\'s toolbar', (tester) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      await tester.pumpWidget(
        PlaygroundApp(workspace: Workspace()..open(dir.path)),
      );
      expect(find.byType(BlurToggleAction), findsOneWidget);
      expect(find.byIcon(Icons.visibility), findsOneWidget); // off by default
    });

    testWidgets('is visible on the detail screen\'s toolbar too', (
      tester,
    ) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        PlaygroundApp(workspace: Workspace()..open(dir.path)),
      );
      await tester.tap(find.text('Eta'));
      await tester.pumpAndSettle();

      expect(find.byType(BlurToggleAction), findsOneWidget);
    });

    testWidgets('tapping it flips the icon and persists across a reload', (
      tester,
    ) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);
      expect(ws.blurNsfw, isFalse);

      await tester.pumpWidget(PlaygroundApp(workspace: ws));
      expect(find.byIcon(Icons.visibility), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();
      expect(ws.blurNsfw, isTrue);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);

      // Same debugStatePathOverride path as `ws` (set once in setUp for
      // this test): a fresh Workspace() simulates the next app launch.
      expect(Workspace().blurNsfw, isTrue);
    });

    testWidgets('registering/unregistering a workspace does not clobber the '
        'persisted toggle (registerWorkspace/unregisterWorkspace merge into '
        'the full state file rather than overwriting it)', (tester) async {
      final dir = _fixtureWorkspace();
      addTearDown(() => dir.deleteSync(recursive: true));
      final ws = Workspace()..open(dir.path);
      ws.setBlurNsfw(true);

      // Opening (registers) and unregistering both used to _saveState a
      // fresh map with only {current, workspaces}, dropping blurNsfw.
      final other = _fixtureWorkspace();
      addTearDown(() => other.deleteSync(recursive: true));
      ws.open(other.path);
      ws.unregister(other.path);

      expect(Workspace().blurNsfw, isTrue);
    });
  });

  group('SourceImage blur', () {
    testWidgets('blur: true wraps the image in a heavy ImageFiltered blur', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SourceImage(
              url: 'https://example.invalid/cover.jpg',
              viaWebView: false,
              blur: true,
            ),
          ),
        ),
      );
      // No pumpAndSettle: the network fetch this triggers never resolves
      // (example.invalid is RFC 2606-reserved to never exist), only the
      // synchronous widget tree built by the first frame is under test.
      await tester.pump();
      expect(find.byType(ImageFiltered), findsOneWidget);
    });

    testWidgets('blur: false renders the image unwrapped', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SourceImage(
              url: 'https://example.invalid/cover.jpg',
              viaWebView: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('press-and-hold peeks through the blur, release re-blurs', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SourceImage(
              url: 'https://example.invalid/cover.jpg',
              viaWebView: false,
              blur: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ImageFiltered), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(SourceImage)),
      );
      // The peek is a long-press, not a plain tap-down: it only reveals
      // once held past the long-press threshold.
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(find.byType(ImageFiltered), findsNothing);

      await gesture.up();
      await tester.pump();
      expect(find.byType(ImageFiltered), findsOneWidget);
    });

    testWidgets(
      'a quick tap reaches an ancestor tap handler — regression for the '
      'peek gesture stealing the tap an InkWell relies on (e.g. "tap a '
      'cover to see its details"); a long-press recognizer never fires for '
      'a tap shorter than the threshold, so it never contests the arena',
      (tester) async {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InkWell(
                onTap: () => tapped = true,
                child: const SourceImage(
                  url: 'https://example.invalid/cover.jpg',
                  viaWebView: false,
                  blur: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byType(SourceImage));
        await tester.pump();

        expect(tapped, isTrue);
      },
    );

    testWidgets(
      'releasing after a genuine peek does NOT also fire the ancestor tap '
      'handler — regression: with a plain Listener the peek never claimed '
      'the gesture, so releasing after a held peek fell through as a tap '
      'and opened whatever a quick tap would have (e.g. a cover\'s details) '
      '— a long-press wins the arena outright once recognized, so release '
      'no longer also counts as a tap',
      (tester) async {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InkWell(
                onTap: () => tapped = true,
                child: const SourceImage(
                  url: 'https://example.invalid/cover.jpg',
                  viaWebView: false,
                  blur: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(SourceImage)),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        expect(find.byType(ImageFiltered), findsNothing); // peeking

        await gesture.up();
        await tester.pump();

        expect(tapped, isFalse);
      },
    );
  });

  group('pickedFieldLabel / groupPickedFields / breakableSelector', () {
    test('a known FieldStep key uses its fieldLabel, capitalized', () {
      expect(pickedFieldLabel('coverSelector', popularSteps), 'Cover');
      // detailsFields' own labels are already capitalized — stays stable.
      expect(pickedFieldLabel('titleSelector', detailsFields), 'Title');
    });

    test('"path" always reads as "Listing URL", regardless of steps', () {
      expect(pickedFieldLabel('path', popularSteps), 'Listing URL');
      expect(pickedFieldLabel('path', const []), 'Listing URL');
    });

    test('an unrecognized key falls back to a derived, capitalized label', () {
      expect(pickedFieldLabel('genreSelector', popularSteps), 'Genre');
      expect(pickedFieldLabel('mystery', popularSteps), 'Mystery');
    });

    test('groups a selector with its *Attr companion into one row', () {
      final groups = groupPickedFields({
        'itemSelector': 'article.card',
        'coverSelector': 'img',
        'coverAttr': 'data-src',
      }, popularSteps);

      expect(groups, hasLength(2));
      expect(groups[0].label, 'Item');
      expect(groups[0].value, 'article.card');
      expect(groups[0].attr, isNull);
      expect(groups[1].label, 'Cover');
      expect(groups[1].value, 'img');
      expect(groups[1].attr, 'data-src');
    });

    test('a "path" entry always sorts first, ahead of map insertion order', () {
      final groups = groupPickedFields({
        'itemSelector': 'article.card',
        'path': '/search?sort=Popularity',
      }, popularSteps);

      expect(groups.first.label, 'Listing URL');
      expect(groups.first.value, '/search?sort=Popularity');
      expect(groups.last.label, 'Item');
    });

    test('threads a preview through from the picker\'s own previews map', () {
      final groups = groupPickedFields(
        {'itemSelector': 'article.card', 'titleSelector': 'h2'},
        popularSteps,
        {'itemSelector': '24 matches', 'titleSelector': 'Blue Lock'},
      );

      expect(groups[0].label, 'Item');
      expect(groups[0].preview, '24 matches');
      expect(groups[1].label, 'Title');
      expect(groups[1].preview, 'Blue Lock');
    });

    test('a field with no matching preview entry gets a null preview', () {
      final groups = groupPickedFields({
        'itemSelector': 'article.card',
      }, popularSteps);

      expect(groups.single.preview, isNull);
    });

    test('"path" never shows a preview, even if the map happens to have one '
        '(it never actually does — path is injected separately from the '
        'picker\'s own preview capture)', () {
      final groups = groupPickedFields(
        {'path': '/search', 'itemSelector': 'article.card'},
        popularSteps,
        {'path': 'should never show', 'itemSelector': '24 matches'},
      );

      expect(groups.first.label, 'Listing URL');
      expect(groups.first.preview, isNull);
    });

    test(
      'inserts a zero-width space after CSS delimiters, not inside a token',
      () {
        final zwsp = String.fromCharCode(0x200b);
        final broken = breakableSelector('div.text-ellipsis.truncate#a>b');
        expect(
          broken,
          'div.${zwsp}text-ellipsis.${zwsp}truncate#${zwsp}a>${zwsp}b',
        );
        // The zero-width space is invisible but present — round-tripping
        // through it strips back to the original, unbroken selector.
        expect(broken.replaceAll(zwsp, ''), 'div.text-ellipsis.truncate#a>b');
      },
    );
  });

  group('pathFromPickedUrl', () {
    test('strips baseUrl\'s prefix to recover a relative path', () {
      expect(
        pathFromPickedUrl(
          Uri.parse('https://example.com/search?sort=Popularity'),
          'https://example.com',
        ),
        '/search?sort=Popularity',
      );
    });

    test('a picked URL at baseUrl\'s root resolves to an empty path', () {
      expect(
        pathFromPickedUrl(
          Uri.parse('https://example.com'),
          'https://example.com',
        ),
        '',
      );
    });

    test(
      'falls back to the full URL when it does not share baseUrl\'s prefix',
      () {
        expect(
          pathFromPickedUrl(
            Uri.parse('https://other.example/listing'),
            'https://example.com',
          ),
          'https://other.example/listing',
        );
        // No baseUrl at all (blank scaffold) — same fallback.
        expect(
          pathFromPickedUrl(Uri.parse('https://example.com/search'), ''),
          'https://example.com/search',
        );
      },
    );
  });

  group('popularPathIsUnset', () {
    AnySourceConfig configWithPopularPath(String path) =>
        AnySourceConfig.fromJson({
          'id': 'examplesite2',
          'name': 'Example Site',
          'lang': 'en',
          'baseUrl': 'https://example.com',
          'popular': {'itemSelector': 'article', 'path': path},
          'chapters': <String, dynamic>{},
          'pages': <String, dynamic>{},
        });

    test('a blank path reads as unset', () {
      expect(popularPathIsUnset(configWithPopularPath('')), isTrue);
    });

    test('any already-set path reads as set, whatever shape it has — a plain '
        'path, a {page}/{offset} template, or a deliberately different URL '
        'than whatever page the picker was last pointed at (e.g. a live source: '
        'popular.path is the real /search/data endpoint, not /search)', () {
      expect(popularPathIsUnset(configWithPopularPath('/search')), isFalse);
      expect(
        popularPathIsUnset(configWithPopularPath('/search?page={page}')),
        isFalse,
      );
      expect(
        popularPathIsUnset(
          configWithPopularPath('/search/data?sort=Popularity'),
        ),
        isFalse,
      );
    });

    test('null (no config parsed yet) reads as unset', () {
      expect(popularPathIsUnset(null), isTrue);
    });
  });

  group('existingPickedFields', () {
    AnySourceConfig config({
      Map<String, dynamic> popular = const {'itemSelector': ''},
      Map<String, dynamic> chapters = const {},
      Map<String, dynamic> pages = const {},
      Map<String, dynamic> details = const {},
    }) => AnySourceConfig.fromJson({
      'id': 'examplesite3',
      'name': 'Example Site',
      'lang': 'en',
      'baseUrl': 'https://example.com',
      'popular': popular,
      'chapters': chapters,
      'pages': pages,
      'details': details,
    });

    test('null/non-SourceConfig parsed reads as nothing configured yet', () {
      expect(existingPickedFields('popular', null), isEmpty);
      expect(
        existingPickedFields(
          'popular',
          const ApiSourceConfig(
            id: 'x',
            name: 'x',
            lang: 'en',
            baseUrl: 'https://x.example',
            apiUrl: 'https://x.example/api',
            popular: ApiListingConfig(),
            chapters: ApiChaptersConfig(),
            pages: ApiPagesConfig(),
          ),
        ),
        isEmpty,
      );
    });

    test('an unrecognized opKey reads as nothing configured', () {
      expect(existingPickedFields('tags', config()), isEmpty);
    });

    test('popular: a blank itemSelector reads as unconfigured, even though '
        'titleSelector/urlSelector/coverSelector all have non-blank schema '
        'defaults that would otherwise look picked', () {
      expect(existingPickedFields('popular', config()), isEmpty);
    });

    test('popular: a set itemSelector seeds the whole block', () {
      final fields = existingPickedFields(
        'popular',
        config(
          popular: {
            'itemSelector': 'article.card',
            'titleSelector': 'h3',
            'titleAttr': '',
            'urlSelector': 'a.link',
            'urlAttr': 'href',
            'coverSelector': 'img.cover',
            'coverAttr': 'data-src',
          },
        ),
      );
      expect(fields, {
        'itemSelector': 'article.card',
        'titleSelector': 'h3',
        'urlSelector': 'a.link',
        'urlAttr': 'href',
        'coverSelector': 'img.cover',
        'coverAttr': 'data-src',
      });
      expect(fields.containsKey('titleAttr'), isFalse);
    });

    test('chapters: a blank itemSelector reads as unconfigured', () {
      expect(existingPickedFields('chapters', config()), isEmpty);
    });

    test('chapters: a set itemSelector seeds the block; dateSelector only '
        'when non-blank', () {
      expect(
        existingPickedFields(
          'chapters',
          config(
            chapters: {
              'itemSelector': 'li.chapter',
              'nameSelector': 'span.name',
              'urlSelector': 'a',
              'urlAttr': 'href',
            },
          ),
        ),
        {
          'itemSelector': 'li.chapter',
          'nameSelector': 'span.name',
          'urlSelector': 'a',
          'urlAttr': 'href',
        },
      );
      expect(
        existingPickedFields(
          'chapters',
          config(
            chapters: {
              'itemSelector': 'li.chapter',
              'nameSelector': 'span.name',
              'urlSelector': 'a',
              'urlAttr': 'href',
              'dateSelector': 'time',
            },
          ),
        )['dateSelector'],
        'time',
      );
    });

    test('pages: a blank imageSelector reads as unconfigured', () {
      expect(existingPickedFields('pages', config()), isEmpty);
    });

    test('pages: a set imageSelector seeds imageSelector + imageAttr', () {
      expect(
        existingPickedFields(
          'pages',
          config(pages: {'imageSelector': 'img.page', 'imageAttr': 'src'}),
        ),
        {'imageSelector': 'img.page', 'imageAttr': 'src'},
      );
    });

    test('details: nothing configured seeds nothing', () {
      expect(existingPickedFields('details', config()), isEmpty);
    });

    test('details: each field is gated independently, unlike the other '
        'blocks — a lone titleSelector seeds only itself', () {
      expect(
        existingPickedFields(
          'details',
          config(details: {'titleSelector': 'h1'}),
        ),
        {'titleSelector': 'h1'},
      );
    });

    test('details: coverSelector/genreSelector bring their *Attr companion '
        'along only when set', () {
      expect(
        existingPickedFields(
          'details',
          config(details: {'coverSelector': 'img', 'coverAttr': 'data-src'}),
        ),
        {'coverSelector': 'img', 'coverAttr': 'data-src'},
      );
      expect(
        existingPickedFields(
          'details',
          config(details: {'genreSelector': 'a.tag', 'genreAttr': ''}),
        ),
        {'genreSelector': 'a.tag'},
      );
    });
  });
}

/// Forces MaterialScrollBehavior.buildScrollbar down its desktop branch
/// (auto-wrap vertical scrollables in a Scrollbar backed by
/// PrimaryScrollController when no explicit controller is given) without
/// touching debugDefaultTargetPlatformOverride, which also engages real
/// platform channels flutter_test can't service.
class _DesktopScrollbarBehavior extends MaterialScrollBehavior {
  @override
  TargetPlatform getPlatform(BuildContext context) => TargetPlatform.macOS;
}
