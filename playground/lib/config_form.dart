// A structured, visual editor for a source config: the alternative to the raw
// JSON view. It edits the *source object* inside whatever wrapper was loaded (a
// bare source, an extension file's `sources[0]`, or an index entry) and emits
// regenerated JSON, so probing/saving stay identical. Schema-agnostic: known
// scalar/selector keys get typed widgets and friendly labels, operations become
// collapsible sections, and anything it doesn't recognize (cover chains, row
// maps) is preserved through a compact JSON sub-field; nothing is dropped.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'json_view.dart';

/// Operation sub-maps, shown as collapsible sections in display order. Map-
/// shaped fields only: `filters` (a List) isn't one of these; it falls
/// through to `_sourceCard`'s generic per-key fallback instead.
const operationKeys = [
  'popular',
  'latest',
  'search',
  'details',
  'chapters',
  'pages',
  'manga',
];

/// Top-level scalar fields, in display order, with friendly labels.
const _scalarFields = <(String, String)>[
  ('name', 'Name'),
  ('id', 'ID'),
  ('lang', 'Language'),
  ('baseUrl', 'Base URL'),
  ('apiUrl', 'API URL'),
];

/// Every top-level source field `_sourceCard` renders with a fixed widget
/// (present in the JSON or not: an absent optional bool still needs its own
/// switch shown, since there's nothing to iterate), excluded from the
/// generic per-key fallback so nothing renders twice. `icon` is deliberately
/// in this set without a widget of its own: it's a captured
/// `data:…;base64,…` blob, not worth a raw-text field, so it's just hidden.
///
/// `config_form_test.dart` checks this set against
/// `docs/source-config.schema.json`'s top-level `properties`: the guard
/// against exactly the drift that left `warmImageByUrl` unreachable in the
/// form after it was added to the engine (`SourceConfig`) but not here.
const sourceCardKnownFields = {
  'name',
  'id',
  'lang',
  'baseUrl',
  'apiUrl',
  'webview',
  'warmImageByUrl',
  'warmImageViaImgTag',
  'js',
  'icon',
};

/// Nicer labels for a few common op keys; anything not here falls back to the
/// raw key.
const _fieldLabels = <String, String>{
  'path': 'Path',
  'itemSelector': 'Item selector',
  'titleSelector': 'Title selector',
  'titleAttr': 'Title attr',
  'urlSelector': 'URL selector',
  'urlAttr': 'URL attr',
  'coverSelector': 'Cover selector',
  'coverAttr': 'Cover attr',
  'nextPageSelector': 'Next-page selector',
  'descriptionSelector': 'Description selector',
  'authorSelector': 'Author selector',
  'nameSelector': 'Name selector',
  'nameAttr': 'Name attr',
  'dateSelector': 'Date selector',
  'imageSelector': 'Image selector',
  'imageAttr': 'Image attr',
};

/// The one field whose presence signals "this block will actually try to
/// extract something" for each operation — used only to badge Form-view
/// progress (see [_opStatusDisplay]), not to validate: a block with just
/// this field can still run; one with everything but it can't. An op not
/// in this map (e.g. `manga`, a raw passthrough) falls back to "any field
/// set" for its status.
const _opKeyField = <String, String>{
  'popular': 'itemSelector',
  'latest': 'itemSelector',
  'search': 'itemSelector',
  'chapters': 'itemSelector',
  'pages': 'imageSelector',
  'details': 'titleSelector',
};

/// The operation keys the point-and-click picker covers — see
/// [ConfigForm.onPickRequested]. `search`/`latest` reuse `popular`'s exact
/// shape but aren't wired to a picker trigger yet (no seed-URL story for
/// a search query); `manga`/`tag` aren't either.
const _pickableOps = {'popular', 'chapters', 'pages', 'details'};

