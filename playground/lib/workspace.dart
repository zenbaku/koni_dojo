// A workspace loaded whole: a directory with the standard layout
// (extensions/, repo/, curation/, sources-catalog.md, workspace.json), e.g.
// <checkout>/workspaces/default or any external collection. Rows come from
// several tiers: the curated `extensions/*.json` (active), hand-authored
// `prototypes/*.json` (prototyping — a source being actively worked on,
// saved but not yet ready to ship, kept out of `extensions/` so it can't
// accidentally reach a production build), the bulk
// `repo/generated-index.min.json` (dormant: bulk-generated, live-unverified),
// and `curation/candidates.json` (candidate — known to exist, not converted
// yet), annotated with the per-source status/notes from the workspace's
// `sources-catalog.md`. The playground registers several workspaces and
// switches between them (see the registry helpers at the bottom of this file).
// (Nothing is Dart-bundled anymore; the API-dialect reference config lives
// in extensions/ like every other source.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:koni_dojo/koni_dojo.dart';

import 'cloudflare.dart';
import 'probe.dart';
import 'probe_store.dart';

enum Tier { active, prototyping, dormant, candidate }

/// How worth pursuing next a `Tier.candidate` row is, from
/// `curation/candidate_priority.json` (see a workspace's own ranking tool).
/// `unranked` is the default for anything not in that file: active/dormant
/// rows, or a candidate the last ranking run hasn't covered yet. Declared
/// highest-first so `PriorityTier.index` sorts "best first" ascending, the
/// same convention [Tier] already uses.
enum PriorityTier { highest, high, medium, low, unranked }

/// Why a candidate ranked where it did: [reasons] is the additive,
/// human-readable score breakdown a workspace's own ranking tool logs, shown
/// verbatim in the table's tooltip rather than re-deriving an explanation.
class PriorityInfo {
  const PriorityInfo({
    required this.score,
    required this.tier,
    required this.reasons,
  });

  factory PriorityInfo.fromJson(Map<String, dynamic> json) => PriorityInfo(
    score: (json['score'] as num?)?.toInt() ?? 0,
    tier: PriorityTier.values.firstWhere(
      (t) => t.name == json['tier'],
      orElse: () => PriorityTier.unranked,
    ),
    reasons: (json['reasons'] as List?)?.cast<String>() ?? const [],
  );

  final int score;
  final PriorityTier tier;
  final List<String> reasons;
}

/// Status + caveats for one source id, from the catalog's Tier 1 table.
class CatalogInfo {
  const CatalogInfo({required this.status, required this.notes});

  final String status;
  final String notes;
}

/// Parses a workspace's sources-catalog.md Tier 1 markdown table, keyed by source
/// id: the 'Status' and 'Caveats / notes' columns. Sparse by design: only
/// the manually-curated first batch has prose; the UI says "no notes" rather
/// than inventing content.
Map<String, CatalogInfo> parseCatalog(String markdown) {
  final infos = <String, CatalogInfo>{};
  final idPattern = RegExp(r'`([a-z0-9_-]+)`');
  final separatorRow = RegExp(r'^[-: ]*$');
  for (var line in const LineSplitter().convert(markdown)) {
    line = line.trim();
    if (!line.startsWith('|')) continue;
    final parts = line.split('|');
    final cells = parts
        .sublist(1, parts.length - 1)
        .map((c) => c.trim())
        .toList();
    if (cells.length != 8 ||
        cells[0] == 'Source' ||
        separatorRow.hasMatch(cells[0])) {
      continue;
    }
    final m = idPattern.firstMatch(cells[1]);
    if (m != null && (cells[6].isNotEmpty || cells[7].isNotEmpty)) {
      infos[m.group(1)!] = CatalogInfo(
        status: _stripLeadingEmoji(cells[6]),
        notes: cells[7],
      );
    }
  }
  return infos;
}

