// Per-source workbench: the config JSON (syntax-highlighted, editable) on
// the left, probe results on the right. Workspace-file-backed (active) rows
// save back to disk in place; a dormant row has no file yet, so its action
// is "Promote" instead: writes the (possibly edited) config to
// extensions/<id>.json, the same convention a workspace's own promote step
// follows, just with whatever fix was made in the editor already applied. A scratch config (no row at all) is edit-and-probe only: there's
// no id/workspace target to promote it into.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:koni_dojo/koni_dojo.dart';

import 'blur_toggle.dart';
import 'cloudflare.dart';
import 'config_form.dart';
import 'consent.dart';
import 'inline_markdown.dart';
import 'json_editor.dart';
import 'json_view.dart';
import 'login.dart';
import 'probe.dart';
import 'probe_store.dart';
import 'results_pane.dart';
import 'workspace.dart';

/// What to do with a just-finished picker session — see
/// `_DetailScreenState._confirmApplyPicked`. [back] reopens the same picker
/// seeded with the in-progress fields instead of discarding them outright,
/// so a mistake in one field doesn't force redoing every other field too.
enum ApplyPickedDecision { discard, back, apply }

/// One row of the "Apply picked selectors?" confirm dialog — see
/// [groupPickedFields].
typedef PickedFieldGroup = ({
  String label,
  String value,
  String? attr,
  String? preview,
});

/// Human label for a picked field's key, preferring the wizard's own
/// [FieldStep.fieldLabel] (already human-written, just inconsistently cased
/// between the linear wizard's lowercase and the details palette's
/// capitalized labels — normalized here). `path` — the listing-URL field
/// `DetailScreen._pickFromPage` injects for `popular` — and anything else
/// unrecognized falls back to a label derived from the key, so the confirm
/// dialog never shows a bare, hard-to-scan JSON key like `titleSelector`.
/// A top-level function (not a `_DetailScreenState` method) purely so it's
/// unit-testable without a live picker session — same convention as
/// `probe.dart`'s `compareRenderedElementCounts`.
String pickedFieldLabel(String key, List<FieldStep> steps) {
  if (key == 'path') return 'Listing URL';
  for (final step in steps) {
    if (step.key != key) continue;
    final label = step.fieldLabel;
    return label.isEmpty
        ? key
        : '${label[0].toUpperCase()}${label.substring(1)}';
  }
  final base = key.endsWith('Selector')
      ? key.substring(0, key.length - 'Selector'.length)
      : key;
  return base.isEmpty ? key : '${base[0].toUpperCase()}${base.substring(1)}';
}

/// Groups a wizard's flat [PickedFields] (`{itemSelector: ..., coverSelector:
/// ..., coverAttr: ...}`) into one row per selector, folding its `*Attr`
/// companion (see `FieldStep.attrKey`) into the same row instead of showing
/// it as an unrelated line — the flat key-per-line layout this replaces gave
/// every key equal visual weight, so a 6-field pick read as a wall of
/// undifferentiated text. `path`, when present, always sorts first — it's
/// the page the rest of the pick was made against, so it reads as context
/// for what follows rather than one field among six. [previews] — the
/// picker's own [PickResult.previews], keyed the same as [fields] — supplies
/// what each selector actually captured (matched-item count, or the
/// extracted text/attr value); `path` never has one, it's already the raw
/// value being shown.
List<PickedFieldGroup> groupPickedFields(
  PickedFields fields,
  List<FieldStep> steps, [
  Map<String, String> previews = const {},
]) {
  final attrKeys = {
    for (final key in fields.keys)
      if (key.endsWith('Selector')) key.replaceAll('Selector', 'Attr'),
  };
  final groups = <PickedFieldGroup>[];
  final path = fields['path'];
  if (path != null) {
    groups.add((label: 'Listing URL', value: path, attr: null, preview: null));
  }
  for (final entry in fields.entries) {
    if (entry.key == 'path' || attrKeys.contains(entry.key)) continue;
    final attrKey = entry.key.endsWith('Selector')
        ? entry.key.replaceAll('Selector', 'Attr')
        : null;
    groups.add((
      label: pickedFieldLabel(entry.key, steps),
      value: entry.value,
      attr: attrKey == null ? null : fields[attrKey],
      preview: previews[entry.key],
    ));
  }
  return groups;
}

final _zeroWidthSpace = String.fromCharCode(0x200b);

/// Inserts a zero-width space after every CSS selector delimiter so a long
/// class-chain selector (routine on Tailwind-styled sites) *prefers* to
/// wrap between tokens instead of mid-word. Doesn't fully guarantee it —
/// Flutter's default line breaker still treats a hyphen inside a class name
/// (e.g. `text-lg`) as its own break opportunity, so a single very long
/// token can still split there under a narrow enough width. Deliberately
/// left alone rather than "fixed" by substituting a non-breaking hyphen:
/// the confirm dialog's selector text is [SelectableText] specifically so
/// it can be copied out for inspection, and a substituted character that
/// merely *looks* like `-` would silently break a selector pasted back into
/// raw JSON. The wider dialog (see `_confirmApplyPicked`) is what actually
/// keeps this rare in practice.
String breakableSelector(String selector) => selector.replaceAllMapped(
  RegExp(r'([.#>~+,])'),
  (m) => '${m[1]}$_zeroWidthSpace',
);

/// Inverse of `DetailScreen._pickerDefaultUrl`'s `'$baseUrl$path'`
/// reconstruction — strips [baseUrl] off [url] to recover a relative
/// `path`. Used so applying a `popular` pick also persists *where* it was
/// picked from: before this, `_applyPickedFields` only ever wrote the
/// selector/attr fields, never `popular.path`, so picking against a URL
/// other than a blank `path`'s implicit `baseUrl` (e.g. a
/// `/search?sort=Popularity&...` listing, common on sites with no dedicated
/// "popular" page) silently kept fetching the wrong page in production —
/// confirmed by reading `_fetchListing`'s `path.isEmpty ? baseUrl :
/// absoluteUrl(path)` resolution in `config_source.dart`. Falls back to the
/// full URL when it doesn't share [baseUrl]'s prefix (cross-origin listing,
/// or `baseUrl` changed since) — still correct, `absoluteUrl` resolves an
/// already-absolute `path` to itself.
String pathFromPickedUrl(Uri url, String baseUrl) {
  final full = url.toString();
  return baseUrl.isNotEmpty && full.startsWith(baseUrl)
      ? full.substring(baseUrl.length)
      : full;
}

/// True when [parsed] has no `popular.path` set yet — the only case
/// [pathFromPickedUrl]'s write should fire for. Originally this only
/// guarded against clobbering a `{page}`/`{offset}` pagination template on
/// a re-pick, but that was too narrow: a source can just as easily have a
/// deliberately *different* URL there than whatever page the picker was
/// last pointed at — e.g. one live source's `popular.path` is `/search/data`,
/// the real (directly fetchable, no JS needed) listing endpoint, while the
/// page a human can actually click through and pick selectors against is
/// `/search`, an interactive form shell that only loads results via a
/// client-side request. Re-picking against `/search` must never silently
/// overwrite the working `/search/data` path. The general rule — never
/// touch an already-set path, whatever shape it has — covers the template
/// case as a special case, so a separate templated-path check is no longer
/// needed. API-dialect sources have no `popular.path` at all (never `null`
/// for them here — `parsed is! SourceConfig` alone already reads as unset).
bool popularPathIsUnset(AnySourceConfig? parsed) =>
    parsed is! SourceConfig || parsed.popular.path.isEmpty;

