// Live end-to-end probe for a single source config: the dev loop for
// developing/refining one extension against its real site, entirely within
// this package (no Flutter, no app checkout). Drives `probeSource`
// (source_probe.dart), the same smoke test the Extension Lab's "Full probe"
// action runs, so a config checks out identically from a terminal or the app.
//
//   dart run tool/live_probe.dart /tmp/foo.json
//   CONFIG_PATH=/tmp/foo.json dart run tool/live_probe.dart
//
// Hits the network; not part of `dart test`.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:koni_dojo/koni_dojo.dart';

import 'node_js_runner.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty
      ? args.first
      : Platform.environment['CONFIG_PATH'];
  if (path == null || path.isEmpty) {
    print('Usage: dart run tool/live_probe.dart <config.json>');
    print('  (or set CONFIG_PATH=<config.json>)');
    exit(1);
  }

  final json = jsonDecode(File(path).readAsStringSync());
  final entry = json is List ? json.first : json;
  final source = (entry is Map && entry.containsKey('sources'))
      ? (entry['sources'] as List).first
      : entry;
  // Both dialects: `"type": "api"` (ApiSourceConfig) or absent/
  // anything else (SourceConfig, the HTML scraper); was previously always
  // parsed+built as SourceConfig regardless, so an API config silently ran
  // through the wrong engine (a `FormatException` from a CSS-selector call
  // on JSON, or worse, a false-negative pass on coincidentally-matching
  // fields).
  final cfg = AnySourceConfig.fromJson(source as Map<String, dynamic>);
  // `js: true` configs need a runtime; use Node when available (see
  // node_js_runner.dart), matching how the app/playground inject QuickJS.
  // Only the HTML dialect has a `js` step capability at all.
  final needsJs = cfg is SourceConfig && cfg.js;
  final jsRunner = needsJs ? NodeJsRunner.detect() : null;
  if (needsJs && jsRunner == null) {
    print(
      'note: config has js:true but `node` is not on PATH — js steps will fail',
    );
  }
  final src = switch (cfg) {
    ApiSourceConfig() => apiSource(cfg, client: http.Client()),
    SourceConfig() => htmlSource(
      cfg,
      client: http.Client(),
      jsRunner: jsRunner,
    ),
  };

  print('── ${cfg.name} <${cfg.baseUrl}> ──');
  final result = await probeSource(src);

  final pop = result.popular ?? const [];
  print(
    'POPULAR: ${pop.length} items'
    '${pop.isEmpty ? "" : "; first='${pop.first.title}' "
              "url=${pop.first.url} cover=${pop.first.thumbnailUrl}"}',
  );

  final details = result.details;
  if (details != null) {
    print(
      'DETAILS: title="${details.title}" author="${details.author}" '
      'status=${details.status} genres=${details.genres.length} '
      'desc=${details.description.length}b cover=${details.thumbnailUrl}',
    );
  }

  final chapters = result.chapters;
  if (chapters != null) {
    print(
      'CHAPTERS: ${chapters.length}'
      '${chapters.isEmpty ? "" : "; first='${chapters.first.name}' "
                "url=${chapters.first.url}"}',
    );
  }

  final pages = result.pages;
  if (pages != null) {
    // probeSource samples first/middle/last chapters until one yields pages.
    print(
      'PAGES: ${pages.length}'
      '${pages.isEmpty ? "" : "; first=${pages.first.url}"}',
    );
  }

  // Best-effort: only attempted when the source has a `tag` listing;
  // never fails the probe, so this alone is never why `!result.passed`.
  final tagTried = result.tagTried;
  if (tagTried != null) {
    final tag = result.tag;
    print(
      'TAG: tried "$tagTried" -> '
      '${tag == null ? "failed (see catalog/config)" : "${tag.length} items"}',
    );
  }

  if (!result.passed) {
    print('FAIL at ${result.failedStage}: ${result.error}');
    exit(1);
  }
}