/// Drops a leading run of emoji + whitespace from a catalog status string (the
/// markdown authors them as "✅ Working" etc.): the UI conveys pass/fail with
/// its own icons and colour, no emoji.
String _stripLeadingEmoji(String s) => s
    .replaceFirst(RegExp(r'^[\s\u{0080}-\u{10FFFF}]+', unicode: true), '')
    .trim();

/// One source, one table row. Extensions with several sources produce a row
/// per source; a file that fails to parse still produces a row so the
/// breakage is visible instead of silently missing.
class SourceRow {
  SourceRow({
    required this.tier,
    this.file,
    this.entryJson,
    required this.extName,
    required this.pkg,
    required this.version,
    required this.nsfw,
    this.config,
    this.parseError,
    required this.rawSource,
    this.iconFile,
    this.catalog,
  });

  final Tier tier;

  /// The authored extensions/*.json this row came from; null for
  /// dormant rows (which have no editable file).
  final File? file;

  /// The full index entry (dormant rows), for pretty-printing in the editor.
  final Map<String, dynamic>? entryJson;

  final String extName;
  final String pkg;
  final String version;
  final bool nsfw;

  /// Engine-parsed config; null when [parseError] is set.
  final AnySourceConfig? config;
  final String? parseError;

  /// The authored JSON of this one source, as written.
  final Map<String, dynamic> rawSource;

  final File? iconFile;
  final CatalogInfo? catalog;

  /// Why this source was archived (curation/archived.json), or null when it
  /// isn't. Archived = deliberately not pursued (site broken, not worth the
  /// hassle), distinct from dormant-but-promotable.
  String? archivedReason;

  bool get archived => archivedReason != null;

  /// How worth converting next this row is (curation/candidate_priority.json,
  /// see a workspace's own ranking tool), only ever set on `Tier.candidate`
  /// rows today, but joined onto every row the same way [catalog] is in case
  /// that changes. Null (not [PriorityTier.unranked]) means no ranking run
  /// has ever covered this id.
  PriorityInfo? priority;

  /// Shared across workspace refreshes (see [Workspace.refresh]) so re-reading
  /// files doesn't wipe probe outcomes.
  ProbeState probe = ProbeState();

  String get id => config?.id ?? rawSource['id'] as String? ?? '';
  String get name => config?.name ?? rawSource['name'] as String? ?? extName;
  String get lang => config?.lang ?? rawSource['lang'] as String? ?? '';
  String get baseUrl =>
      config?.baseUrl ?? rawSource['baseUrl'] as String? ?? '';
  String get engine => rawSource['type'] == 'api' ? 'api' : 'html';
  bool get webview => rawSource['webview'] == true;

  String? get iconDataUri {
    final icon = rawSource['icon'];
    return (icon is String && icon.startsWith('data:')) ? icon : null;
  }

  /// "1/s", "0.5/s": requests per second from the rateLimit block.
  String get rateLimitLabel {
    final rl = rawSource['rateLimit'];
    if (rl is! Map) return '';
    final req = rl['requests'];
    final per = rl['perMs'];
    if (req is! num || per is! num || per <= 0) return '';
    final perSec = req * 1000 / per;
    final isWhole = perSec == perSec.roundToDouble();
    return '${isWhole ? perSec.toInt() : perSec.toStringAsFixed(1)}/s';
  }

  /// Identity that survives a refresh.
  String get key => '${tier.name}|$pkg|$id';

  /// What the detail editor opens on: the authored file verbatim (active), or
  /// the pretty-printed index entry (dormant).
  String editorText() {
    if (file != null) return file!.readAsStringSync();
    return const JsonEncoder.withIndent('  ').convert(entryJson ?? rawSource);
  }
}

class Workspace extends ChangeNotifier {
  String? root;
  final List<SourceRow> rows = [];
  String? loadError;

  /// The opened workspace's manifest (workspace.json), empty if none.
  Map<String, dynamic> manifest = const {};

  /// Registered workspace directories (persisted), for the switcher.
  List<String> registered = [];