/// The inverse of `_DetailScreenState._applyPickedFields`: reads [opKey]'s
/// already-configured selectors back out of [parsed] into the same
/// [PickedFields] shape a picker session produces, so a picker can be
/// re-opened pre-seeded instead of starting blank every time. Empty when
/// nothing's configured yet, or [parsed] isn't HTML-dialect.
///
/// `popular`/`chapters`/`pages` are gated on the whole block's own
/// `itemSelector` (`pages`: `imageSelector`) being non-empty before
/// returning anything: `titleSelector`/`urlSelector` default to `'a'` and
/// `coverSelector` to `'img'` (see `ListingConfig`), so per-field emptiness
/// can't tell "picked" from "still the schema default" for those — only
/// the block-level selector is unambiguous. Same signal `probe.dart`'s
/// `popularConfigured`/`chaptersConfigured`/`pagesConfigured` already use.
///
/// `details` has no such ambiguity — every relevant `DetailsConfig` field
/// defaults to `''` — so it's gated per field, giving the palette's
/// individual "this chip is already picked" granularity.
///
/// `path` is deliberately excluded: it's not a [FieldStep] key, and is
/// synthesized separately at apply-time (see [pathFromPickedUrl]).
PickedFields existingPickedFields(String opKey, AnySourceConfig? parsed) {
  if (parsed is! SourceConfig) return const {};
  switch (opKey) {
    case 'popular':
      final p = parsed.popular;
      if (p.itemSelector.isEmpty) return const {};
      return {
        'itemSelector': p.itemSelector,
        'titleSelector': p.titleSelector,
        if (p.titleAttr.isNotEmpty) 'titleAttr': p.titleAttr,
        'urlSelector': p.urlSelector,
        'urlAttr': p.urlAttr,
        'coverSelector': p.coverSelector,
        'coverAttr': p.coverAttr,
      };
    case 'chapters':
      final c = parsed.chapters;
      if (c.itemSelector.isEmpty) return const {};
      return {
        'itemSelector': c.itemSelector,
        'nameSelector': c.nameSelector,
        'urlSelector': c.urlSelector,
        'urlAttr': c.urlAttr,
        if (c.dateSelector.isNotEmpty) 'dateSelector': c.dateSelector,
      };
    case 'pages':
      final pg = parsed.pages;
      if (pg.imageSelector.isEmpty) return const {};
      return {'imageSelector': pg.imageSelector, 'imageAttr': pg.imageAttr};
    case 'details':
      final d = parsed.details;
      return {
        if (d.titleSelector.isNotEmpty) 'titleSelector': d.titleSelector,
        if (d.authorSelector.isNotEmpty) 'authorSelector': d.authorSelector,
        if (d.descriptionSelector.isNotEmpty)
          'descriptionSelector': d.descriptionSelector,
        if (d.coverSelector.isNotEmpty) ...{
          'coverSelector': d.coverSelector,
          'coverAttr': d.coverAttr,
        },
        if (d.genreSelector.isNotEmpty) ...{
          'genreSelector': d.genreSelector,
          if (d.genreAttr.isNotEmpty) 'genreAttr': d.genreAttr,
        },
      };
    default:
      return const {};
  }
}

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    this.row,
    this.workspace,
    required this.title,
    required this.initialText,
  });

  /// The workspace row this config belongs to, or null for a scratch config.
  final SourceRow? row;
  final Workspace? workspace;
  final String title;
  final String initialText;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

/// What the archive-reason dialog's non-cancel buttons resolve to.
enum _ArchiveAction { save, unarchive }

class _DetailScreenState extends State<DetailScreen> {
  late final JsonEditingController _controller;
  late final ProbeState _probe;

  // Stage-runner state: which single stage to run and its inputs.
  ProbeStage _stage = ProbeStage.full;
  final _stageInput = TextEditingController();
  final _pageInput = TextEditingController(text: '1');

  // Tag stage: when the source's `tag` listing shares a query param with one
  // of its own `filters` groups (see `tagRelevantFilters`), that group's
  // already-known options replace the free-text field with a proper
  // include/exclude picker: no guessing valid tag spellings. Null = not
  // checked yet for the current config text; empty = checked, no match,
  // free text stays.
  List<FilterGroup>? _tagFilterGroups;
  bool _loadingTagFilters = false;
  FilterSelection _tagSelection = FilterSelection();

  /// User opt-out of the picker (a "Raw" checkbox, shown once a picker is
  /// available), back to the free-text field, e.g. to try a tag the
  /// source doesn't declare in `filters` at all (an undocumented/secret
  /// one). Doesn't clear `_tagSelection`; toggling back to managed mode
  /// keeps whatever was picked.
  bool _tagFreeForm = false;

  // Search stage: every filter group the source declares (type, status,
  // tags, …), shown alongside the free-text query, not replacing it, since
  // `search(query, filters)` combines both. Same null/empty convention as
  // the Tag stage's picker state above.
  List<FilterGroup>? _searchFilterGroups;
  bool _loadingSearchFilters = false;
  FilterSelection _searchFilterSelection = FilterSelection();

  // Editor mode: structured form vs raw JSON.
  bool _formMode = false;

  bool _dirty = false;
  AnySourceConfig? _parsed;
  String? _parseError;

  /// Background "does this site need webview: true" check (see
  /// [_maybeCheckWebviewNeed]) — null until it resolves with something
  /// worth showing. [_webviewSuggestionDismissed] tracks the banner's own
  /// close button separately, so re-triggering the check (it doesn't,
  /// currently, but the split keeps "resolved" and "user closed it"
  /// independent) never un-dismisses it.
  WebviewSuggestion? _webviewSuggestion;
  bool _webviewSuggestionDismissed = false;
  bool _checkedWebviewNeed = false;

  @override
  void initState() {
    super.initState();
    _controller = JsonEditingController(text: widget.initialText);
    _controller.addListener(_onChanged);
    // Share the row's probe state so results probed here show in the table.
    _probe = widget.row?.probe ?? ProbeState();
    _reparse();
    _maybeCheckWebviewNeed();
  }

  @override
  void dispose() {
    _controller.dispose();
    _stageInput.dispose();
    _pageInput.dispose();
    super.dispose();
  }

  void _onChanged() {
    _dirty = _controller.text != widget.initialText;
    _reparse();
  }

  void _reparse() {
    setState(() {
      // The config text changed: a stale picker (built from the old text)
      // would offer options that may no longer be valid.
      _tagFilterGroups = null;
      _tagSelection = FilterSelection();
      _searchFilterGroups = null;
      _searchFilterSelection = FilterSelection();
      if (_controller.text.trim().isEmpty) {
        _parsed = null;
        _parseError = null;
        return;
      }
      try {
        _parsed = parseConfig(_controller.text);
        _parseError = null;
      } catch (e) {
        _parsed = null;
        _parseError = '$e';
      }
    });
    if (_stage == ProbeStage.tag) _maybeLoadTagFilters();
    if (_stage == ProbeStage.search) _maybeLoadSearchFilters();
  }

  /// Kicks off the tag-picker's option load once, when the Tag stage is
  /// active and the config has a `filters` group matching `tag`'s own
  /// param, a no-op (stays empty) otherwise, leaving the free-text field
  /// in place.
  void _maybeLoadTagFilters() {
    if (_tagFilterGroups != null || _loadingTagFilters) return;
    final parsed = _parsed;
    if (parsed == null || tagRelevantFilters(parsed).isEmpty) {
      setState(() => _tagFilterGroups = const []);
      return;
    }
    setState(() => _loadingTagFilters = true);
    loadTagFilterGroups(_controller.text)
        .then((groups) {
          if (!mounted) return;
          setState(() {
            _tagFilterGroups = groups;
            _loadingTagFilters = false;
          });
        })
        .catchError((Object _) {
          // Falls back to free text; the Cloudflare-guarded stage run
          // itself is still the reliable path for a gated source.
          if (!mounted) return;
          setState(() {
            _tagFilterGroups = const [];
            _loadingTagFilters = false;
          });
        });
  }

  /// Kicks off the Search stage's filter-picker load once: every group the
  /// source declares, shown alongside the query field rather than replacing
  /// it (search combines free text and filters).
  void _maybeLoadSearchFilters() {
    if (_searchFilterGroups != null ||
        _loadingSearchFilters ||
        _parsed == null) {
      return;
    }
    setState(() => _loadingSearchFilters = true);
    loadFilterGroups(_controller.text)
        .then((groups) {
          if (!mounted) return;
          setState(() {
            _searchFilterGroups = groups;
            _loadingSearchFilters = false;
          });
        })
        .catchError((Object _) {
          if (!mounted) return;
          setState(() {
            _searchFilterGroups = const [];
            _loadingSearchFilters = false;
          });
        });
  }

  /// Kicks off a background check for whether this source might need
  /// `webview: true` (see `diagnoseWebviewNeed`'s doc) — once per
  /// screen-open, matching [_maybeLoadTagFilters]/[_maybeLoadSearchFilters]'s
  /// pattern. Only while the config still looks like a fresh, unconfigured
  /// scaffold (blank `popular`, `webview` not already on) and this platform
  /// can drive a WebView at all — covers both the moment a source is
  /// scaffolded from a URL and any later reopen of a still-unconfigured
  /// prototype, since both are just a fresh `DetailScreen`/fresh
  /// `initState`. A source whose `popular` is already configured (hand-
  /// written or already picked) never reaches the fetch at all.
  void _maybeCheckWebviewNeed() {
    if (_checkedWebviewNeed || !cloudflareSolveSupported) return;
    final parsed = _parsed;
    if (parsed is! SourceConfig || parsed.webview) return;
    if (popularConfigured(parsed)) return;
    final url = Uri.tryParse(parsed.baseUrl);
    if (url == null) return;
    _checkedWebviewNeed = true;
    diagnoseWebviewNeed(url).then((suggestion) {
      if (!mounted || suggestion == null) return;
      setState(() => _webviewSuggestion = suggestion);
    });
  }

  /// The most recent HTML body the probe fetched (last non-JSON trace body):
  /// the document the Form's selector tester runs against.
  String? get _lastProbedHtml {
    for (final t in _probe.traces.reversed) {
      final b = t.body.trimLeft();
      if (b.isNotEmpty && !b.startsWith('{') && !b.startsWith('[')) {
        return t.body;
      }
    }
    return null;
  }