/// A brand-new source's `popular`/`chapters`/`pages` blocks all start
/// present-but-empty (`{}` — the engine requires the keys to exist at all
/// for `SourceConfig.fromJson` to succeed, even though every field within
/// them defaults), which read identically to "fully configured, just
/// happens to use every default" without this: an icon + label per block
/// distinguishing not-started (no fields at all) from in-progress (some
/// fields, but not the one that actually makes it do anything) from
/// configured (has that key field), so progress across several blocks is
/// legible at a glance instead of requiring a read of every field.
(IconData, Color, String) _opStatusDisplay(
  ThemeData theme,
  String opKey,
  Map<String, dynamic> op,
) {
  if (op.isEmpty) {
    return (
      Icons.circle_outlined,
      theme.colorScheme.outlineVariant,
      'Not started',
    );
  }
  final keyField = _opKeyField[opKey];
  final hasKeyField =
      keyField == null || '${op[keyField] ?? ''}'.trim().isNotEmpty;
  final count = '${op.length} field${op.length == 1 ? '' : 's'} set';
  return hasKeyField
      ? (Icons.check_circle_outline, Colors.green, count)
      : (Icons.edit_outlined, Colors.orange, '$count — in progress');
}

class ConfigForm extends StatefulWidget {
  const ConfigForm({
    super.key,
    required this.text,
    required this.onChanged,
    this.testHtml,
    this.onPickRequested,
  });

  /// Current config JSON.
  final String text;

  /// Emits regenerated (pretty) JSON on every edit.
  final ValueChanged<String> onChanged;

  /// The HTML body from the last probe/stage run, if any. When present, each
  /// selector field shows a live match count + first-match preview against it
  /// (parsed with the same package:html the engine uses), a check VS Code
  /// can't do because it needs the live fetched DOM.
  final String? testHtml;

  /// Point-and-click picker trigger for one operation key
  /// (`'popular'`/`'chapters'`/`'pages'`/`'details'`) — shown as a small
  /// icon next to that block's status badge when non-null. Null hides the
  /// icon for every block (the caller has no picker available at all: wrong
  /// platform, or an API-dialect config with no DOM to click on).
  final void Function(String opKey)? onPickRequested;

  @override
  State<ConfigForm> createState() => _ConfigFormState();
}

/// Locates the *source object* inside whatever wrapper [root] is (a bare
/// source, an extension file's `sources[0]`, or an index entry) — the
/// unwrapping convention this form edits under, also needed by
/// `detail_screen.dart`'s point-and-click picker, which mutates the same
/// underlying JSON directly rather than through a live form instance (so it
/// works the same whether the user is currently looking at the Form or the
/// raw JSON tab). Returns null if [root] isn't shaped like a source at all.
Map<String, dynamic>? extractSource(Object? root) {
  final entry = root is List ? root.first : root;
  final source = (entry is Map && entry.containsKey('sources'))
      ? (entry['sources'] as List).first
      : entry;
  return source is Map ? source.cast<String, dynamic>() : null;
}

class _ConfigFormState extends State<ConfigForm> {
  Object? _root;
  Map<String, dynamic>? _source;
  String? _parseError;
  String _lastEmitted = '';

  // Parsed test document (from widget.testHtml), memoized on the source string.
  dom.Document? _testDoc;
  String? _testDocSource;