  /// Screen-safety switch: heavily blur every rendered cover/page image
  /// (press-and-hold to peek), so an NSFW source's images aren't visible
  /// over someone's shoulder while probing it. Global, not per-workspace,
  /// but persisted alongside the workspace registry since that's the app's
  /// only settings file.
  bool blurNsfw = loadBlurNsfw();

  void setBlurNsfw(bool value) {
    if (value == blurNsfw) return;
    blurNsfw = value;
    saveBlurNsfw(value);
    notifyListeners();
  }

  /// Source id → reason, from curation/archived.json: sources deliberately
  /// not pursued. Loaded on [refresh]; edited via [setArchived].
  Map<String, String> archived = {};

  /// Candidate id → priority, from curation/candidate_priority.json. Loaded
  /// on [refresh]; regenerated by a workspace's own ranking tool (no in-app
  /// editor: unlike [archived], this is a bulk-computed ranking, not a
  /// per-source hand annotation).
  Map<String, PriorityInfo> priority = {};

  bool probing = false;
  bool _cancelProbing = false;

  /// Display name of the opened workspace: manifest `name`, else the dir stem.
  String get name =>
      manifest['name'] as String? ??
      (root == null ? '' : root!.split('/').where((s) => s.isNotEmpty).last);

  /// A directory is a workspace if it has an extensions/ dir (the manifest is
  /// optional but recommended).
  static bool isWorkspace(String path) =>
      Directory('$path/extensions').existsSync();

  /// Opens [path] as a workspace and registers it (so the switcher lists it).
  /// A workspace directory has the standard layout (extensions/, repo/,
  /// curation/, sources-catalog.md, workspace.json).
  void open(String path) {
    root = path;
    refresh();
    if (loadError == null) {
      registered = registerWorkspace(path);
      saveCurrentWorkspace(path);
    }
  }

  /// Switches to an already-registered workspace.
  void switchTo(String path) => open(path);

  /// Drops [path] from the registry (does not touch disk). If it was current,
  /// the caller decides what to open next.
  void unregister(String path) {
    registered = unregisterWorkspace(path);
    notifyListeners();
  }

  /// Loads the registry (call once at startup, before [open]).
  void loadRegistry() {
    registered = loadRegisteredWorkspaces();
  }

  /// Re-reads everything from disk. Probe outcomes survive: rows are matched
  /// by (tier, pkg, id) and keep their ProbeState object.
  void refresh() {
    final previous = {for (final r in rows) r.key: r.probe};
    rows.clear();
    loadError = null;

    final rootDir = root;
    if (rootDir == null) return;
    final extDir = Directory('$rootDir/extensions');
    if (!extDir.existsSync()) {
      loadError =
          'Not a workspace: $rootDir has no extensions/ directory. Open a '
          'workspace directory (e.g. <checkout>/workspaces/default).';
      notifyListeners();
      return;
    }

    final manifestFile = File('$rootDir/workspace.json');
    manifest = manifestFile.existsSync()
        ? (jsonDecode(manifestFile.readAsStringSync()) as Map)
              .cast<String, dynamic>()
        : const {};

    // The catalog now lives inside the workspace (moved out of docs/ so each
    // collection carries its own curation log).
    final catalogFile = File('$rootDir/sources-catalog.md');
    final catalog = catalogFile.existsSync()
        ? parseCatalog(catalogFile.readAsStringSync())
        : const <String, CatalogInfo>{};

    // Active first, then prototyping/dormant: a curated (active) source that
    // was promoted out of the bulk pool (or graduated from a prototype)
    // still has stale traces elsewhere (a leftover generated-index.min.json
    // entry, or, in principle, an un-cleaned-up prototypes/ file), so skip
    // ids already shown as active rather than listing them twice.
    _loadActive(extDir, catalog);
    final promotedIds = {for (final r in rows) r.id};
    _loadPrototypes(Directory('$rootDir/prototypes'), catalog, promotedIds);
    _loadDormant(
      File('$rootDir/repo/generated-index.min.json'),
      catalog,
      promotedIds,
    );
    _loadCandidates(File('$rootDir/curation/candidates.json'));
    _loadArchived(File('$rootDir/curation/archived.json'));
    _loadPriority(File('$rootDir/curation/candidate_priority.json'));

    for (final row in rows) {
      row.archivedReason = archived[row.id];
      row.priority = priority[row.id];
      final kept = previous[row.key];
      if (kept != null) {
        row.probe = kept; // this session's live result wins
      } else {
        // No live result yet: show the last-known status from the store, so
        // the table remembers across restarts.
        final last = probeStore?.lastRun(row.id);
        if (last != null) row.probe = probeStateFromRun(last);
      }
    }
    notifyListeners();
  }

