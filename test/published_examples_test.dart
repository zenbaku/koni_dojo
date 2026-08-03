import 'dart:convert';
import 'dart:io';

import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// Build-integrity tests for `tool/build_repo.dart`: `repo/index.min.json` is
/// the union of a workspace's `extensions/*.json` (with icons inlined), and
/// every config round-trips losslessly through the engine. Runs against a
/// synthetic fixture workspace; the real collection lives in the separate
/// data repo (koni_dojo_repo).
void main() {
  const ws = 'test/fixtures/workspace';

  List<File> sourceFiles() => Directory('$ws/extensions')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList();

  // Mirrors tool/build_repo.dart: inline extensions/icons/<slug>.png as a data:
  // URI on each source, so the union comparison covers the captured icons too.
  Map<String, dynamic> withInlinedIcon(File f) {
    final entry = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final slug = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');
    final icon = File('$ws/extensions/icons/$slug.png');
    if (icon.existsSync()) {
      final dataUri =
          'data:image/png;base64,${base64Encode(icon.readAsBytesSync())}';
      for (final s in (entry['sources'] as List).cast<Map<String, dynamic>>()) {
        s['icon'] = dataUri;
      }
    }
    return entry;
  }

  test('published index is the union of the extensions/ source files', () {
    final expected = [for (final f in sourceFiles()) withInlinedIcon(f)];
    final published =
        jsonDecode(File('$ws/repo/index.min.json').readAsStringSync()) as List;
    // Compare by pkg so neither ordering nor formatting matters. If this fails,
    // the index is stale. Run: dart run tool/build_repo.dart
    //
    // `version`/`updatedAt` are excluded from both sides: build_repo.dart
    // stamps these from the file's own content hash + git history (see its
    // doc comment), not from whatever the raw extensions/ file happens to
    // carry; this test is about content union, not about re-verifying that
    // stamping (which `tool/build_repo.dart`'s own live run already proves).
    Map<String, Object?> byPkg(List entries) => {
      for (final e in entries)
        (e as Map)['pkg'] as String:
            (Map<String, dynamic>.from(e)
              ..remove('version')
              ..remove('updatedAt')),
    };
    expect(byPkg(published), byPkg(expected));
  });

  test('every extensions/ source parses + round-trips through the engine', () {
    final files = sourceFiles();
    expect(files, isNotEmpty);
    for (final f in files) {
      final entry = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final ext = ExtensionInfo.fromJson(entry); // throws on a malformed config
      expect(ext.sources, isNotEmpty, reason: f.path);
      for (final s in ext.sources) {
        expect(
          AnySourceConfig.fromJson(s.toJson()).toJson(),
          s.toJson(),
          reason: '${f.path} is not a lossless round-trip',
        );
      }
    }
  });

  test('build inlines a captured icon as a data: URI on each source', () {
    // The fixture's delta config has a committed icon; alpha does not.
    final published =
        (jsonDecode(File('$ws/repo/index.min.json').readAsStringSync()) as List)
            .cast<Map<String, dynamic>>();
    final delta = published.firstWhere(
      (e) => e['pkg'].toString().contains('delta'),
    );
    final src = (delta['sources'] as List).single as Map<String, dynamic>;
    expect(src['icon'], startsWith('data:image/png;base64,'));

    final alpha = published.firstWhere(
      (e) => e['pkg'] == 'app.koni.fixture.alpha',
    );
    expect((alpha['sources'] as List).single, isNot(contains('icon')));
  });
}
