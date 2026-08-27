// Builds a workspace's curated extension index from its per-extension source
// files (`<ws>/extensions/`): the single source of truth for hand-authored
// sources. Operates on the workspace selected by --workspace / WORKSPACE
// (default workspaces/default); see tool/workspace.dart.
//
//   dart run tool/build_repo.dart                       # default workspace
//   dart run tool/build_repo.dart --workspace nsfw      # another workspace
//   dart run tool/build_repo.dart --check               # verify up to date (CI)
//
// Each `extensions/*.json` is one index entry
// `{name, pkg, version, lang, nsfw, sources:[...]}`. Every source is parsed
// through the real engine (`ExtensionInfo.fromJson` → `AnySourceConfig.fromJson`,
// plus a lossless round-trip), validated against `docs/source-config.schema.json`
// (which the models can't do for themselves: an unknown key isn't an error to
// a `fromJson`, it is simply never read — so a misspelled selector key would
// otherwise build, ship, and quietly match nothing), and every selector string
// is checked with
// `selector_lint.dart` against the engine's actual CSS support surface, so a
// typo, an unsupported pseudo-class, or an unrepresentable selector fails the
// build instead of shipping and only surfacing live. Entries are de-duped by
// pkg and sorted by name, then written **minified** to `repo/index.min.json`:
// the index served to any app/repository client. Authored key order is
// preserved (what you write is what ships, sans whitespace). The bulk
// `repo/generated-index.min.json` (a collection's bulk-generated tier) is
// separate and untouched.
//
// The built index is the artifact `task serve`/`task publish` expose; nothing
// is bundled into consuming apps; they install it from a repository URL.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:koni_dojo/koni_dojo.dart';

import 'schema_lint.dart';
import 'selector_lint.dart';
import 'workspace.dart';

/// A stable, engine-independent stand-in for a hand-maintained semver:
/// truncated SHA-256 of [bytes] (the extension file exactly as committed).
/// See `ExtensionInfo.version`'s doc for why this hashes raw file bytes
/// rather than the parsed/reserialized entry.
String _contentHash(List<int> bytes) =>
    sha256.convert(bytes).toString().substring(0, 16);

/// [fileName]'s last-committed date (`YYYY-MM-DD`, committer date) within
/// [ws]'s git checkout, or '' when it can't be determined (no git installed,
/// not a git checkout, or the file is new/uncommitted); callers fall back
/// to today's date in that case, same as a brand-new file effectively is.
String _lastCommittedDate(Workspace ws, String fileName) {
  try {
    final result = Process.runSync('git', [
      'log',
      '-1',
      '--format=%cs',
      '--',
      'extensions/$fileName',
    ], workingDirectory: ws.root);
    if (result.exitCode != 0) return '';
    return (result.stdout as String).trim();
  } catch (_) {
    return '';
  }
}

/// Whether any of [config]'s operation pipelines contains a `js` step.
bool _usesJsStep(AnySourceConfig config) {
  if (config is! SourceConfig) return false;
  final pipelines = <Pipeline?>[
    config.popular.steps,
    config.latest?.steps,
    config.search?.steps,
    config.details.steps,
    config.chapters.steps,
    config.pages.steps,
  ];
  return pipelines.any((p) => p != null && p.steps.any((s) => s.js != null));
}