  void _loadArchived(File file) {
    archived = {};
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map;
      archived = json.map((k, v) => MapEntry(k as String, '$v'));
    } catch (e) {
      loadError = 'curation/archived.json failed to parse: $e';
    }
  }

  void _loadPriority(File file) {
    priority = {};
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map;
      priority = json.map(
        (k, v) => MapEntry(
          k as String,
          PriorityInfo.fromJson((v as Map).cast<String, dynamic>()),
        ),
      );
    } catch (e) {
      loadError = 'curation/candidate_priority.json failed to parse: $e';
    }
  }

  /// Marks a source id as archived with [reason], or un-archives it when
  /// [reason] is null. Re-reads curation/archived.json first so entries
  /// added outside this session (hand edits, another checkout) aren't
  /// clobbered, then persists it pretty-printed and sorted by id and
  /// updates the rows in place.
  void setArchived(String id, String? reason) {
    final rootDir = root;
    if (rootDir == null) return;
    final file = File('$rootDir/curation/archived.json');
    _loadArchived(file); // merge base: the file on disk, not this session's map
    if (reason == null) {
      archived.remove(id);
    } else {
      archived[id] = reason;
    }
    file.parent.createSync(recursive: true);
    final sorted = {
      for (final k in archived.keys.toList()..sort()) k: archived[k],
    };
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(sorted)}\n',
    );
    for (final row in rows) {
      row.archivedReason = archived[row.id];
    }
    notifyListeners();
  }

  void _loadActive(Directory extDir, Map<String, CatalogInfo> catalog) {
    final files =
        extDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final slug = file.uri.pathSegments.last.replaceAll('.json', '');
      final iconFile = File('${extDir.path}/icons/$slug.png');
      final icon = iconFile.existsSync() ? iconFile : null;
      try {
        final json = (jsonDecode(file.readAsStringSync()) as Map)
            .cast<String, dynamic>();
        _addEntryRows(
          json,
          tier: Tier.active,
          file: file,
          iconFile: icon,
          catalog: catalog,
          fallbackName: slug,
        );
      } catch (e) {
        rows.add(
          SourceRow(
            tier: Tier.active,
            file: file,
            extName: slug,
            pkg: '',
            version: '',
            nsfw: false,
            parseError: '$e',
            rawSource: const {},
            iconFile: icon,
          ),
        );
      }
    }
  }

  /// Loads `prototypes/*.json`: hand-authored sources being actively worked
  /// on (created via the playground's "New source from URL" + "Save as
  /// prototype", see detail_screen.dart), same file shape as `extensions/`
  /// (an extension entry with a `sources` list — `detail_screen.dart`'s
  /// `_asExtensionEntry` guarantees that shape at save time) so this reuses
  /// [_addEntryRows] exactly like [_loadActive] does. Deliberately a
  /// sibling directory to `extensions/`, not a status field within it: no
  /// build/publish/candidate tool globs anything but `extensions/*.json`,
  /// so a WIP source here can't accidentally reach a production build.
  void _loadPrototypes(
    Directory dir,
    Map<String, CatalogInfo> catalog,
    Set<String> skipIds,
  ) {
    if (!dir.existsSync()) return;
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final slug = file.uri.pathSegments.last.replaceAll('.json', '');
      try {
        final json = (jsonDecode(file.readAsStringSync()) as Map)
            .cast<String, dynamic>();
        _addEntryRows(
          json,
          tier: Tier.prototyping,
          file: file,
          catalog: catalog,
          fallbackName: slug,
          skipIds: skipIds,
        );
      } catch (e) {
        rows.add(
          SourceRow(
            tier: Tier.prototyping,
            file: file,
            extName: slug,
            pkg: '',
            version: '',
            nsfw: false,
            parseError: '$e',
            rawSource: const {},
          ),
        );
      }
    }
  }

  void _loadDormant(
    File index,
    Map<String, CatalogInfo> catalog,
    Set<String> skipIds,
  ) {
    if (!index.existsSync()) return;
    try {
      final entries = jsonDecode(index.readAsStringSync()) as List;
      for (final entry in entries) {
        _addEntryRows(
          (entry as Map).cast<String, dynamic>(),
          tier: Tier.dormant,
          catalog: catalog,
          fallbackName: '?',
          skipIds: skipIds,
        );
      }
    } catch (e) {
      loadError = 'repo/generated-index.min.json failed to parse: $e';
    }
  }

  /// Loads `curation/candidates.json` (see a workspace's own candidate lister):
  /// sources the collection knows exist but has never written a config for,
  /// probed, or archived. Each entry is a bare stub, not a real config, so
  /// these rows skip [AnySourceConfig.fromJson] entirely (it would just
  /// throw: nothing here has `popular`/`details`/`chapters`/`pages`) and
  /// carry a [SourceRow.parseError] instead, which doubles as what already
  /// excludes them from [probeAll]: there's nothing to probe.
  void _loadCandidates(File file) {
    if (!file.existsSync()) return;
    try {
      final entries = jsonDecode(file.readAsStringSync()) as List;
      for (final entry in entries) {
        final raw = (entry as Map).cast<String, dynamic>();
        rows.add(
          SourceRow(
            tier: Tier.candidate,
            extName: raw['name'] as String? ?? raw['id'] as String? ?? '?',
            pkg: raw['pkg'] as String? ?? '',
            version: '',
            nsfw: raw['nsfw'] == true,
            parseError:
                'No config written yet — a candidate, not a curated '
                'source (listed by the workspace\'s own tooling).',
            rawSource: raw,
          ),
        );
      }
    } catch (e) {
      loadError = 'curation/candidates.json failed to parse: $e';
    }
  }

  /// One row per source in an extension entry; a source that fails engine
  /// parsing gets an error row instead of disappearing.
  void _addEntryRows(
    Map<String, dynamic> entry, {
    required Tier tier,
    required Map<String, CatalogInfo> catalog,
    required String fallbackName,
    File? file,
    File? iconFile,
    Set<String> skipIds = const {},
  }) {
    final extName = entry['name'] as String? ?? fallbackName;
    final pkg = entry['pkg'] as String? ?? '';
    final version = entry['version'] as String? ?? '';
    final nsfw = entry['nsfw'] == 1 || entry['nsfw'] == true;
    final sources = entry['sources'] as List? ?? const [];
    for (final s in sources) {
      final raw = (s as Map).cast<String, dynamic>();
      // Already shown in a higher tier (a promoted source): don't duplicate.
      if (skipIds.contains(raw['id'])) continue;
      AnySourceConfig? config;
      String? parseError;
      try {
        config = AnySourceConfig.fromJson(raw);
      } catch (e) {
        parseError = '$e';
      }
      rows.add(
        SourceRow(
          tier: tier,
          file: file,
          entryJson: tier == Tier.dormant ? entry : null,
          extName: extName,
          pkg: pkg,
          version: version,
          nsfw: nsfw,
          config: config,
          parseError: parseError,
          rawSource: raw,
          iconFile: iconFile,
          catalog: catalog[raw['id']],
        ),
      );
    }
  }

  /// Probes [targets] with a small worker pool, updating each row's state as
  /// it goes, the "status manifest, but live" view.
  Future<void> probeAll(List<SourceRow> targets, {int concurrency = 4}) async {
    if (probing) return;
    probing = true;
    _cancelProbing = false;
    final queue = [
      for (final r in targets)
        if (r.parseError == null) r,
    ];
    notifyListeners();
    await Future.wait([
      for (var i = 0; i < concurrency; i++)
        () async {
          while (queue.isNotEmpty && !_cancelProbing) {
            final row = queue.removeAt(0);
            await runProbe(
              row.probe,
              jsonEncode(row.rawSource),
              onUpdate: notifyListeners,
              // Headless-only during bulk probes (no dialog storm); solves
              // are serialized inside solveCloudflare. Rows the headless pass
              // can't clear fail with a pointer to the row detail's
              // interactive solver.
              onChallenge: (url) => solveCloudflare(url),
              onDone: (state) => probeStore?.record(state, tier: row.tier.name),
            );
          }
        }(),
    ]);
    probing = false;
    notifyListeners();
  }

  /// Stops scheduling new probes; in-flight ones finish.
  void cancelProbing() => _cancelProbing = true;

  /// Lets detail screens push probe updates into the table.
  void ping() => notifyListeners();
}

