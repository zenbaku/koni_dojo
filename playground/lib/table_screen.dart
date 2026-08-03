// The workspace's master view: every source across the three tiers in one
// sortable, filterable table: characteristics from the configs, status and
// notes from the catalog, and a live probe-status column that "Probe all"
// fills in. The status manifest, but interactive.
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import 'blur_toggle.dart';
import 'cloudflare.dart';
import 'detail_screen.dart';
import 'probe.dart';
import 'sample_config.dart';
import 'workspace.dart';

class TableScreen extends StatefulWidget {
  const TableScreen({super.key, required this.workspace});

  final Workspace workspace;

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _Column {
  const _Column(this.label, this.width, {this.compare});

  final String label;
  final double width;
  final Comparator<SourceRow>? compare;
}

final _columns = <_Column>[
  const _Column('', 40), // icon
  _Column(
    'Name',
    190,
    compare: (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  ),
  _Column('id', 150, compare: (a, b) => a.id.compareTo(b.id)),
  _Column('Tier', 80, compare: (a, b) => a.tier.index.compareTo(b.tier.index)),
  _Column(
    'Priority',
    76,
    compare: (a, b) {
      final ta = (a.priority?.tier ?? PriorityTier.unranked).index;
      final tb = (b.priority?.tier ?? PriorityTier.unranked).index;
      if (ta != tb) return ta.compareTo(tb);
      return (b.priority?.score ?? 0).compareTo(a.priority?.score ?? 0);
    },
  ),
  _Column('Engine', 64, compare: (a, b) => a.engine.compareTo(b.engine)),
  _Column('Lang', 56, compare: (a, b) => a.lang.compareTo(b.lang)),
  _Column(
    '18+',
    44,
    compare: (a, b) => (a.nsfw ? 1 : 0).compareTo(b.nsfw ? 1 : 0),
  ),
  const _Column('WV', 40),
  const _Column('Rate', 56),
  _Column(
    'Probe',
    130,
    compare: (a, b) => a.probe.label.compareTo(b.probe.label),
  ),
  _Column(
    'Catalog status',
    200,
    compare: (a, b) =>
        (a.catalog?.status ?? '').compareTo(b.catalog?.status ?? ''),
  ),
  const _Column('Base URL', 220),
  const _Column('Notes', 320),
];

double get _tableWidth =>
    _columns.fold(0.0, (w, c) => w + c.width) + 24; // + row padding

/// Probe-status filter: everything, passing, failing, or not yet probed.
enum _ProbeFilter { any, pass, fail, unprobed }

/// 18+ filter: everything, only 18+, or hide 18+.
enum _NsfwFilter { any, only, hide }

class _TableScreenState extends State<TableScreen> {
  String _query = '';
  final Set<Tier> _tiers = {Tier.active, Tier.prototyping};
  final Set<String> _engines = {'html', 'api'};
  String? _lang; // null = any
  _ProbeFilter _probeFilter = _ProbeFilter.any;
  _NsfwFilter _nsfwFilter = _NsfwFilter.any;
  PriorityTier? _priorityFilter; // null = any
  bool _includeArchived = false;
  int _sortColumn = 1; // Name
  bool _ascending = true;

  // Without this, the explicit Scrollbar around the table falls back to
  // PrimaryScrollController for both itself and the SingleChildScrollView
  // it wraps, not reliably attached, throwing "no ScrollPosition attached"
  // on the very first warm-up frame (this table is often the first thing
  // rendered, since a workspace reopens automatically on launch).
  final _tableScrollController = ScrollController();

  @override
  void dispose() {
    _tableScrollController.dispose();
    super.dispose();
  }

  Workspace get ws => widget.workspace;

  bool _matchesProbe(SourceRow r) => switch (_probeFilter) {
    _ProbeFilter.any => true,
    _ProbeFilter.pass => r.probe.phase == ProbePhase.done && r.probe.passed,
    _ProbeFilter.fail => r.probe.phase == ProbePhase.done && r.probe.failed,
    _ProbeFilter.unprobed => r.probe.phase == ProbePhase.idle,
  };

  bool _matchesNsfw(SourceRow r) => switch (_nsfwFilter) {
    _NsfwFilter.any => true,
    _NsfwFilter.only => r.nsfw,
    _NsfwFilter.hide => !r.nsfw,
  };

  // `unranked` means "no ranking run has covered this id at all" (r.priority
  // itself is null): tool/rank_candidates.dart never writes that tier as a
  // value, it's only ever the field's own default.
  bool _matchesPriority(SourceRow r) {
    final f = _priorityFilter;
    if (f == null) return true;
    if (f == PriorityTier.unranked) return r.priority == null;
    return r.priority?.tier == f;
  }

  List<SourceRow> get _filtered {
    final q = _query.toLowerCase();
    final rows = [
      for (final r in ws.rows)
        // An archived row keeps whatever tier it had before archiving, so
        // toggling the tier chips off to isolate "just archived" would
        // otherwise leave no tier selected for it to match: the archived
        // toggle needs to bypass the tier gate, not just the archived
        // exclusion below.
        if ((_tiers.contains(r.tier) || (_includeArchived && r.archived)) &&
            _engines.contains(r.engine) &&
            (_lang == null || r.lang == _lang) &&
            _matchesProbe(r) &&
            _matchesNsfw(r) &&
            _matchesPriority(r) &&
            (_includeArchived || !r.archived) &&
            (q.isEmpty ||
                r.name.toLowerCase().contains(q) ||
                r.id.contains(q) ||
                r.pkg.contains(q) ||
                r.baseUrl.contains(q)))
          r,
    ];
    final cmp = _columns[_sortColumn].compare;
    if (cmp != null) {
      rows.sort((a, b) => _ascending ? cmp(a, b) : cmp(b, a));
    }
    return rows;
  }

  /// Distinct languages across the workspace, most frequent first, for the
  /// language dropdown.
  List<String> get _langs {
    final counts = <String, int>{};
    for (final r in ws.rows) {
      if (r.lang.isNotEmpty) counts[r.lang] = (counts[r.lang] ?? 0) + 1;
    }
    final langs = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return langs;
  }

  Future<void> _openWorkspace() async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    ws.open(dir);
  }

  void _openScratch() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          workspace: ws,
          title: 'Scratch config',
          initialText: sampleConfig,
        ),
      ),
    );
  }

  /// Derives a starter `id`/`name` from a host: strips `www.` and the TLD,
  /// squashes the rest together (`www.manhuaus.com` → `manhuaus`) — a rough
  /// guess the user is expected to rename, not a real slugify. Empty only if
  /// the host itself is somehow empty (guarded against by the caller before
  /// this is reached).
  String _slugFromHost(String host) {
    var h = host.toLowerCase();
    if (h.startsWith('www.')) h = h.substring(4);
    final parts = h.split('.');
    final withoutTld = parts.length > 1
        ? parts.sublist(0, parts.length - 1).join()
        : h;
    final slug = withoutTld.replaceAll(RegExp('[^a-z0-9]'), '');
    return slug.isEmpty ? 'newsource' : slug;
  }

  /// A minimal-but-valid `SourceConfig` JSON for [url]'s origin: just enough
  /// (`id`/`name`/`baseUrl` plus empty `popular`/`chapters`/`pages` blocks —
  /// every field within those has its own default, `ListingConfig.fromJson`
  /// etc. all tolerate `{}`) for `parseConfig` to succeed immediately, which
  /// is what unlocks detail_screen's "Pick from page" picker. Without this,
  /// starting from a bare URL meant hand-typing that skeleton first — the
  /// exact friction this entry point exists to remove.
  String _scaffoldConfigFromUrl(Uri url) {
    final id = _slugFromHost(url.host);
    final json = {
      'id': id,
      'name': id[0].toUpperCase() + id.substring(1),
      'lang': 'en',
      'baseUrl': '${url.scheme}://${url.host}',
      'popular': <String, dynamic>{},
      'chapters': <String, dynamic>{},
      'pages': <String, dynamic>{},
    };
    return '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  }

  /// "New source" entry point: prompts for just a URL, scaffolds a minimal
  /// valid config from its origin (see [_scaffoldConfigFromUrl]), and opens
  /// it — landing straight on a config the "Pick from page" picker can work
  /// with right away, instead of an empty or fixed-demo editor. Still a
  /// scratch config (no workspace row): same edit-and-probe-only status quo
  /// as [_openScratch] until it's saved by hand into `extensions/<id>.json`.
  Future<void> _openNewFromUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<Uri>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New source from URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Site URL',
            hintText: 'https://example.com',
          ),
          onSubmitted: (v) => Navigator.pop(context, Uri.tryParse(v.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, Uri.tryParse(controller.text.trim())),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (url == null || url.host.isEmpty || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          workspace: ws,
          title: 'New source · ${url.host}',
          initialText: _scaffoldConfigFromUrl(url),
        ),
      ),
    );
  }

  void _openRow(SourceRow row) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          row: row,
          workspace: ws,
          title: '${row.name} · ${row.id}',
          initialText: row.editorText(),
        ),
      ),
    );
  }

  /// A dropdown of registered workspaces (label = manifest name / dir stem),
  /// plus "Open another workspace…". Switching re-opens the chosen dir.
  Widget _workspaceSwitcher() {
    String label(String path) {
      final stem = path.split('/').where((s) => s.isNotEmpty).last;
      return path == ws.root ? ws.name : stem;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: PopupMenuButton<String>(
        tooltip: 'Switch workspace',
        onSelected: (v) =>
            v == _openSentinel ? _openWorkspace() : ws.switchTo(v),
        itemBuilder: (context) => [
          for (final path in ws.registered)
            CheckedPopupMenuItem(
              value: path,
              checked: path == ws.root,
              child: Text(label(path), overflow: TextOverflow.ellipsis),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _openSentinel,
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 18),
                SizedBox(width: 8),
                Text('Open another workspace…'),
              ],
            ),
          ),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.workspaces_outline, size: 18),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(ws.name, overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  static const _openSentinel = ' open';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ws,
      builder: (context, _) {
        final rows = _filtered;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Konimanga Source Playground'),
            centerTitle: false,
            actions: [
              _workspaceSwitcher(),
              IconButton(
                tooltip:
                    'New source from URL — scaffolds a minimal config '
                    'so "Pick from page" works right away',
                onPressed: _openNewFromUrl,
                icon: const Icon(Icons.add_link),
              ),
              IconButton(
                tooltip: 'Scratch config',
                onPressed: _openScratch,
                icon: const Icon(Icons.note_add_outlined),
              ),
              IconButton(
                tooltip: 'Reload workspace from disk',
                onPressed: ws.refresh,
                icon: const Icon(Icons.refresh),
              ),
              BlurToggleAction(workspace: ws),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(rows),
              _filterBar(),
              if (ws.loadError != null)
                MaterialBanner(
                  content: Text(ws.loadError!),
                  actions: const [SizedBox.shrink()],
                ),
              const Divider(height: 1),
              Expanded(child: _table(rows)),
            ],
          ),
        );
      },
    );
  }

  Widget _toolbar(List<SourceRow> rows) {
    final theme = Theme.of(context);
    final done = rows.where((r) => r.probe.phase == ProbePhase.done);
    final passed = done.where((r) => r.probe.passed).length;
    final failed = done.where((r) => r.probe.failed).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search name, id, pkg, url…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const Spacer(),
          ValueListenableBuilder<int>(
            valueListenable: warmedClearanceCookies,
            builder: (context, n, _) => n == 0
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Tooltip(
                      message:
                          'Cloudflare clearances from a previous session '
                          'were re-seeded into the WebView, so those hosts skip '
                          'the challenge (until the token expires).',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            size: 14,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$n clearance${n == 1 ? '' : 's'} reused',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          if (passed + failed > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '$passed pass · $failed fail',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Text('${rows.length} shown', style: theme.textTheme.bodySmall),
          const SizedBox(width: 12),
          if (ws.probing)
            OutlinedButton.icon(
              onPressed: ws.cancelProbing,
              icon: const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              label: const Text('Cancel'),
            )
          else
            FilledButton.icon(
              onPressed: rows.isEmpty ? null : () => ws.probeAll(rows),
              icon: const Icon(Icons.play_arrow),
              label: Text('Probe all ${rows.length}'),
            ),
        ],
      ),
    );
  }

  /// Whether any filter deviates from its default (used for the Reset button).
  bool get _hasActiveFilters =>
      !setEquals(_tiers, {Tier.active, Tier.prototyping}) ||
      !setEquals(_engines, {'html', 'api'}) ||
      _lang != null ||
      _probeFilter != _ProbeFilter.any ||
      _nsfwFilter != _NsfwFilter.any ||
      _priorityFilter != null ||
      _includeArchived;

  void _resetFilters() => setState(() {
    _tiers
      ..clear()
      ..addAll({Tier.active, Tier.prototyping});
    _engines
      ..clear()
      ..addAll(['html', 'api']);
    _lang = null;
    _probeFilter = _ProbeFilter.any;
    _nsfwFilter = _NsfwFilter.any;
    _priorityFilter = null;
    _includeArchived = false;
  });

  /// The second toolbar row: everything that narrows the table (tier,
  /// engine, language, probe status, 18+, and archived) as one visual
  /// system: chip-height controls, grouped by thin dividers, filled when
  /// they deviate from the default.
  Widget _filterBar() {
    final theme = Theme.of(context);
    final archivedCount = ws.rows.where((r) => r.archived).length;

    Widget divider() => Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: theme.colorScheme.outlineVariant,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final tier in Tier.values)
            _filterChip(
              label:
                  '${tier.name} ${ws.rows.where((r) => r.tier == tier).length}',
              selected: _tiers.contains(tier),
              onSelected: (on) =>
                  setState(() => on ? _tiers.add(tier) : _tiers.remove(tier)),
            ),
          divider(),
          for (final engine in const ['html', 'api'])
            _filterChip(
              label: engine,
              selected: _engines.contains(engine),
              onSelected: (on) => setState(
                () => on ? _engines.add(engine) : _engines.remove(engine),
              ),
            ),
          divider(),
          _FilterDropdown<String?>(
            label: 'Lang',
            value: _lang,
            isDefault: _lang == null,
            items: [null, ..._langs],
            labelOf: (v) => v ?? 'any',
            onChanged: (v) => setState(() => _lang = v),
          ),
          _FilterDropdown<_ProbeFilter>(
            label: 'Probe',
            value: _probeFilter,
            isDefault: _probeFilter == _ProbeFilter.any,
            items: _ProbeFilter.values,
            labelOf: (v) => v.name,
            onChanged: (v) => setState(() => _probeFilter = v),
          ),
          _FilterDropdown<_NsfwFilter>(
            label: '18+',
            value: _nsfwFilter,
            isDefault: _nsfwFilter == _NsfwFilter.any,
            items: _NsfwFilter.values,
            labelOf: (v) => v.name,
            onChanged: (v) => setState(() => _nsfwFilter = v),
          ),
          _FilterDropdown<PriorityTier?>(
            label: 'Priority',
            value: _priorityFilter,
            isDefault: _priorityFilter == null,
            items: [null, ...PriorityTier.values],
            labelOf: (v) => v?.name ?? 'any',
            onChanged: (v) => setState(() => _priorityFilter = v),
          ),
          divider(),
          _filterChip(
            label: 'archived $archivedCount',
            selected: _includeArchived,
            onSelected: (on) => setState(() => _includeArchived = on),
            tooltip:
                'Include sources marked as not pursued '
                '(curation/archived.json)',
          ),
          if (_hasActiveFilters) ...[
            divider(),
            SizedBox(
              height: 30,
              child: TextButton.icon(
                onPressed: _resetFilters,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 15),
                label: const Text('Reset'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Uniform compact chip: same 30px height and corner radius as the
  /// dropdowns so the whole bar reads as one row of controls.
  Widget _filterChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
    String? tooltip,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 30,
      child: FilterChip(
        label: Text(label),
        labelStyle: theme.textTheme.bodySmall!.copyWith(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
        selected: selected,
        onSelected: onSelected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected
                ? Colors.transparent
                : theme.colorScheme.outlineVariant,
          ),
        ),
        tooltip: tooltip,
      ),
    );
  }

  Widget _table(List<SourceRow> rows) {
    return Scrollbar(
      thumbVisibility: true,
      controller: _tableScrollController,
      child: SingleChildScrollView(
        controller: _tableScrollController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _tableWidth,
          child: Column(
            children: [
              _headerRow(),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemExtent: 40,
                  itemBuilder: (context, i) => _Row(
                    row: rows[i],
                    even: i.isEven,
                    onTap: () => _openRow(rows[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerRow() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final (i, col) in _columns.indexed)
            SizedBox(
              width: col.width,
              child: col.compare == null
                  ? Text(col.label, style: theme.textTheme.labelMedium)
                  : InkWell(
                      onTap: () => setState(() {
                        if (_sortColumn == i) {
                          _ascending = !_ascending;
                        } else {
                          _sortColumn = i;
                          _ascending = true;
                        }
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                col.label,
                                style: theme.textTheme.labelMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_sortColumn == i)
                              Icon(
                                _ascending
                                    ? Icons.arrow_drop_up
                                    : Icons.arrow_drop_down,
                                size: 16,
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

/// Non-null carrier so `PopupMenuButton<_Choice<T>>` can select a genuinely
/// null [T] (this file's "any" convention, e.g. `_lang`/`_priorityFilter`).
/// `PopupMenuButton` resolves its selection through `showMenu<T>`, which
/// returns null both when an item whose value is null was tapped *and* when
/// the menu was dismissed without a selection: indistinguishable without
/// this wrapper, so a bare `PopupMenuItem<T>(value: null)` can never actually
/// fire `onSelected` once tapped (confirmed live: selecting "highest" in the
/// Priority filter left no way back to "any").
class _Choice<T> {
  const _Choice(this.value);
  final T value;

  // Value equality, not identity: a fresh _Choice is built every frame
  // (itemBuilder/initialValue both wrap `value` anew), so PopupMenuButton's
  // own initial-highlight matching needs this to recognize "the same choice"
  // across rebuilds.
  @override
  bool operator ==(Object other) => other is _Choice<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A dropdown filter styled to sit beside [FilterChip]s: a chip-height pill
/// showing "Label value ▾", outlined when at its default and filled (like a
/// selected chip) when the filter is narrowing the table.
class _FilterDropdown<T> extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.isDefault,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final T value;
  final bool isDefault;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = !isDefault;
    final fg = active
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurface;
    return PopupMenuButton<_Choice<T>>(
      tooltip: 'Filter by ${label.toLowerCase()}',
      initialValue: _Choice(value),
      onSelected: (choice) => onChanged(choice.value),
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem(
            value: _Choice(item),
            height: 34,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: item == value
                      ? const Icon(Icons.check, size: 15)
                      : null,
                ),
                Text(labelOf(item), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: active ? theme.colorScheme.secondaryContainer : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? Colors.transparent
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall!.copyWith(
                color: active
                    ? theme.colorScheme.onSecondaryContainer.withValues(
                        alpha: 0.7,
                      )
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              labelOf(value),
              style: theme.textTheme.bodySmall!.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: fg),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.even, required this.onTap});

  final SourceRow row;
  final bool even;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final body = theme.textTheme.bodySmall!;

    Widget cell(int i, Widget child) =>
        SizedBox(width: _columns[i].width, child: child);
    Widget textCell(int i, String text, {TextStyle? style, String? tooltip}) {
      final t = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style ?? body,
      );
      return cell(
        i,
        tooltip == null || tooltip.isEmpty
            ? t
            : Tooltip(message: tooltip, child: t),
      );
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: even
            ? Colors.transparent
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: Row(
          children: [
            cell(0, _icon(theme)),
            cell(
              1,
              Row(
                children: [
                  if (row.archived)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Tooltip(
                        message: 'Archived: ${row.archivedReason}',
                        child: Icon(
                          Icons.archive,
                          size: 13,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  Flexible(
                    child: Text(
                      row.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: row.archived
                          ? body.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.outline,
                            )
                          : body.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            textCell(2, row.id, style: dim),
            textCell(3, row.tier.name, style: dim),
            cell(4, _priorityCell(theme)),
            textCell(5, row.engine, style: dim),
            textCell(6, row.lang, style: dim),
            textCell(7, row.nsfw ? '18+' : '', style: dim),
            textCell(8, row.webview ? 'WV' : '', style: dim),
            textCell(9, row.rateLimitLabel, style: dim),
            cell(10, _probeCell(theme)),
            textCell(
              11,
              row.catalog?.status ?? '',
              style: dim,
              tooltip: row.catalog?.status,
            ),
            textCell(12, row.baseUrl, style: dim, tooltip: row.baseUrl),
            textCell(
              13,
              row.catalog?.notes ?? '',
              style: dim,
              tooltip: row.catalog?.notes,
            ),
          ],
        ),
      ),
    );
  }

  /// Colored tier label; hover for the score + the additive reasons
  /// tool/rank_candidates.dart logged for it: the ranking is meant to be
  /// inspectable, not just trusted.
  Widget _priorityCell(ThemeData theme) {
    final p = row.priority;
    if (p == null) {
      return Text(
        '—',
        style: theme.textTheme.bodySmall!.copyWith(
          color: theme.colorScheme.outlineVariant,
        ),
      );
    }
    final color = switch (p.tier) {
      PriorityTier.highest => Colors.amber.shade800,
      PriorityTier.high => theme.colorScheme.primary,
      PriorityTier.medium => theme.colorScheme.onSurfaceVariant,
      PriorityTier.low => theme.colorScheme.outlineVariant,
      PriorityTier.unranked => theme.colorScheme.outlineVariant,
    };
    return Tooltip(
      message: 'score ${p.score}\n${p.reasons.join('\n')}',
      child: Text(
        p.tier.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall!.copyWith(
          color: color,
          fontWeight: p.tier == PriorityTier.highest
              ? FontWeight.w700
              : FontWeight.w400,
        ),
      ),
    );
  }

  Widget _icon(ThemeData theme) {
    Widget? img;
    final dataUri = row.iconDataUri;
    if (row.iconFile != null) {
      img = Image.file(row.iconFile!, width: 22, height: 22);
    } else if (dataUri != null) {
      img = Image.memory(
        base64Decode(dataUri.substring(dataUri.indexOf(',') + 1)),
        width: 22,
        height: 22,
      );
    }
    return img == null
        ? Icon(
            Icons.extension_outlined,
            size: 18,
            color: theme.colorScheme.outlineVariant,
          )
        : ClipRRect(borderRadius: BorderRadius.circular(4), child: img);
  }

  Widget _probeCell(ThemeData theme) {
    if (row.parseError != null) {
      return Tooltip(
        message: row.parseError!,
        child: Text(
          'config error',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    final probe = row.probe;
    switch (probe.phase) {
      case ProbePhase.idle:
        return Text(
          '—',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.outlineVariant,
          ),
        );
      case ProbePhase.running:
        return const Align(
          alignment: Alignment.centerLeft,
          child: SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case ProbePhase.done:
        final color = probe.passed ? Colors.green : theme.colorScheme.error;
        final detail =
            probe.runError ?? (probe.passed ? '' : '${probe.stageError ?? ''}');
        final ms = probe.elapsed?.inMilliseconds;
        // A result seeded from the store (a previous session) is shown a touch
        // dimmer and marked in the tooltip; a live probe this session is solid.
        final fromHistory = probe.recordedAt != null;
        final tip = [
          if (detail.isNotEmpty) detail,
          if (fromHistory) 'last probed ${probe.recordedAt}',
        ].join('\n');
        return Tooltip(
          message: tip.isEmpty ? probe.label : tip,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (fromHistory)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.history,
                    size: 11,
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
              Flexible(
                child: Text(
                  '${probe.label}${ms == null ? '' : ' · ${ms}ms'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: fromHistory ? color.withValues(alpha: 0.7) : color,
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }
}
