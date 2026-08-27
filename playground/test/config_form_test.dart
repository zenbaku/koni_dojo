import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konimanga_playground/config_form.dart';

/// `config_form.dart`'s Form editor has no schema to introspect at runtime:
/// its field coverage is two hand-maintained lists (`sourceCardKnownFields`,
/// `operationKeys`) that must be kept in sync with the engine's actual config
/// model by hand. That's exactly how `warmImageByUrl` went missing from the
/// form after landing in `SourceConfig`: the model gained a field, the form
/// didn't. `docs/source-config.schema.json` is the other hand-maintained
/// artifact describing the same model (for editor autocomplete/validation on
/// `extensions/*.json`). This test cross-checks the two, so the next time a
/// field is added to one and not the other, this fails instead of silently
/// drifting again.
void main() {
  late Map<String, dynamic> schema;

  setUpAll(() {
    // Tests run with the package root (`playground/`) as cwd.
    final file = File('../docs/source-config.schema.json');
    schema = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  Map<String, dynamic> defs(String name) =>
      ((schema[r'$defs'] as Map)[name] as Map)['properties']
          as Map<String, dynamic>;

  Set<String> booleanProperties(Map<String, dynamic> properties) => {
    for (final entry in properties.entries)
      if (entry.value is Map && (entry.value as Map)['type'] == 'boolean')
        entry.key,
  };

  test('every boolean top-level field in the schema has a switch in the form '
      '(an optional flag that defaults to false is omitted from the JSON '
      'entirely, so it needs an explicit always-visible switch — a generic '
      "fallback over the JSON's present keys would never surface it)", () {
    final booleans = {
      ...booleanProperties(defs('sourceConfig')),
      ...booleanProperties(defs('apiSourceConfig')),
    };
    expect(
      booleans.difference(sourceCardKnownFields),
      isEmpty,
      reason:
          'add a switch for these in ConfigForm._sourceCard (see how '
          'webview/warmImageByUrl/js are wired) and add them to '
          'sourceCardKnownFields',
    );
  });

  test("sourceCardKnownFields doesn't carry a stale entry — every field it "
      'claims to handle is a real top-level property on at least one dialect '
      "(the schema is ground truth for what exists; a name that's drifted "
      "away from a renamed/removed model field would otherwise silently hide "
      'a JSON key from the form with no widget actually rendering it)', () {
    final allProps = {
      ...defs('sourceConfig').keys,
      ...defs('apiSourceConfig').keys,
    };
    expect(
      sourceCardKnownFields.difference(allProps),
      isEmpty,
      reason:
          'these are in ConfigForm.sourceCardKnownFields but not in the '
          'schema — either the schema is missing them, or the form is '
          'silently swallowing a field that no longer exists',
    );
  });
  group('webviewOps', () {
    /* The drift guard above only reaches *boolean* top-level fields, and this
     * one is an array — so nothing in the schema cross-check would notice if
     * the control stopped working. It matters more than most: the difference
     * between an operation that renders and one that doesn't is a whole
     * browser page load, and the editor is where that gets typed. */
    String config({String? webviewOps}) => jsonEncode({
      'id': 'x',
      'name': 'X',
      'baseUrl': 'https://example.test',
      'webview': true,
      if (webviewOps != null) 'webviewOps': jsonDecode(webviewOps),
      'popular': {'path': '/p', 'itemSelector': 'a'},
      'chapters': {'itemSelector': 'li'},
      'pages': {'imageSelector': 'img'},
    });

    Future<String?> mount(WidgetTester tester, String text) async {
      String? emitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(text: text, onChanged: (v) => emitted = v),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return emitted;
    }

    Map<String, dynamic> sourceOf(String json) =>
        jsonDecode(json) as Map<String, dynamic>;

    testWidgets('absent is off, and shows no chips to mistake for an answer', (
      tester,
    ) async {
      await mount(tester, config());
      expect(
        find.text('Narrow to specific operations (webviewOps)'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.ancestor(
                of: find.text('Narrow to specific operations (webviewOps)'),
                matching: find.byType(SwitchListTile),
              ),
            )
            .value,
        isFalse,
      );
      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('an empty list is a real answer, not the absent one', (
      tester,
    ) async {
      /* `[]` says no operation needs a rendered DOM — which is the shape that
       * took a real source off the render tab entirely. A control that could
       * not tell it from an absent key would round-trip it back to "render
       * everything" just by opening the form. */
      await mount(tester, config(webviewOps: '[]'));
      expect(find.byType(FilterChip), findsWidgets);
      expect(
        tester
            .widgetList<FilterChip>(find.byType(FilterChip))
            .where((c) => c.selected),
        isEmpty,
      );
    });

    testWidgets('a named operation shows selected, and stays named', (
      tester,
    ) async {
      await mount(tester, config(webviewOps: '["chapters"]'));
      final selected = tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .where((c) => c.selected)
          .map((c) => (c.label as Text).data)
          .toList();
      expect(selected, ['chapters']);
    });

    testWidgets('turning it on writes an empty list, not a bare true', (
      tester,
    ) async {
      /* `webview` stays a boolean for old engines and the narrowing rides in
       * its own key. An engine that predates webviewOps parses `webview` with
       * a hard cast and drops the whole extension when it is not a bool, so
       * the editor writing the wrong shape is silent breakage downstream. */
      String? emitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(text: config(), onChanged: (v) => emitted = v),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('Narrow to specific operations (webviewOps)'),
          matching: find.byType(SwitchListTile),
        ),
      );
      await tester.pumpAndSettle();

      expect(sourceOf(emitted!)['webviewOps'], isEmpty);
      expect(sourceOf(emitted!)['webview'], isTrue);
    });

    testWidgets('picking chips writes them in the enum\'s order', (
      tester,
    ) async {
      String? emitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigForm(
              text: config(webviewOps: '[]'),
              onChanged: (v) => emitted = v,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tapped out of order on purpose: the JSON must not reshuffle itself
      // between edits just because of the order they were clicked.
      await tester.tap(find.widgetWithText(FilterChip, 'pages'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'chapters'));
      await tester.pumpAndSettle();

      expect(sourceOf(emitted!)['webviewOps'], ['chapters', 'pages']);
      expect(
        sourceOf(emitted!)['webview'],
        isTrue,
        reason: 'narrowing must not turn the boolean off',
      );
    });
  });
}
