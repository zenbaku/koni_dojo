// A **workspace**: the project's first-class unit of a source collection.
//
// A workspace is any directory with this layout:
//
//   <ws>/workspace.json     manifest: {name, description, servePort, publish}
//   <ws>/extensions/*.json  curated, hand-authored source configs (+ icons/)
//   <ws>/repo/index.min.json          the built, servable index
//   <ws>/repo/generated-index.min.json  the dormant (bulk-generated) tier
//   <ws>/curation/archived.json       sources deliberately not pursued
//   <ws>/sources-catalog.md           this collection's curation log/status
//
// This repo ships no workspace of its own (`workspaces/` is gitignored); the
// data lives in its own repo, conventionally the sibling `../koni_dojo_repo/`,
// which the Taskfile passes as the default `WORKSPACE`. Every tool resolves a
// workspace from `--workspace <name|path>` (a bare name → `workspaces/<name>`),
// the `WORKSPACE` env var, or, absent both, the `workspaces/default` fallback.
import 'dart:convert';
import 'dart:io';

const _defaultWorkspace = 'workspaces/default';

class Workspace {
  Workspace(this.root, this.manifest);

  /// The workspace directory, as given (relative or absolute).
  final String root;

  /// Parsed workspace.json (empty map if the file is absent).
  final Map<String, dynamic> manifest;

  /// Resolves the workspace for a tool invocation from (in priority order):
  /// a `--workspace <name|path>` / `--workspace=<name|path>` flag, the
  /// `WORKSPACE` env var (the Taskfile sets it to `../koni_dojo_repo`, so
  /// `task` commands default there), or the `workspaces/default` fallback. A
  /// spec with no path separator is treated as a name under `workspaces/`.
  factory Workspace.resolve(List<String> args) {
    String? spec;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.startsWith('--workspace=')) {
        spec = a.substring('--workspace='.length);
      } else if (a == '--workspace' && i + 1 < args.length) {
        spec = args[i + 1];
      }
    }
    spec ??= Platform.environment['WORKSPACE'];
    spec ??= _defaultWorkspace;

    final isPath =
        spec == '.' ||
        spec.contains('/') ||
        spec.contains(Platform.pathSeparator);
    final dir = isPath ? spec : 'workspaces/$spec';

    final mf = File('$dir/workspace.json');
    final manifest = mf.existsSync()
        ? jsonDecode(mf.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    return Workspace(dir, manifest);
  }

  /// Removes `--workspace <x>` / `--workspace=<x>` from [args] so a tool's own
  /// argument parsing (positional ids, other flags) is unaffected.
  static List<String> stripArgs(List<String> args) {
    final out = <String>[];
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--workspace') {
        i++; // also skip its value
        continue;
      }
      if (a.startsWith('--workspace=')) continue;
      out.add(a);
    }
    return out;
  }

  bool get exists => Directory(root).existsSync();

  String get name =>
      manifest['name'] as String? ??
      root.split('/').where((s) => s.isNotEmpty).last;

  String get extensionsDir => '$root/extensions';
  String get iconsDir => '$root/extensions/icons';
  String get repoDir => '$root/repo';
  String get repoIndex => '$root/repo/index.min.json';
  String get generatedIndex => '$root/repo/generated-index.min.json';
  String get archivedPath => '$root/curation/archived.json';
  String get catalogPath => '$root/sources-catalog.md';

  /// LAN serve port (manifest `servePort`, default 18437).
  int get servePort => (manifest['servePort'] as num?)?.toInt() ?? 18437;

  /// Cloudflare Pages project for `task publish` (manifest `publish.cfProject`).
  String? get publishProject =>
      (manifest['publish'] as Map?)?['cfProject'] as String?;
}
