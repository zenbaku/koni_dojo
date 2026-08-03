import 'dart:convert';
import 'dart:io';

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

  test(
    'every boolean top-level field in the schema has a switch in the form '
    '(an optional flag that defaults to false is omitted from the JSON '
    'entirely, so it needs an explicit always-visible switch — a generic '
    "fallback over the JSON's present keys would never surface it)",
    () {
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
    },
  );

  test(
    "sourceCardKnownFields doesn't carry a stale entry — every field it "
    'claims to handle is a real top-level property on at least one dialect '
    "(the schema is ground truth for what exists; a name that's drifted "
    "away from a renamed/removed model field would otherwise silently hide "
    'a JSON key from the form with no widget actually rendering it)',
    () {
      final allProps = {...defs('sourceConfig').keys, ...defs('apiSourceConfig').keys};
      expect(
        sourceCardKnownFields.difference(allProps),
        isEmpty,
        reason:
            'these are in ConfigForm.sourceCardKnownFields but not in the '
            'schema — either the schema is missing them, or the form is '
            'silently swallowing a field that no longer exists',
      );
    },
  );
}