  final _controllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _parse(widget.text);
    _parseTestDoc();
  }

  @override
  void didUpdateWidget(ConfigForm old) {
    super.didUpdateWidget(old);
    // Re-parse only on an *external* text change (JSON-mode edit, file load),
    // not our own emits, which would stomp the field being typed in.
    if (widget.text != old.text && widget.text != _lastEmitted) {
      _disposeControllers();
      _parse(widget.text);
    }
    if (widget.testHtml != old.testHtml) _parseTestDoc();
  }

  void _parseTestDoc() {
    if (widget.testHtml == _testDocSource) return;
    _testDocSource = widget.testHtml;
    final html = widget.testHtml;
    _testDoc = (html == null || html.isEmpty) ? null : html_parser.parse(html);
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _disposeControllers() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }

  void _parse(String text) {
    try {
      final root = jsonDecode(text);
      final source = extractSource(root);
      if (source == null) throw const FormatException('not a source config');
      _root = root;
      _source = source;
      _parseError = null;
    } catch (e) {
      _root = null;
      _source = null;
      _parseError = '$e';
    }
  }

  void _emit() {
    if (_root == null) return;
    final text = '${const JsonEncoder.withIndent('  ').convert(_root)}\n';
    _lastEmitted = text;
    widget.onChanged(text);
  }

  TextEditingController _controllerFor(String path, String value) {
    final existing = _controllers[path];
    if (existing != null) return existing;
    return _controllers[path] = TextEditingController(text: value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_parseError != null || _source == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Can\'t show the form — the JSON doesn\'t parse:\n$_parseError\n\n'
            'Fix it in the JSON tab.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      );
    }

    final source = _source!;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _sourceCard(theme, source),
        if (source['rateLimit'] is Map) _rateLimitCard(theme, source),
        for (final key in operationKeys)
          if (source[key] is Map)
            _operationSection(theme, key, (source[key] as Map).cast()),
      ],
    );
  }

  Widget _sourceCard(ThemeData theme, Map<String, dynamic> source) {
    final elsewhere = {...operationKeys, 'rateLimit'};
    final remaining = [
      for (final k in source.keys)
        if (!elsewhere.contains(k) && !sourceCardKnownFields.contains(k)) k,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Source', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final (key, label) in _scalarFields)
              if (source.containsKey(key) || key == 'name' || key == 'id')
                _textField(
                  path: 'src.$key',
                  label: label,
                  value: '${source[key] ?? ''}',
                  onChanged: (v) {
                    source[key] = v;
                    _emit();
                  },
                ),
            _sourceSwitch(
              source,
              'webview',
              'WebView (route requests through WKWebView)',
            ),
            _sourceSwitch(
              source,
              'warmImageByUrl',
              'Warm image by URL (webview: image path, not bare origin)',
            ),
            _sourceSwitch(
              source,
              'warmImageViaImgTag',
              'Warm image via <img> tag (webview: crossorigin img + canvas '
                  'from baseUrl, tried first — falls back to warmImageByUrl '
                  'on failure when both are set)',
            ),
            _sourceSwitch(source, 'js', 'JS steps (sandboxed QuickJS)'),
            // Anything else present in the JSON but not one of the fixed
            // fields above or an operation/rateLimit section: same
            // scalar/complex dispatch _opField/_jsonSubField already give
            // every operation, so a new top-level field (e.g. `headers`)
            // shows up here automatically instead of being silently dropped.
            for (final k in remaining)
              if (source[k] is Map || source[k] is List)
                _jsonSubField(theme, 'src', source, k)
              else
                _opField('src', source, k),
          ],
        ),
      ),
    );
  }

  /// A bool switch for a top-level source field that's *omitted* from the
  /// JSON at its default (false). Unlike `_opField`'s bool branch, which
  /// only runs for a key already present, this one has to work from absence.
  Widget _sourceSwitch(Map<String, dynamic> source, String key, String label) {
    /* `webview` is a bool *or* a list of operation names. A list is on, and
     * stays a list: reading it as `== true` would show a narrowed config as
     * off, and writing `true` over it would widen it back to every request —
     * silently undoing the narrowing just by opening the form. */
    final value = source[key];
    final narrowed = value is List && value.isNotEmpty;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(narrowed ? '$label — ${value.join(', ')}' : label),
      value: value == true || narrowed,
      onChanged: (v) {
        if (!v) {
          source.remove(key);
        } else if (!narrowed) {
          source[key] = true;
        }
        _emit();
        setState(() {});
      },
    );
  }

  Widget _rateLimitCard(ThemeData theme, Map<String, dynamic> source) {
    final rl = (source['rateLimit'] as Map).cast<String, dynamic>();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rate limit', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _numberField(
                    path: 'rl.requests',
                    label: 'Requests',
                    value: '${rl['requests'] ?? ''}',
                    onChanged: (n) {
                      rl['requests'] = n;
                      _emit();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _numberField(
                    path: 'rl.perMs',
                    label: 'per ms',
                    value: '${rl['perMs'] ?? ''}',
                    onChanged: (n) {
                      rl['perMs'] = n;
                      _emit();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _operationSection(
    ThemeData theme,
    String opKey,
    Map<String, dynamic> op,
  ) {
    // String/scalar fields first (the selectors), complex ones after.
    final scalar = <String>[];
    final complex = <String>[];
    for (final k in op.keys) {
      (op[k] is Map || op[k] is List ? complex : scalar).add(k);
    }
    final (statusIcon, statusColor, statusLabel) = _opStatusDisplay(
      theme,
      opKey,
      op,
    );
    final onPickRequested = widget.onPickRequested;
    final canPick = onPickRequested != null && _pickableOps.contains(opKey);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: Text(opKey, style: theme.textTheme.titleSmall),
        subtitle: Row(
          children: [
            Icon(statusIcon, size: 13, color: statusColor),
            const SizedBox(width: 4),
            Text(
              statusLabel,
              style: theme.textTheme.bodySmall!.copyWith(color: statusColor),
            ),
            if (canPick) ...[
              const SizedBox(width: 6),
              InkWell(
                onTap: () => onPickRequested(opKey),
                child: Tooltip(
                  message: 'Pick $opKey selectors by clicking a live page',
                  child: Icon(
                    Icons.ads_click_outlined,
                    size: 14,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ],
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        children: [
          for (final k in scalar) _opField(opKey, op, k),
          for (final k in complex) _jsonSubField(theme, opKey, op, k),
        ],
      ),
    );
  }

  /// One scalar field: bool → switch, num → number field, else text. Used
  /// both for an operation's own fields ([pathPrefix] = the op key) and,
  /// generically, for any top-level source field the fixed source-card
  /// widgets above don't already cover ([pathPrefix] = `'src'`).
  Widget _opField(
    String pathPrefix,
    Map<String, dynamic> container,
    String key,
  ) {
    final value = container[key];
    final label = _fieldLabels[key] ?? key;
    if (value is bool) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label),
        value: value,
        onChanged: (v) {
          container[key] = v;
          _emit();
          setState(() {});
        },
      );
    }
    if (value is num) {
      return _numberField(
        path: '$pathPrefix.$key',
        label: label,
        value: '$value',
        onChanged: (n) {
          container[key] = n;
          _emit();
        },
      );
    }
    final isSelector = key.toLowerCase().contains('selector');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _textField(
          path: '$pathPrefix.$key',
          label: label,
          value: '${value ?? ''}',
          mono: isSelector || key == 'path',
          onChanged: (v) {
            container[key] = v;
            _emit();
            if (isSelector) setState(() {}); // refresh the match indicator
          },
        ),
        if (isSelector && _testDoc != null)
          _SelectorMatch(
            doc: _testDoc!,
            op: container,
            selectorKey: key,
            selector: '${container[key] ?? ''}',
          ),
      ],
    );
  }

  /// A complex (List/Map) field, preserved through a compact JSON editor;
  /// same [pathPrefix] generality as [_opField].
  Widget _jsonSubField(
    ThemeData theme,
    String pathPrefix,
    Map<String, dynamic> container,
    String key,
  ) {
    final path = '$pathPrefix.$key.json';
    final controller = _controllerFor(
      path,
      const JsonEncoder.withIndent('  ').convert(container[key]),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _fieldLabels[key] ?? key,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            maxLines: null,
            style: kMono.copyWith(fontSize: 11.5),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(8),
            ),
            onChanged: (raw) {
              try {
                container[key] = jsonDecode(raw);
                _emit();
              } catch (_) {
                // Hold the invalid text; don't emit until it parses again.
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _textField({
    required String path,
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
    bool mono = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: _controllerFor(path, value),
        style: mono ? kMono.copyWith(fontSize: 12.5) : null,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _numberField({
    required String path,
    required String label,
    required String value,
    required ValueChanged<num> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: _controllerFor(path, value),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: (raw) {
          final n = num.tryParse(raw);
          if (n != null) onChanged(n);
        },
      ),
    );
  }
}

/// Live result of running one selector against the last-probed document:
/// match count and a preview of what the first match extracts. Item-relative
/// selectors (title/url/cover/name/date in an op that has an `itemSelector`)
/// are scoped to the first item, matching how the engine extracts per-item.
class _SelectorMatch extends StatelessWidget {
  const _SelectorMatch({
    required this.doc,
    required this.op,
    required this.selectorKey,
    required this.selector,
  });

  final dom.Document doc;
  final Map<String, dynamic> op;
  final String selectorKey;
  final String selector;

  bool get _isItemRelative {
    final itemSel = op['itemSelector'];
    return selectorKey != 'itemSelector' &&
        itemSel is String &&
        itemSel.trim().isNotEmpty;
  }

  String? _attrValue(dom.Element el) {
    // If this selector pairs with an *Attr key, preview that attribute's value.
    final attrKey = selectorKey.replaceAll('Selector', 'Attr');
    final attr = (attrKey != selectorKey && op[attrKey] is String)
        ? op[attrKey] as String
        : '';
    return attr.isNotEmpty
        ? (el.attributes[attr] ?? '')
        : el.text.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Whole-document evaluation, for `itemSelector` itself and any selector
  /// in an operation with no `itemSelector` (e.g. `details`, `pages`).
  ({int count, int? totalItems, String preview}) _evaluateGlobal() {
    final root = doc.documentElement;
    if (root == null) return (count: 0, totalItems: null, preview: '');
    final matches = root.querySelectorAll(selector);
    if (matches.isEmpty) return (count: 0, totalItems: null, preview: '');
    return (
      count: matches.length,
      totalItems: null,
      preview: _attrValue(matches.first) ?? '',
    );
  }

  /// Item-relative evaluation: tests [selector] against **every** item
  /// element `itemSelector` finds, not just the first, since a selector
  /// that only matches some cards (a lazy-loaded cover, an occasional
  /// "official" badge) is exactly the kind of partial failure a single-item
  /// preview would hide.
  ({int count, int? totalItems, String preview}) _evaluateItemRelative() {
    final itemSel = op['itemSelector'] as String;
    final items = doc.querySelectorAll(itemSel);
    if (items.isEmpty) return (count: 0, totalItems: 0, preview: '');
    var hits = 0;
    var preview = '';
    for (final item in items) {
      final matches = item.querySelectorAll(selector);
      if (matches.isEmpty) continue;
      hits++;
      if (preview.isEmpty) preview = _attrValue(matches.first) ?? '';
    }
    return (count: hits, totalItems: items.length, preview: preview);
  }

  ({int count, int? totalItems, String preview}) _evaluate() {
    if (selector.trim().isEmpty) {
      return (count: 0, totalItems: null, preview: '');
    }
    return _isItemRelative ? _evaluateItemRelative() : _evaluateGlobal();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (selector.trim().isEmpty) return const SizedBox.shrink();

    int count;
    int? totalItems;
    String preview;
    String? error;
    try {
      final r = _evaluate();
      count = r.count;
      totalItems = r.totalItems;
      preview = r.preview;
    } catch (_) {
      // package:html throws on selectors it can't parse: the same failure the
      // engine would hit, surfaced here as feedback.
      count = 0;
      totalItems = null;
      preview = '';
      error = 'unsupported selector';
    }

    final previewSuffix =
        ' · ${preview.length > 60 ? '${preview.substring(0, 60)}…' : preview}';
    final (color, icon, text) = switch ((error, count, totalItems)) {
      (final e?, _, _) => (theme.colorScheme.error, Icons.error_outline, e),
      (_, 0, final total?) when total > 0 => (
        theme.colorScheme.error,
        Icons.close,
        '0/$total items matched in last probe',
      ),
      (_, 0, _) => (
        theme.colorScheme.error,
        Icons.close,
        'no match in last probe',
      ),
      (_, final n, final total?) when total > 0 => (
        n == total ? Colors.green : Colors.orange,
        n == total ? Icons.check : Icons.warning_amber_outlined,
        '$n/$total items matched${preview.isEmpty ? '' : previewSuffix}',
      ),
      (_, final n, _) => (
        Colors.green,
        Icons.check,
        '$n match${n == 1 ? '' : 'es'}${preview.isEmpty ? '' : previewSuffix}',
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 6, top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall!.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