// ── Workspace registry persistence ─────────────────────────────────────────
// A dev tool, not an App Store app: the sandbox is disabled (see
// macos/Runner/*.entitlements), so a plain dotfile in $HOME works and the
// registered workspaces stay readable across launches. State shape:
//   { "current": "<path>", "workspaces": ["<path>", ...] }
// (the legacy `lastWorkspace` key is still read as a fallback.)

/// Overrides the state file location (tests set this to a temp path so they
/// don't touch the developer's real registry). Null = the $HOME dotfile.
String? debugStatePathOverride;

String get _statePath {
  if (debugStatePathOverride != null) return debugStatePathOverride!;
  final home = Platform.environment['HOME'] ?? '.';
  return '$home/.konimanga_playground.json';
}

Map<String, dynamic> _loadState() {
  try {
    return (jsonDecode(File(_statePath).readAsStringSync()) as Map)
        .cast<String, dynamic>();
  } catch (_) {
    return {};
  }
}

void _saveState(Map<String, dynamic> state) {
  try {
    File(_statePath).writeAsStringSync(jsonEncode(state));
  } catch (_) {
    // Non-fatal: state just won't persist.
  }
}

/// The registered workspace dirs that still exist on disk, most-recent first.
List<String> loadRegisteredWorkspaces() {
  final state = _loadState();
  final list =
      (state['workspaces'] as List?)?.cast<String>() ??
      // Legacy single-workspace state.
      [if (state['lastWorkspace'] is String) state['lastWorkspace'] as String];
  return list.where((p) => Workspace.isWorkspace(p)).toList();
}