  /// [_lastProbedHtml] scoped to [url] specifically — what the picker needs.
  /// Unlike the Form's selector tester (always "whatever was last probed",
  /// which is exactly what it's testing against by design), the picker
  /// targets a *different* page every time it opens once chapters/pages/
  /// details and seed-from-result are in play; blindly reusing the most
  /// recent trace regardless of its URL cross-checks a click against the
  /// wrong page's HTML and silently reports "0 matches" for a selector that
  /// would actually be fine — confirmed live: this is exactly what made a
  /// real pick on a live source look broken (the last trace was `popular`'s
  /// homepage; the picker had been reopened on the search page). Null both
  /// when nothing matches [url] and when the match is JSON, not HTML.
  String? _probedHtmlFor(Uri url) {
    final target = url.toString();
    for (final t in _probe.traces.reversed) {
      if (t.requestUrl != target) continue;
      final b = t.body.trimLeft();
      if (b.isNotEmpty && !b.startsWith('{') && !b.startsWith('[')) {
        return t.body;
      }
    }
    return null;
  }

  bool get _tagPickerActive =>
      !_tagFreeForm && (_tagFilterGroups?.isNotEmpty ?? false);

  void _run(ProbeStage stage) {
    final page = int.tryParse(_pageInput.text.trim()) ?? 1;
    final usingTagPicker = stage == ProbeStage.tag && _tagPickerActive;
    runStage(
      _probe,
      _controller.text,
      stage,
      input: usingTagPicker
          ? _tagSelection.allIncluded.join(',')
          : _stageInput.text.trim(),
      excludedTags: usingTagPicker
          ? _tagSelection.allExcluded.toSet()
          : const {},
      filters: stage == ProbeStage.search ? _searchFilterSelection : null,
      page: page,
      onUpdate: () {
        if (mounted) setState(() {});
        widget.workspace?.ping(); // keep the table's status cell in sync
      },
      // Headless solve first; if the challenge needs a human (Turnstile),
      // fall back to a visible solver window right here.
      onChallenge: (url) =>
          solveCloudflare(url, context: mounted ? context : null),
      onDone: (state) {
        probeStore?.record(state, tier: widget.row?.tier.name);
        if (mounted) setState(() {}); // refresh the history panel
      },
    );
  }

  /// Switching stage always starts from a blank input: a value left over
  /// from a different stage (a chapter url sitting in what's now the search
  /// query box) is never valid there, so it's cleared unconditionally
  /// first. Then pre-fills from the last run's first result (the chain
  /// `probeSource` would have followed) so a one-click "run details on what
  /// popular just returned" still works.
  void _onStageChanged(ProbeStage stage) {
    setState(() {
      _stage = stage;
      _stageInput.clear();
      if ((stage == ProbeStage.details || stage == ProbeStage.chapters) &&
          (_probe.popular?.isNotEmpty ?? false)) {
        _stageInput.text = _probe.popular!.first.url;
      } else if (stage == ProbeStage.pages &&
          (_probe.chapters?.isNotEmpty ?? false)) {
        _stageInput.text = _probe.chapters!.first.url;
      } else if (stage == ProbeStage.tag &&
          (_probe.details?.genres.isNotEmpty ?? false)) {
        _stageInput.text = _probe.details!.genres.first;
      }
    });
    if (stage == ProbeStage.tag) _maybeLoadTagFilters();
    if (stage == ProbeStage.search) _maybeLoadSearchFilters();
  }