void main(List<String> args) {
  final ws = Workspace.resolve(args);
  final check = args.contains('--check');
  final dir = Directory(ws.extensionsDir);
  if (!dir.existsSync()) {
    stderr.writeln(
      'No ${ws.extensionsDir}/ directory (workspace "${ws.name}" — run from '
      'the project root, or check --workspace).',
    );
    exit(1);
  }

  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  // Compiled once: it walks the whole schema document, and this loop runs a
  // few hundred times.
  final schema = ExtensionSchema.load('docs/source-config.schema.json');

  final entries = <Map<String, dynamic>>[];
  final byPkg = <String, String>{}; // pkg -> filename, for duplicate detection
  var errors = 0;

  for (final f in files) {
    final fileName = f.uri.pathSegments.last;
    final Map<String, dynamic> entry;
    try {
      entry = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (e) {
      print('✗ $fileName: not a JSON object ($e)');
      errors++;
      continue;
    }
    /* Schema gate, before the engine parses anything: the models silently
     * ignore a key they don't know, so a misspelled selector key is a config
     * that builds, ships, and returns nothing on a real site. The schema
     * declares `additionalProperties: false` everywhere, which is what makes
     * that an error instead of a shrug. Run against the file as authored, so
     * the message points at what is actually written there. */
    final schemaIssues = lintExtensionSchema(entry, fileName, schema);
    if (schemaIssues.isNotEmpty) {
      for (final issue in schemaIssues) {
        print('✗ $fileName: $issue');
      }
      errors++;
      continue;
    }
    try {
      final ext = ExtensionInfo.fromJson(entry);
      if (ext.name.isEmpty || ext.pkg.isEmpty || ext.sources.isEmpty) {
        print('✗ $fileName: missing name/pkg/sources');
        errors++;
        continue;
      }
      // A lossless round-trip catches anything fromJson tolerated but the
      // runtime can't express.
      var jsGateOk = true;
      for (final s in ext.sources) {
        final cfg = AnySourceConfig.fromJson(s.toJson());
        // Trust gate: a `js` step runs sandboxed remote code, so it's allowed
        // only when the source explicitly opts in with `"js": true`.
        if (_usesJsStep(cfg) && !(cfg is SourceConfig && cfg.js)) {
          print(
            '✗ $fileName: uses a `js` pipeline step but is missing '
            '`"js": true` (required to run sandboxed JavaScript)',
          );
          jsGateOk = false;
        }
      }
      if (!jsGateOk) {
        errors++;
        continue;
      }
      // Selector gate: every *Selector/selector string must parse and stay
      // within extended_selectors.dart's supported surface, so a typo or
      // unsupported pseudo-class fails the build instead of shipping and
      // only surfacing (as a crash or silent zero results) the first time a
      // real page exercises it.
      final selectorIssues = lintExtensionSelectors(entry, fileName);
      if (selectorIssues.isNotEmpty) {
        for (final issue in selectorIssues) {
          print('✗ $fileName: $issue');
        }
        errors++;
        continue;
      }
      final dupe = byPkg[ext.pkg];
      if (dupe != null) {
        print('✗ $fileName: duplicate pkg ${ext.pkg} (also in $dupe)');
        errors++;
        continue;
      }
      // Inline the captured icon (extensions/icons/<slug>.png, slug = the
      // config's filename stem) as a data: URI on each source, so the app shows
      // it offline. Authored files stay icon-free; the icon lives as a committed
      // PNG and is embedded only here, in the built index.
      final slug = fileName.replaceFirst(RegExp(r'\.json$'), '');
      final iconFile = File('${ws.iconsDir}/$slug.png');
      if (iconFile.existsSync()) {
        final dataUri =
            'data:image/png;base64,${base64Encode(iconFile.readAsBytesSync())}';
        for (final s
            in (entry['sources'] as List).cast<Map<String, dynamic>>()) {
          s['icon'] = dataUri;
        }
      }
      // Stamp a content-derived version + last-changed date, overriding
      // whatever `version` the curator's file happens to still carry (see
      // `ExtensionInfo.version`'s doc: hand-authored semver is retired in
      // favor of this). Hashes the file exactly as committed, read fresh
      // here rather than reusing `entry`, deliberately independent of the
      // icon inlining and any other build-time mutation above.
      entry['version'] = _contentHash(f.readAsBytesSync());
      final date = _lastCommittedDate(ws, fileName);
      entry['updatedAt'] = date.isNotEmpty
          ? date
          : DateTime.now().toIso8601String().substring(0, 10);
      byPkg[ext.pkg] = fileName;
      entries.add(entry);
      final n = ext.sources.length;
      print('✓ ${ext.name}  ·  ${ext.pkg}  ($n source${n == 1 ? '' : 's'})');
    } catch (e) {
      print('✗ $fileName: $e');
      errors++;
    }
  }

  if (errors > 0) {
    stderr.writeln(
      '\n$errors invalid extension(s); not writing ${ws.repoIndex}.',
    );
    exit(1);
  }

  entries.sort(
    (a, b) => (a['name'] as String).toLowerCase().compareTo(
      (b['name'] as String).toLowerCase(),
    ),
  );
  final minified = jsonEncode(entries);

  final out = File(ws.repoIndex);
  if (check) {
    final jsonOk = out.existsSync() && out.readAsStringSync() == minified;
    if (!jsonOk) {
      stderr.writeln(
        '\n${ws.repoIndex} is out of date — run: dart run tool/build_repo.dart',
      );
      exit(1);
    }
    print('\n${ws.repoIndex} up to date (${entries.length} extensions).');
    return;
  }
  Directory(ws.repoDir).createSync(recursive: true);
  out.writeAsStringSync(minified);
  print('\nWrote ${ws.repoIndex} — ${entries.length} extensions.');
}