/// The workspace to open on launch (last current, if still valid).
String? loadCurrentWorkspace() {
  final state = _loadState();
  final path = state['current'] as String? ?? state['lastWorkspace'] as String?;
  return (path != null && Workspace.isWorkspace(path)) ? path : null;
}

/// Adds [path] to the registry (most-recent first, deduped) and returns it.
/// Merges into the full persisted state rather than replacing it, so other
/// keys (e.g. [blurNsfw]'s) survive.
List<String> registerWorkspace(String path) {
  final list = loadRegisteredWorkspaces()..remove(path);
  list.insert(0, path);
  final state = _loadState();
  state['current'] = path;
  state['workspaces'] = list;
  _saveState(state);
  return list;
}

/// Removes [path] from the registry and returns the remainder.
List<String> unregisterWorkspace(String path) {
  final list = loadRegisteredWorkspaces()..remove(path);
  final state = _loadState();
  if (state['current'] == path) state.remove('current');
  state['workspaces'] = list;
  _saveState(state);
  return list;
}

void saveCurrentWorkspace(String path) {
  final state = _loadState();
  state['current'] = path;
  _saveState(state);
}

/// The persisted "blur NSFW-risk images" toggle: a screen-safety setting,
/// global across all workspaces (not scoped to any one project).
bool loadBlurNsfw() => _loadState()['blurNsfw'] == true;

void saveBlurNsfw(bool value) {
  final state = _loadState();
  state['blurNsfw'] = value;
  _saveState(state);
}
