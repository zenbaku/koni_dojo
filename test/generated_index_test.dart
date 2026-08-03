import 'dart:convert';
import 'dart:io';

import 'package:koni_dojo/koni_dojo.dart';
import 'package:test/test.dart';

/// A workspace's generated index is machine-produced (bulk-converted rather
/// than hand-authored), so its structural invariants are pinned here: every entry
/// must parse through the real model, carry the reader-critical blocks, and
/// survive a JSON round trip. Runs against a synthetic fixture; the real
/// collection lives in the separate data repo (koni_dojo_repo).
void main() {
  final file = File('test/fixtures/workspace/repo/generated-index.min.json');
  if (!file.existsSync()) return;

  final entries = (jsonDecode(file.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('generated index is non-empty and well-formed', () {
    expect(entries, isNotEmpty);
    final pkgs = entries.map((e) => e['pkg']).toSet();
    expect(pkgs.length, entries.length, reason: 'pkgs must be unique');
  });

  test('every generated source parses and carries the reader pipeline', () {
    var sources = 0;
    for (final raw in entries) {
      final ext = ExtensionInfo.fromJson(raw);
      expect(ext.name, isNotEmpty);
      expect(ext.sources, isNotEmpty, reason: '${ext.pkg} has no sources');
      for (final any in ext.sources) {
        sources++;
        expect(any.id, isNotEmpty, reason: '${ext.pkg} empty id');
        expect(any.baseUrl, startsWith('http'), reason: '${ext.pkg} baseUrl');
        // The reading path must be expressible, in either dialect.
        if (any is SourceConfig) {
          // Expressible via the sugar fields or an explicit `steps` pipeline.
          expect(
            any.popular.itemSelector.isNotEmpty || any.popular.steps != null,
            isTrue,
            reason: '${ext.pkg} popular has no items',
          );
          expect(
            any.chapters.itemSelector.isNotEmpty || any.chapters.steps != null,
            isTrue,
            reason: '${ext.pkg} chapters has no items',
          );
          final hasPages =
              any.pages.imageSelector.isNotEmpty ||
              any.pages.script != null ||
              any.pages.steps != null;
          expect(hasPages, isTrue, reason: '${ext.pkg} has no page source');
        } else if (any is ApiSourceConfig) {
          expect(
            any.pages.path.isNotEmpty || any.pages.steps != null,
            isTrue,
            reason: '${ext.pkg} no pages path',
          );
        }
        // Round trip is lossless.
        expect(AnySourceConfig.fromJson(any.toJson()).toJson(), any.toJson());
      }
    }
    expect(sources, greaterThanOrEqualTo(entries.length));
  });
}