  void _save() {
    final file = widget.row?.file;
    if (file != null) {
      file.writeAsStringSync(_controller.text);
      widget.workspace?.refresh(); // probe states survive (keyed carry-over)
      setState(() => _dirty = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
      return;
    }
    _promote();
  }

  /// A dormant row has no backing file; "Promote" creates one, writing the
  /// editor's current text (the dormant config, plus whatever fix was made
  /// in place, e.g. turning on `webview`) to `extensions/<id>.json`. Same
  /// target path a workspace's promote step writes to; unlike
  /// that CLI tool this carries live edits, not just the untouched dormant
  /// entry. Guards against the one thing that tool also guards against: a
  /// pkg that's already promoted under a different id (a multi-language
  /// extension where a sibling language got promoted first).
  void _promote() {
    final row = widget.row;
    final ws = widget.workspace;
    final root = ws?.root;
    if (row == null || ws == null || root == null) return;
    final id = row.id;
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Can't promote: this config has no id.")),
      );
      return;
    }
    final collisions = ws.rows.where(
      (r) => r.tier == Tier.active && r.pkg == row.pkg,
    );
    if (collisions.isNotEmpty) {
      final collision = collisions.first;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Not promoted: pkg "${row.pkg}" is already active as '
            '"${collision.id}".',
          ),
        ),
      );
      return;
    }
    final file = File('$root/extensions/$id.json');
    file.writeAsStringSync(_controller.text);
    ws.refresh();
    setState(() => _dirty = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Promoted to active: ${file.path}')));
  }

  /// Ensures [text]'s root is wrapped the way every `extensions/*.json` file
  /// already is (`{name, pkg, version, lang, nsfw, sources: [...]}`), since
  /// the workspace loader's `_addEntryRows` (shared by active/prototyping/
  /// dormant rows) reads sources out of that `sources` list — a bare source
  /// object (what both the "Scratch config" sample and the URL-scaffolded
  /// starter produce) would silently load as zero rows otherwise. Already-
  /// wrapped input (a config that started from a real row) passes through
  /// untouched.
  String _asExtensionEntry(String text, AnySourceConfig parsed) {
    final root = jsonDecode(text);
    final entry = root is List ? root.first : root;
    if (entry is Map && entry.containsKey('sources')) {
      return '${const JsonEncoder.withIndent('  ').convert(root)}\n';
    }
    final wrapped = {
      'name': parsed.name,
      'pkg': 'app.konimanga.extension.${parsed.lang}.${parsed.id}',
      'version': '0.1.0',
      'lang': parsed.lang,
      'nsfw': 0,
      'sources': [entry],
    };
    return '${const JsonEncoder.withIndent('  ').convert(wrapped)}\n';
  }

  /// Writes the current scratch buffer to `prototypes/<id>.json` and re-opens
  /// this source as a real, file-backed `Tier.prototyping` row — the missing
  /// other half of "New source from URL" (table_screen.dart): that flow
  /// gets you to a working `popular` block, this is what actually persists
  /// it into the workspace. Kept out of `extensions/` (and therefore every
  /// build/publish/candidate tool, which only ever globs `extensions/*.json`
  /// — see `_loadPrototypes` in workspace.dart) until deliberately promoted,
  /// so a WIP source can't accidentally reach a production build.
  Future<void> _saveAsPrototype() async {
    final ws = widget.workspace;
    final root = ws?.root;
    final parsed = _parsed;
    if (ws == null || root == null || parsed == null) return;
    final id = parsed.id;
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Can't save: this config has no id.")),
      );
      return;
    }
    final collision = ws.rows.where((r) => r.id == id);
    if (collision.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Not saved: id "$id" already exists '
            '(${collision.first.tier.name}). Change the id first.',
          ),
        ),
      );
      return;
    }
    Directory('$root/prototypes').createSync(recursive: true);
    final file = File('$root/prototypes/$id.json');
    file.writeAsStringSync(_asExtensionEntry(_controller.text, parsed));
    ws.refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved as prototype: ${file.path}')));
    final newRow = ws.rows
        .where((r) => r.tier == Tier.prototyping && r.id == id)
        .firstOrNull;
    if (newRow == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          row: newRow,
          workspace: ws,
          title: '${newRow.name} · ${newRow.id}',
          initialText: newRow.editorText(),
        ),
      ),
    );
  }

  /// Graduates a `Tier.prototyping` row to `extensions/<id>.json` (same
  /// target [_promote] writes for a dormant row) and deletes the prototype
  /// file so it doesn't linger as a stale duplicate once the source is
  /// live. Pops back to the table rather than staying on this screen (unlike
  /// [_promote]): the delete makes `widget.row.file` point at a path that no
  /// longer exists, and staying open would let a later Save resurrect it via
  /// `writeAsStringSync`. The active write happens before the delete, so a
  /// failure writing the active file leaves the prototype untouched.
  Future<void> _promoteToActive() async {
    final row = widget.row;
    final ws = widget.workspace;
    final root = ws?.root;
    final parsed = _parsed;
    if (row == null || ws == null || root == null || parsed == null) return;
    // parsed.id, not row.id: if the id was edited in this session (before
    // promoting), row.id is the *original* one — using it here would write
    // extensions/<old-id>.json with content whose own "id" field says
    // something else entirely, and check collisions against the wrong id.
    final id = parsed.id;
    if (id.isEmpty) return;
    final collisions = ws.rows.where(
      (r) => r.tier == Tier.active && r.id == id,
    );
    if (collisions.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not promoted: "$id" is already active.')),
      );
      return;
    }
    final activeFile = File('$root/extensions/$id.json');
    activeFile.writeAsStringSync(_asExtensionEntry(_controller.text, parsed));
    final prototypeFile = row.file;
    if (prototypeFile != null && prototypeFile.existsSync()) {
      prototypeFile.deleteSync();
    }
    ws.refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Promoted to active: ${activeFile.path}')),
    );
    Navigator.of(context).pop();
  }

  /// Archive (with a reason), edit an already-archived source's reason, or
  /// un-archive it: "archived" marks a source we deliberately won't pursue
  /// (curation/archived.json). Always opens the reason dialog, pre-filled
  /// with the current reason when already archived, so re-confirming or
  /// updating why a source is archived doesn't require un-archiving first.
  Future<void> _toggleArchived() async {
    final row = widget.row;
    final ws = widget.workspace;
    if (row == null || ws == null) return;
    final controller = TextEditingController(text: row.archivedReason ?? '');
    final action = await showDialog<_ArchiveAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          row.archived
              ? 'Edit archive reason — ${row.name}'
              : 'Archive ${row.name}',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Why? (site broken, not worth the effort, …)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (row.archived)
            TextButton(
              onPressed: () => Navigator.pop(context, _ArchiveAction.unarchive),
              child: const Text('Un-archive'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ArchiveAction.save),
            child: Text(row.archived ? 'Save' : 'Archive'),
          ),
        ],
      ),
    );
    switch (action) {
      case null:
        return;
      case _ArchiveAction.unarchive:
        ws.setArchived(row.id, null);
      case _ArchiveAction.save:
        final reason = controller.text.trim();
        ws.setArchived(row.id, reason.isEmpty ? 'archived' : reason);
    }
    setState(() {});
  }

  /// The parsed config's `loginUrl` (HTML dialect only: the API dialect
  /// doesn't carry this field yet), or null when there's nothing to log into.
  String? get _loginUrl {
    final parsed = _parsed;
    if (parsed is! SourceConfig || parsed.loginUrl.isEmpty) return null;
    return parsed.loginUrl;
  }

  /// The parsed config's `localStoragePreferences` (HTML dialect only, same
  /// as `_loginUrl`), empty when there's nothing to toggle.
  List<LocalStoragePreferenceConfig> get _consentPreferences {
    final parsed = _parsed;
    return parsed is SourceConfig ? parsed.localStoragePreferences : const [];
  }

  /// Opens a dialog with one switch per `_consentPreferences` entry, read/
  /// written through `playgroundConsent`, so a config author can flip a
  /// declared toggle and re-run a probe stage to see whether the result
  /// changes, the same reason `_login` exists for `loginUrl`.
  Future<void> _openConsentPreferences() async {
    final parsed = _parsed;
    final prefs = _consentPreferences;
    if (parsed is! SourceConfig || prefs.isEmpty) return;
    final current = Map<String, bool>.of(
      playgroundConsent.valuesFor(parsed.id),
    );
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Content preferences'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final pref in prefs)
                  SwitchListTile(
                    title: Text(pref.label),
                    value: current[pref.id] ?? pref.defaultValue,
                    onChanged: (value) {
                      setDialogState(() => current[pref.id] = value);
                      playgroundConsent.save(parsed.id, pref.id, value);
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  bool _loggingIn = false;

  /// Opens the login WebView so a config author can actually exercise a
  /// login-gated corner of the source; re-run a probe stage afterward to see
  /// whether it comes alive (the session lives in the shared WebView cookie
  /// jar the probe's own fetches already use, so nothing else here needs to
  /// change for that to work).
  Future<void> _login() async {
    final url = Uri.tryParse(_loginUrl ?? '');
    if (url == null || _loggingIn) return;
    setState(() => _loggingIn = true);
    final ok = await login(url, context: mounted ? context : null);
    if (!mounted) return;
    setState(() => _loggingIn = false);
    if (ok) setState(() {}); // refresh the lock icon
  }

  /// Opens *any* URL in the same interactive WebView `_login` uses, not
  /// login-specific at all, despite reusing that machinery: some sites gate
  /// content behind a one-time, purely client-side click-through (e.g. a
  /// "confirm you're 18" interstitial). Useful for anything that click-through
  /// sets as *cookie* state: the WebView's cookie jar genuinely is shared
  /// process-wide with the probe's own fetches (confirmed live: this is how
  /// login sessions carry over). **Not** useful for a `localStorage`-backed
  /// flag specifically: confirmed live that a value set here, in this
  /// separate interactive `InAppWebView`, does not reach the probe's own
  /// persistent `HeadlessInAppWebView` instance: those two apparently don't
  /// share a storage jar the way they share cookies. For that case, use
  /// `SourceConfig.localStorageSeed` instead (applied by the fetcher itself,
  /// on its own WebView, no separate dialog involved).
  Future<void> _openUrl() async {
    final controller = TextEditingController(text: _parsed?.baseUrl ?? '');
    final url = await showDialog<Uri>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open URL in WebView'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'URL',
            hintText: 'https://example.com/whatever-needs-a-manual-click',
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
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (url == null || !mounted) return;
    await login(url, context: mounted ? context : null);
  }

  bool _picking = false;

  /// Whether the point-and-click picker (any of popular/chapters/pages/
  /// details) is available at all: the platform can drive a WebView, and
  /// there's an HTML-dialect config to pick selectors into (API-dialect
  /// sources have no DOM to click on).
  bool get _canPick => cloudflareSolveSupported && _parsed is SourceConfig;

  /// Whether a probe is currently in flight — gates the picker triggers
  /// (see the toolbar's `PopupMenuButton` and `ConfigForm.onPickRequested`
  /// below): a picker's own "probe first if nothing's cached yet" step
  /// calls `runStage`, which silently no-ops while one is already running,
  /// so opening the picker mid-probe would otherwise skip that step
  /// instead of failing loudly or waiting.
  bool get _probeRunning => _probe.phase == ProbePhase.running;

  /// Whether the current config already has `webview: true` — gates the
  /// picker's "this site might need webview" callout (see [_pickFromPage]):
  /// never shown once it's already on, since a mismatch there means
  /// something else entirely.
  bool get _sourceUsesWebview {
    final parsed = _parsed;
    return parsed is SourceConfig && parsed.webview;
  }

  /// Set by "target this" on a Popular/Chapters result in [ResultsPane]
  /// (see [_targetForPicking]): the next [_pickFromPage] call uses this as
  /// the picker's default URL instead of the generic per-block guess.
  /// Stays set across repeated details/chapters/pages picks — those all
  /// point at the same series/chapter, so losing the target on every
  /// reopen would force re-targeting for no reason — and
  /// [_promptForPickerUrl] always shows "Targeting: {label}" whenever this
  /// is set, so a stale target is visible, never silent. Only cleared when
  /// a `popular` pick completes (that block targets the listing page
  /// itself, not a specific series — reusing a leftover single-item target
  /// there would actually be wrong) or when the user targets something new.
  ({String url, String label})? _pickTarget;

  void _targetForPicking(String url, String label) {
    setState(() => _pickTarget = (url: url, label: label));
  }

  /// Dispatches a picker trigger — the toolbar menu and each
  /// `ConfigForm._operationSection`'s inline icon both call this with the
  /// same [opKey] values (`'popular'`/`'chapters'`/`'pages'`/`'details'`).
  void _pickOp(String opKey) => opKey == 'details'
      ? _pickDetailsFromPage(
          seed: _configSeed(opKey),
          seedRows: _configSeedRows(),
        )
      : _pickFromPage(opKey, _stepsForOp(opKey), seed: _configSeed(opKey));

  /// [opKey]'s already-configured selectors (see [existingPickedFields]),
  /// wrapped as a picker [PickResult] so it can be passed straight through
  /// as a `seed` — null (not an empty one) when there's nothing configured
  /// yet, so the picker opens exactly as it did before this existed.
  PickResult? _configSeed(String opKey) {
    final fields = existingPickedFields(opKey, _parsed);
    return fields.isEmpty ? null : (fields: fields, previews: const {});
  }

  /// [_configSeed]'s counterpart for `details.rows` — the picker's own
  /// `_RowsDraft.fromConfig` (private to `koni_dojo_webview.dart`) does the
  /// actual seed→draft round trip; this just reads the raw, already-parsed
  /// [RowsConfig] straight off the current config.
  RowsConfig? _configSeedRows() {
    final parsed = _parsed;
    return parsed is SourceConfig ? parsed.details.rows : null;
  }

  /// The linear-wizard step list for [opKey] — everything but `details`,
  /// which uses its own field-palette dialog ([_pickDetailsFromPage]) since
  /// it has no repeating item to detect.
  List<FieldStep> _stepsForOp(String opKey) => switch (opKey) {
    'chapters' => chaptersSteps,
    'pages' => pagesSteps,
    _ => popularSteps,
  };

  /// The `ProbeStage` that fetches the page a [opKey] block's selectors are
  /// picked against — run once first (if nothing's been probed yet) so the
  /// picker has real `engineHtml` to cross-check candidates against, same
  /// as `popular` already did. Null for a block with no picker (nothing
  /// calls this for those).
  ProbeStage? _stageForOp(String opKey) => switch (opKey) {
    'popular' => ProbeStage.popular,
    'chapters' => ProbeStage.chapters,
    'pages' => ProbeStage.pages,
    'details' => ProbeStage.details,
    _ => null,
  };

  /// Best-guess URL to open for the "Pick from page" wizard. A targeted
  /// result (see [_pickTarget]) always wins — it's a real, resolved series
  /// or chapter URL, better than any guess. Otherwise: for `popular`, the
  /// source's own `popular.path` if the config already has one (crudely
  /// resolving `{page}`/`{offset}` templates to their first-page values —
  /// good enough to land on a real listing page, not a faithful
  /// reproduction of the engine's own pagination); every other block has no
  /// generic guess without a target (there's no config field pointing at
  /// "a" manga/chapter page), so it falls back to `baseUrl`. Always shown
  /// in an editable prompt rather than used silently, since this guess can
  /// be wrong and opening the visible WebView is disruptive enough that the
  /// user should confirm first.
  String _pickerDefaultUrl(String opKey) {
    final target = _pickTarget;
    if (target != null) return target.url;
    final parsed = _parsed;
    final baseUrl = parsed?.baseUrl ?? '';
    if (opKey != 'popular' ||
        parsed is! SourceConfig ||
        parsed.popular.path.isEmpty) {
      return baseUrl;
    }
    final path = parsed.popular.path
        .replaceAll('{page}', '1')
        .replaceAll('{offset}', '0');
    return path.startsWith('http') ? path : '$baseUrl$path';
  }

  Future<Uri?> _promptForPickerUrl(String opKey) {
    final target = _pickTarget;
    final controller = TextEditingController(text: _pickerDefaultUrl(opKey));
    return showDialog<Uri>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pick selectors from a page'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (target != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Targeting: ${target.label}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'URL — the page to click through',
                hintText: 'https://example.com/manga/page/1/',
              ),
              onSubmitted: (v) =>
                  Navigator.pop(context, Uri.tryParse(v.trim())),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, Uri.tryParse(controller.text.trim())),
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }

  /// Opens the guided point-and-click picker for [opKey]'s block ([steps] —
  /// [popularSteps]/[chaptersSteps]/[pagesSteps]). Runs the matching single
  /// stage first if nothing's been probed yet (seeded with the picker's own
  /// target URL for anything past `popular`, which needs no input), so the
  /// picker can cross-check every candidate the user clicks against the
  /// engine's own parse (`pickFields`' `engineHtml`) instead of only the
  /// browser's rendered DOM, which can disagree on JS-hydrated pages.
  ///
  /// [presetUrl] skips the URL prompt. [forceReprobe] (default true when a
  /// [presetUrl] is given) forces a fresh probe, bypassing the
  /// `_probedHtmlFor(url) == null` cache check — needed by the "Enable
  /// webview & retry" path below, re-opening the picker on the *exact* URL
  /// just picked against right after the config's fetch mode changed,
  /// where reusing a cached (pre-change) probe would defeat the whole
  /// point of retrying. "Back to picker" (see [_confirmApplyPicked]) passes
  /// `forceReprobe: false` instead — nothing about the site changed there,
  /// so forcing a reprobe would only add latency and Cloudflare-challenge
  /// risk for no reason.
  ///
  /// [seed] pre-populates the picker dialog with already-known
  /// fields/previews — either [_configSeed] (already-configured selectors)
  /// or, from "Back to picker", the in-progress result of the session just
  /// backed out of.
  Future<void> _pickFromPage(
    String opKey,
    List<FieldStep> steps, {
    Uri? presetUrl,
    bool forceReprobe = true,
    PickResult? seed,
  }) async {
    if (_picking) return;
    final url = presetUrl ?? await _promptForPickerUrl(opKey);
    if (url == null || !mounted) return;

    setState(() => _picking = true);
    final stage = _stageForOp(opKey);
    if (((presetUrl != null && forceReprobe) || _probedHtmlFor(url) == null) &&
        stage != null) {
      await runStage(
        _probe,
        _controller.text,
        stage,
        input: stage == ProbeStage.popular ? '' : url.toString(),
        onUpdate: () {
          if (mounted) setState(() {});
          widget.workspace?.ping();
        },
        onChallenge: (u) =>
            solveCloudflare(u, context: mounted ? context : null),
        onDone: (state) =>
            probeStore?.record(state, tier: widget.row?.tier.name),
      );
    }
    if (!mounted) return;

    // Set by the picker's "Enable webview & retry" callout — fires
    // synchronously from within the dialog, *before* pickFields resolves
    // (i.e. while _picking is still true), so it can't safely recurse into
    // _pickFromPage itself here; it just records the intent, and the
    // retry happens below once _picking is false again.
    var enableWebviewRequested = false;
    final result = await pickFields(
      url,
      steps: steps,
      engineHtml: _probedHtmlFor(url) ?? '',
      sourceUsesWebview: _sourceUsesWebview,
      onRequestEnableWebview: () => enableWebviewRequested = true,
      context: mounted ? context : null,
      seed: seed,
    );
    if (!mounted) return;
    setState(() {
      _picking = false;
      // Only `popular` targets the listing page itself, not a specific
      // series — reusing a leftover single-item target there would be
      // wrong. details/chapters/pages keep the target sticky (see
      // _pickTarget's doc) so repeated picks stay on the same series.
      if (opKey == 'popular') _pickTarget = null;
    });
    if (enableWebviewRequested) {
      _setSourceWebview(true);
      await _pickFromPage(opKey, steps, presetUrl: url, seed: seed);
      return;
    }
    final fields = result?.fields;
    // `popular` is the one block the picker's own target URL should also
    // persist into — see pathFromPickedUrl's doc for why this was missing.
    // chapters/pages/details have no equivalent `path` field: they're
    // reached by following a URL discovered from the previous stage, not a
    // fixed listing location. Only fills a currently-*blank* path (see
    // popularPathIsUnset) — never overwrites one already set, since the
    // picker's own target URL and the config's real listing path can
    // deliberately diverge (a pagination template, or a site where the
    // clickable page and the actual data endpoint are different URLs).
    final parsed = _parsed;
    if (opKey == 'popular' && fields != null && popularPathIsUnset(parsed)) {
      fields['path'] = pathFromPickedUrl(url, parsed?.baseUrl ?? '');
    }
    if (fields == null || !mounted) return;
    switch (await _confirmApplyPicked(opKey, fields, steps, result!.previews)) {
      case ApplyPickedDecision.apply:
        _applyPickedFields(opKey, fields);
      case ApplyPickedDecision.back:
        await _pickFromPage(
          opKey,
          steps,
          presetUrl: url,
          forceReprobe: false,
          seed: (fields: fields, previews: result.previews),
        );
      case ApplyPickedDecision.discard:
        break;
    }
  }

  /// Decode-mutate-encode-write round trip shared by every direct writer of
  /// `_controller.text`'s JSON ([_setSourceWebview], [_applyPickedFields]):
  /// parse (blank/invalid text treated as "start fresh"), unwrap to the
  /// source object via [extractSource] (creating one if the buffer was
  /// empty or unparseable), let [mutate] touch it in place, then re-encode
  /// and write back with the cursor pinned to the end. Pulled out after
  /// Fable's session review flagged the two writers as identical apart from
  /// their mutation step — [_asExtensionEntry] and `ConfigForm`'s own
  /// `_emit` look similar but solve different problems (shape-wrapping for
  /// a *file* write; a persistent, per-keystroke `_root` instead of a
  /// single-shot parse) and don't fit this shape.
  void _mutateConfigSource(void Function(Map<String, dynamic> source) mutate) {
    Object? root;
    try {
      root = _controller.text.trim().isEmpty
          ? null
          : jsonDecode(_controller.text);
    } catch (_) {
      root = null;
    }
    var source = root == null ? null : extractSource(root);
    if (source == null) {
      source = <String, dynamic>{};
      root = source;
    }
    mutate(source);
    final text = '${const JsonEncoder.withIndent('  ').convert(root)}\n';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Sets the top-level `webview` field directly in `_controller.text`'s
  /// JSON, same convention [_applyPickedFields] uses for a nested block.
  void _setSourceWebview(bool value) {
    _mutateConfigSource((source) => source['webview'] = value);
  }

  Widget _pickedFieldRow(ThemeData theme, PickedFieldGroup group) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: theme.textTheme.labelLarge,
              children: [
                TextSpan(text: group.label),
                if (group.attr != null)
                  TextSpan(
                    text: '   attr: ${group.attr}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              breakableSelector(group.value),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
          if (group.preview != null && group.preview!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.visibility_outlined,
                  size: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    group.preview!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Summarizes what the wizard just picked and asks what to do with it —
  /// otherwise finishing the wizard has no visible effect beyond the
  /// JSON/Form view silently changing underneath the user, easy to miss and
  /// with no chance to back out of a bad pick. [steps] supplies human field
  /// labels (see [pickedFieldLabel]) — the same list the wizard itself
  /// walked, or [detailsFields] for the palette. [previews] is the picker's
  /// own [PickResult.previews], shown alongside each selector (see
  /// [groupPickedFields]) so a pick can be sanity-checked without
  /// re-opening the picker.
  Future<ApplyPickedDecision> _confirmApplyPicked(
    String opKey,
    PickedFields fields,
    List<FieldStep> steps,
    Map<String, String> previews, {
    RowsConfig? rows,
  }) async {
    final groups = groupPickedFields(fields, steps, previews);
    final result = await showDialog<ApplyPickedDecision>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text('Apply picked $opKey selectors?'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Counts rows below (attr companions folded in, see
                    // groupPickedFields), not fields.length's raw JSON key
                    // count — those can differ once an *Attr key is folded
                    // into its selector's row, and the two numbers
                    // disagreeing read as a bug, not a rounding choice.
                    'This sets ${groups.length} field'
                    '${groups.length == 1 ? '' : 's'} in $opKey'
                    '${rows == null ? '' : ' (plus a rows block)'}:',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  for (final group in groups) _pickedFieldRow(theme, group),
                  if (rows != null)
                    _pickedRowsSection(theme, rows, previews, fields),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, ApplyPickedDecision.discard),
              child: const Text('Discard'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, ApplyPickedDecision.back),
              child: const Text('Back to picker'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, ApplyPickedDecision.apply),
              child: const Text('Apply to config'),
            ),
          ],
        );
      },
    );
    return result ?? ApplyPickedDecision.discard;
  }

  /// [rows]' own summary in the confirm dialog — a nested [RowsConfig]
  /// doesn't fit [groupPickedFields]'s flat-selector-row model, so this is
  /// a small, separate renderer in the same visual language
  /// (`SelectableText`, monospace). [previews] carries each field's
  /// already-simulated multi-value preview under the `'rows.<field>'` key
  /// (see `_DetailsPickerDialogState._syncPendingIfValid`'s `_ArmedRowsValue`
  /// case) — there's no live document here to re-simulate against.
  Widget _pickedRowsSection(
    ThemeData theme,
    RowsConfig rows,
    Map<String, String> previews,
    PickedFields flatFields,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Rows', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              'row: ${breakableSelector(rows.itemSelector)}   '
              'label: ${breakableSelector(rows.labelSelector)}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
          for (final entry in rows.fields.entries)
            _pickedRowsFieldRow(theme, entry.key, entry.value, previews),
          for (final entry in rows.fields.entries)
            if (flatFields.containsKey('${entry.key}Selector'))
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text(
                  'Note: a flat "${entry.key}Selector" is also set above — '
                  'rows values win at scrape time, so that becomes a '
                  'fallback.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _pickedRowsFieldRow(
    ThemeData theme,
    String fieldKey,
    RowField field,
    Map<String, String> previews,
  ) {
    final preview = previews['rows.$fieldKey'];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: theme.textTheme.labelMedium,
              children: [
                TextSpan(text: fieldKey),
                TextSpan(
                  text: '   labels: ${field.labels.join(', ')}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            field.valueSelector.isEmpty
                ? '(the row\'s own text)'
                : breakableSelector(field.valueSelector),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          ),
          if (preview != null && preview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      preview,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Writes a picker result straight into `_controller.text`'s underlying
  /// JSON — not through a live `ConfigForm` instance, so this works
  /// identically whether the user is currently looking at the Form tab or
  /// the raw JSON tab. Mirrors `ConfigForm`'s own parse/re-serialize
  /// convention (`extractSource`, pretty-printed with the same indent) so
  /// the result reads as a normal hand-edit, not a special case. Creates
  /// the [opKey] block (and, if the config was entirely blank, the source
  /// object itself) when it doesn't exist yet, so picking works starting
  /// from nothing, not just a config that already has the block scaffolded.
  void _applyPickedFields(
    String opKey,
    PickedFields fields, {
    RowsConfig? rows,
  }) {
    _mutateConfigSource((source) {
      final existing = source[opKey];
      final block = existing is Map
          ? existing.cast<String, dynamic>()
          : (source[opKey] = <String, dynamic>{});
      fields.forEach((key, value) => block[key] = value);
      // Additive-only, same convention as every flat field above: never
      // clears an already-configured `rows` block the user didn't touch
      // this session (e.g. picked nothing under Rows… this time).
      if (rows != null) block['rows'] = rows.toJson();
    });
  }

  /// [_pickFromPage]'s counterpart for `details`, whose picker is a field
  /// palette ([pickDetailsFields]) rather than a [FieldStep]-list wizard —
  /// see `detailsFields`'s doc for why. Otherwise identical, including the
  /// [presetUrl]/[forceReprobe]/[seed] retry path (see [_pickFromPage]'s
  /// doc).
  Future<void> _pickDetailsFromPage({
    Uri? presetUrl,
    bool forceReprobe = true,
    PickResult? seed,
    RowsConfig? seedRows,
  }) async {
    if (_picking) return;
    final url = presetUrl ?? await _promptForPickerUrl('details');
    if (url == null || !mounted) return;

    setState(() => _picking = true);
    if ((presetUrl != null && forceReprobe) || _probedHtmlFor(url) == null) {
      await runStage(
        _probe,
        _controller.text,
        ProbeStage.details,
        input: url.toString(),
        onUpdate: () {
          if (mounted) setState(() {});
          widget.workspace?.ping();
        },
        onChallenge: (u) =>
            solveCloudflare(u, context: mounted ? context : null),
        onDone: (state) =>
            probeStore?.record(state, tier: widget.row?.tier.name),
      );
    }
    if (!mounted) return;

    var enableWebviewRequested = false;
    final result = await pickDetailsFields(
      url,
      engineHtml: _probedHtmlFor(url) ?? '',
      sourceUsesWebview: _sourceUsesWebview,
      onRequestEnableWebview: () => enableWebviewRequested = true,
      context: mounted ? context : null,
      seed: seed,
      seedRows: seedRows,
    );
    if (!mounted) return;
    // `details` always keeps the target sticky — see _pickTarget's doc.
    setState(() => _picking = false);
    if (enableWebviewRequested) {
      _setSourceWebview(true);
      await _pickDetailsFromPage(
        presetUrl: url,
        seed: seed,
        seedRows: seedRows,
      );
      return;
    }
    final fields = result?.fields;
    if (fields == null || !mounted) return;
    switch (await _confirmApplyPicked(
      'details',
      fields,
      detailsFields,
      result!.previews,
      rows: result.rows,
    )) {
      case ApplyPickedDecision.apply:
        _applyPickedFields('details', fields, rows: result.rows);
      case ApplyPickedDecision.back:
        await _pickDetailsFromPage(
          presetUrl: url,
          forceReprobe: false,
          seed: (fields: fields, previews: result.previews),
          seedRows: result.rows,
        );
      case ApplyPickedDecision.discard:
        break;
    }
  }

  /// [_maybeCheckWebviewNeed]'s result, shown above the editor — same
  /// visual language as the picker's own webview-mismatch callout
  /// (`_webviewMismatchCallout` in `koni_dojo_webview.dart`), so the two
  /// read as the same feature whether it caught you at scaffold time or
  /// mid-pick. "Enable webview" here just flips the flag (no specific pick
  /// to retry, unlike the picker's own action).
  Widget _webviewSuggestionBanner(ThemeData theme, WebviewSuggestion s) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.travel_explore, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text(s.reason, style: theme.textTheme.bodySmall)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              _setSourceWebview(true);
              setState(() => _webviewSuggestionDismissed = true);
            },
            child: const Text('Enable webview'),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _webviewSuggestionDismissed = true),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = widget.row;
    final fileBacked = row?.file != null;
    // A dormant row (has an id, isn't file-backed yet) can be promoted
    // straight to active; a scratch config (no row at all) has no
    // workspace target yet, but can be saved as a new prototyping row.
    final promotableFromDormant =
        row != null &&
        !fileBacked &&
        widget.workspace != null &&
        row.id.isNotEmpty;
    final canSaveAsPrototype =
        row == null &&
        widget.workspace?.root != null &&
        (_parsed?.id.isNotEmpty ?? false);
    final canPromoteToActive = row?.tier == Tier.prototyping;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (row != null && widget.workspace != null)
            IconButton(
              tooltip: row.archived
                  ? 'Edit archive reason or un-archive '
                        '(archived: ${row.archivedReason})'
                  : 'Archive — mark as not pursued',
              icon: Icon(
                row.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              onPressed: _toggleArchived,
            ),
          if (widget.workspace != null)
            BlurToggleAction(workspace: widget.workspace!),
          if (probeStore != null && (widget.row?.id ?? _parsed?.id) != null)
            IconButton(
              tooltip: 'Probe history & saved examples',
              icon: const Icon(Icons.history),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    _HistoryDialog(sourceId: widget.row?.id ?? _parsed!.id),
              ),
            ),
          if (_loginUrl != null && cloudflareSolveSupported)
            IconButton(
              tooltip: playgroundLogin.hasFor(_loginUrl!)
                  ? 'Logged in to ${Uri.tryParse(_loginUrl!)?.host ?? _loginUrl}'
                  : 'Log in — needed to probe login-gated content',
              icon: _loggingIn
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      playgroundLogin.hasFor(_loginUrl!)
                          ? Icons.lock_open_outlined
                          : Icons.lock_outline,
                    ),
              onPressed: _loggingIn ? null : _login,
            ),
          if (_consentPreferences.isNotEmpty)
            IconButton(
              tooltip:
                  'Content preferences — declared consent toggles for '
                  'this source',
              icon: const Icon(Icons.shield_outlined),
              onPressed: _openConsentPreferences,
            ),
          if (cloudflareSolveSupported)
            IconButton(
              tooltip:
                  'Open a URL in an interactive WebView — for a one-time '
                  'click-through (age gate, content-warning interstitial, …) '
                  'that has nothing to do with logging in',
              icon: const Icon(Icons.open_in_browser_outlined),
              onPressed: _openUrl,
            ),
          if (_canPick)
            _picking
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : PopupMenuButton<String>(
                    enabled: !_probeRunning,
                    tooltip: _probeRunning
                        ? 'Wait for the current probe to finish first'
                        : 'Pick selectors by clicking a live page, instead '
                              'of hand-writing them',
                    icon: const Icon(Icons.ads_click_outlined),
                    onSelected: _pickOp,
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'popular', child: Text('Popular')),
                      PopupMenuItem(value: 'details', child: Text('Details')),
                      PopupMenuItem(value: 'chapters', child: Text('Chapters')),
                      PopupMenuItem(value: 'pages', child: Text('Pages')),
                    ],
                  ),
          TextButton(
            onPressed: () {
              // Pretty-print in place; unparseable text is left alone (the
              // status line already shows why).
              try {
                _controller.text = prettyJson(_controller.text);
              } catch (_) {}
            },
            child: const Text('Format'),
          ),
          if (fileBacked)
            TextButton.icon(
              onPressed: _dirty ? _save : null,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save'),
            )
          else if (promotableFromDormant)
            TextButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.publish_outlined, size: 18),
              label: const Text('Promote'),
            )
          else if (canSaveAsPrototype)
            TextButton.icon(
              onPressed: _saveAsPrototype,
              icon: const Icon(Icons.science_outlined, size: 18),
              label: const Text('Save as prototype'),
            ),
          if (canPromoteToActive)
            TextButton.icon(
              onPressed: _promoteToActive,
              icon: const Icon(Icons.rocket_launch_outlined, size: 18),
              label: const Text('Promote to active'),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: (_parsed == null || _probeRunning)
                  ? null
                  : () => _run(ProbeStage.full),
              icon: _probeRunning
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: const Text('Full probe'),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (row != null) _HeaderStrip(row: row),
          if (_webviewSuggestion != null && !_webviewSuggestionDismissed)
            _webviewSuggestionBanner(theme, _webviewSuggestion!),
          _StageRunner(
            stage: _stage,
            stageInput: _stageInput,
            pageInput: _pageInput,
            running: _probeRunning,
            enabled: _parsed != null,
            onStageChanged: _onStageChanged,
            onRun: () => _run(_stage),
            tagFilterGroups: _tagFilterGroups,
            loadingTagFilters: _loadingTagFilters,
            tagSelection: _tagSelection,
            onTagSelectionChanged: () => setState(() {}),
            tagFreeForm: _tagFreeForm,
            onTagFreeFormChanged: (v) => setState(() => _tagFreeForm = v),
            searchFilterGroups: _searchFilterGroups,
            loadingSearchFilters: _loadingSearchFilters,
            searchFilterSelection: _searchFilterSelection,
            onSearchFilterSelectionChanged: () => setState(() {}),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _editor(theme)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: widget.workspace == null
                      ? ResultsPane(
                          state: _probe,
                          onTargetPicked: _canPick ? _targetForPicking : null,
                        )
                      : ListenableBuilder(
                          // Reacts live to the NSFW blur toggle even while
                          // this screen is already open: it's a
                          // screen-safety switch, flipping it should take
                          // effect immediately, not on the next navigation.
                          listenable: widget.workspace!,
                          builder: (context, _) => ResultsPane(
                            state: _probe,
                            blur: widget.workspace!.blurNsfw,
                            onTargetPicked: _canPick ? _targetForPicking : null,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _editor(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('JSON'),
                  icon: Icon(Icons.data_object, size: 16),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Form'),
                  icon: Icon(Icons.view_list, size: 16),
                ),
              ],
              selected: {_formMode},
              onSelectionChanged: (s) => setState(() => _formMode = s.first),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: _formMode
                ? ConfigForm(
                    // Rebuilds from the shared text; the form ignores its own
                    // emits so typing isn't interrupted.
                    text: _controller.text,
                    testHtml: _lastProbedHtml,
                    onChanged: (t) => _controller.value = TextEditingValue(
                      text: t,
                      selection: TextSelection.collapsed(offset: t.length),
                    ),
                    onPickRequested: _canPick && !_picking && !_probeRunning
                        ? _pickOp
                        : null,
                  )
                : TextField(
                    controller: _controller,
                    expands: true,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: ['Menlo', 'Consolas'],
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: _parseError != null
              ? Text(
                  _parseError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              : Text(
                  _parsed == null
                      ? 'Empty.'
                      : '${_parsed!.name} · ${_parsed!.id} · ${_parsed!.lang} · '
                            '${_parsed!.baseUrl}${_dirty ? '  (unsaved)' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
        ),
      ],
    );
  }
}

/// The stage runner: pick one operation, give it an input, and run it in
/// isolation (or run the full chain). The Extension Lab's "try a stage with
/// different parameters" affordance.
class _StageRunner extends StatelessWidget {
  const _StageRunner({
    required this.stage,
    required this.stageInput,
    required this.pageInput,
    required this.running,
    required this.enabled,
    required this.onStageChanged,
    required this.onRun,
    this.tagFilterGroups,
    this.loadingTagFilters = false,
    required this.tagSelection,
    this.onTagSelectionChanged,
    this.tagFreeForm = false,
    this.onTagFreeFormChanged,
    this.searchFilterGroups,
    this.loadingSearchFilters = false,
    required this.searchFilterSelection,
    this.onSearchFilterSelectionChanged,
  });

  final ProbeStage stage;
  final TextEditingController stageInput;
  final TextEditingController pageInput;
  final bool running;
  final bool enabled;
  final ValueChanged<ProbeStage> onStageChanged;
  final VoidCallback onRun;

  /// Null = not checked yet for this config; empty = checked, the source's
  /// `tag` doesn't share a param with any `filters` group, free text stays.
  /// Non-empty offers [_FilterGroupChips] below the control row, in place
  /// of the free-text field, unless [tagFreeForm] opts back out of it.
  final List<FilterGroup>? tagFilterGroups;
  final bool loadingTagFilters;
  final FilterSelection tagSelection;
  final VoidCallback? onTagSelectionChanged;

  /// User opt-out of the picker even though one's available, e.g. to try
  /// a tag the source doesn't declare in `filters` (an undocumented one).
  /// The "Raw" checkbox only appears once [tagFilterGroups] is non-empty;
  /// meaningless (and hidden) otherwise, since free text is already all
  /// there is.
  final bool tagFreeForm;
  final ValueChanged<bool>? onTagFreeFormChanged;

  /// Null = not checked yet; empty = the source declares no `filters` at
  /// all. Non-empty shows every declared group as [_FilterGroupChips]
  /// *alongside* the query field. Unlike the Tag picker, Search's own
  /// free text and its filters combine (`search(query, filters)`), so
  /// there's no opt-out toggle to build here.
  final List<FilterGroup>? searchFilterGroups;
  final bool loadingSearchFilters;
  final FilterSelection searchFilterSelection;
  final VoidCallback? onSearchFilterSelectionChanged;

  bool get _needsRef =>
      stage == ProbeStage.details ||
      stage == ProbeStage.chapters ||
      stage == ProbeStage.pages;
  bool get _needsQuery => stage == ProbeStage.search || stage == ProbeStage.tag;
  bool get _needsPage =>
      stage == ProbeStage.popular ||
      stage == ProbeStage.search ||
      stage == ProbeStage.tag;
  bool get _hasTagOptions =>
      stage == ProbeStage.tag && (tagFilterGroups?.isNotEmpty ?? false);
  bool get _tagPickerActive => _hasTagOptions && !tagFreeForm;
  bool get _hasSearchFilters =>
      stage == ProbeStage.search && (searchFilterGroups?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasInput = _needsRef || _needsQuery;
    final showPicker = _tagPickerActive;
    final showFreeText = hasInput && !showPicker;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: theme.dividerColor),
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.bolt, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text('Run', style: theme.textTheme.labelMedium),
              const SizedBox(width: 8),
              // A bordered box so the dropdown reads as a control, not a heading.
              Container(
                padding: const EdgeInsets.only(left: 12, right: 4),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<ProbeStage>(
                    value: stage,
                    isDense: true,
                    borderRadius: BorderRadius.circular(8),
                    onChanged: (s) => s == null ? null : onStageChanged(s),
                    items: [
                      for (final s in ProbeStage.values)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Contextual input, kept adjacent to the dropdown (no orphaning gap).
              if (showFreeText)
                Expanded(
                  child: TextField(
                    controller: stageInput,
                    onSubmitted: (_) => (enabled && !running) ? onRun() : null,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: scheme.surface,
                      border: const OutlineInputBorder(),
                      hintText: stage.inputHint,
                      prefixIcon: Icon(
                        stage == ProbeStage.tag
                            ? Icons.sell_outlined
                            : _needsQuery
                            ? Icons.search
                            : Icons.link,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              if (showPicker)
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        Icons.sell_outlined,
                        size: 16,
                        color: scheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tagSelection.isEmpty
                              ? 'Tap tags below — from this source\'s own filters, not free text'
                              : '${tagSelection.allIncluded.length} included'
                                    '${tagSelection.allExcluded.isEmpty ? '' : ', ${tagSelection.allExcluded.length} excluded'}',
                          style: theme.textTheme.bodySmall!.copyWith(
                            color: scheme.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              if ((stage == ProbeStage.tag && loadingTagFilters) ||
                  (stage == ProbeStage.search && loadingSearchFilters)) ...[
                const SizedBox(width: 8),
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (_hasTagOptions) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message:
                      'Bypass the known-tag picker and type any value — '
                      'e.g. to try an undocumented tag the source doesn\'t '
                      'list in its own filters.',
                  child: InkWell(
                    onTap: () => onTagFreeFormChanged?.call(!tagFreeForm),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: tagFreeForm,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) =>
                                onTagFreeFormChanged?.call(v ?? false),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            'Raw',
                            style: theme.textTheme.bodySmall!.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (_needsPage) ...[
                if (hasInput) const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: pageInput,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: scheme.surface,
                      border: const OutlineInputBorder(),
                      labelText: 'page',
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: (!enabled || running) ? null : onRun,
                icon: running
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 18),
                label: Text(
                  stage == ProbeStage.full ? 'Run chain' : 'Run stage',
                ),
              ),
              // When the stage takes no wide input, keep the cluster
              // left-aligned and use the space for a hint rather than a void.
              if (!hasInput) ...[
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    stage == ProbeStage.full
                        ? 'Runs popular → details → chapters → pages against the live site.'
                        : 'Runs just this stage against the live site.',
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: scheme.outline,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          if (showPicker) ...[
            const SizedBox(height: 8),
            _FilterGroupChips(
              groups: tagFilterGroups!,
              selection: tagSelection,
              onChanged: onTagSelectionChanged,
            ),
          ],
          if (_hasSearchFilters) ...[
            const SizedBox(height: 8),
            _FilterGroupChips(
              groups: searchFilterGroups!,
              selection: searchFilterSelection,
              onChanged: onSearchFilterSelectionChanged,
            ),
          ],
        ],
      ),
    );
  }
}

/// Tri-state (off → included → excluded, skipping excluded when the group
/// doesn't support it) chip picker for one or more [FilterGroup]s: the
/// Tag stage's substitute for free-typing exact tag spellings when the
/// source's own `filters` already enumerate them (see `tagRelevantFilters`),
/// and the Search stage's picker for every declared group (type, status,
/// tags, …), shown alongside its free-text query rather than replacing it.
/// Colors mirror the app's own filter sheet convention: green = included,
/// red = excluded.
class _FilterGroupChips extends StatelessWidget {
  const _FilterGroupChips({
    required this.groups,
    required this.selection,
    this.onChanged,
  });

  final List<FilterGroup> groups;
  final FilterSelection selection;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in groups) ...[
          Text(group.name, style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in group.options)
                _FilterChip(
                  label: option.label,
                  state: selection.stateOf(group.id, option.id),
                  onTap: () {
                    selection.cycle(group, option.id);
                    onChanged?.call();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.state,
    required this.onTap,
  });

  final String label;
  final FilterState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground, icon) = switch (state) {
      FilterState.off => (
        theme.colorScheme.surface,
        theme.colorScheme.onSurfaceVariant,
        null,
      ),
      FilterState.included => (
        Colors.green.shade700,
        Colors.white,
        Icons.check,
      ),
      FilterState.excluded => (Colors.red.shade700, Colors.white, Icons.close),
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
          border: state == FilterState.off
              ? Border.all(color: theme.colorScheme.outlineVariant)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: foreground),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: theme.textTheme.bodySmall!.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tier / pkg / catalog status / notes, above the editor+results split.
/// Notes (the catalog's free-form prose, sometimes a long paragraph) are
/// collapsed behind a toggle chip by default so a long writeup doesn't push
/// the editor/results below the fold; expand on demand, capped and
/// scrollable so even a very long note can't blow out the layout further.
class _HeaderStrip extends StatefulWidget {
  const _HeaderStrip({required this.row});

  final SourceRow row;

  @override
  State<_HeaderStrip> createState() => _HeaderStripState();
}

class _HeaderStripState extends State<_HeaderStrip> {
  bool _notesExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = widget.row.catalog;
    final hasNotes = catalog != null && catalog.notes.isNotEmpty;
    Widget chip(String text) => Chip(
      label: Text(text),
      labelStyle: theme.textTheme.bodySmall,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              chip(widget.row.tier.name),
              if (widget.row.pkg.isNotEmpty)
                chip('${widget.row.pkg} @ ${widget.row.version}'),
              chip(widget.row.engine),
              if (widget.row.nsfw) chip('18+'),
              if (widget.row.webview) chip('webview'),
              if (widget.row.rateLimitLabel.isNotEmpty)
                chip(widget.row.rateLimitLabel),
              if (catalog != null && catalog.status.isNotEmpty)
                chip(catalog.status),
              if (hasNotes)
                ActionChip(
                  avatar: Icon(
                    _notesExpanded ? Icons.expand_less : Icons.notes_outlined,
                    size: 16,
                  ),
                  label: const Text('Notes'),
                  labelStyle: theme.textTheme.bodySmall,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onPressed: () =>
                      setState(() => _notesExpanded = !_notesExpanded),
                ),
            ],
          ),
          if (hasNotes && _notesExpanded)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: InlineMarkdown(
                    catalog.notes,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Persisted probe history + the latest run's captured request/response
/// examples for one source, read from the SQLite store.
class _HistoryDialog extends StatelessWidget {
  const _HistoryDialog({required this.sourceId});

  final String sourceId;

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = probeStore!;
    final runs = store.history(sourceId, limit: 30);
    final examples = store.examplesFor(sourceId);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$sourceId · history',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Recent probes (${runs.length})',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 6),
                  if (runs.isEmpty)
                    Text(
                      'No runs recorded yet.',
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    )
                  else
                    for (final r in runs) _runTile(theme, r),
                  const SizedBox(height: 18),
                  Text(
                    'Captured examples · latest run (${examples.length})',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 6),
                  if (examples.isEmpty)
                    Text(
                      'None captured.',
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    )
                  else
                    for (final e in examples) _exampleTile(context, theme, e),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _runTile(ThemeData theme, ProbeRun r) {
    final ok = r.passed;
    final color = ok ? Colors.green : theme.colorScheme.error;
    final status = ok
        ? 'pass'
        : (r.failedStage != null ? 'fail@${r.failedStage}' : 'error');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, size: 14, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(r.op, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              status,
              style: theme.textTheme.bodySmall!.copyWith(color: color),
            ),
          ),
          if (r.elapsedMs != null)
            Text(
              '${r.elapsedMs}ms',
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          const SizedBox(width: 10),
          Text(
            _ago(r.ranAt),
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _exampleTile(BuildContext context, ThemeData theme, ProbeExample e) {
    return InkWell(
      onTap: e.body.isEmpty
          ? null
          : () => showRawDataDialog(
              context,
              title: 'Step ${e.stepIndex} · response',
              text: e.body,
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                e.method,
                style: kMono.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.requestUrl ?? '(reuses prior body)',
                    style: kMono.copyWith(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (e.captured.isNotEmpty)
                    Text(
                      e.captured.entries
                          .map((c) => '${c.key}=${c.value}')
                          .join('  '),
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (e.body.isNotEmpty)
              Text(
                '${(e.body.length / 1024).toStringAsFixed(1)}KB',
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
