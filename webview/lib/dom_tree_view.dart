/// The DOM-tree ("Elements panel") sidebar for the point-and-click picker:
/// an expand/collapse tree over a parsed [dom.Document]'s already-fetched,
/// static HTML — the same `engineDoc` the picker cross-checks WebView
/// clicks against — so a click on a tree row is a *direct pick*, not just a
/// navigation aid, and works even when the live WebView render disagrees
/// with what the engine actually sees (the JS-hydration divergence problem
/// this sidebar exists to make legible).
library;

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;

/// One flattened, currently-visible row: [element] at [depth]. Only
/// elements currently expanded (or their ancestors) appear in the flattened
/// list at all — collapsed subtrees are never walked, so this stays cheap
/// even for a document with thousands of elements.
class _TreeRow {
  const _TreeRow(this.element, this.depth);
  final dom.Element element;
  final int depth;
}

/// Renders [root]'s subtree (usually `engineDoc.documentElement` or
/// `engineDoc.body`). Tapping a row's label reports that element via
/// [onTap] — the chevron only expands/collapses, never picks, so browsing
/// deep into the tree doesn't risk an accidental pick along the way.
/// [highlightedGroup] tints every element in it (the tree's counterpart to
/// the WebView's dashed-border group highlight, e.g. every matched sibling
/// once an item candidate is confirmed); [selected] tints the exact element
/// the last pick came from, distinctly.
class DomTreePanel extends StatefulWidget {
  const DomTreePanel({
    super.key,
    required this.root,
    required this.onTap,
    this.highlightedGroup,
    this.selected,
  });

  final dom.Element root;
  final ValueChanged<dom.Element> onTap;
  final Set<dom.Element>? highlightedGroup;
  final dom.Element? selected;

  @override
  State<DomTreePanel> createState() => _DomTreePanelState();
}

class _DomTreePanelState extends State<DomTreePanel> {
  /// Elements whose children are currently shown. Identity-keyed (`dom`'s
  /// `Node`/`Element` don't override `==`/`hashCode`, confirmed via source)
  /// — exactly what's wanted here, since two structurally-identical
  /// elements at different tree positions are different nodes.
  final Set<dom.Element> _expanded = {};

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _expandShallow(widget.root, 0);
    _revealSelected();
  }

  @override
  void didUpdateWidget(covariant DomTreePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.selected, oldWidget.selected)) {
      _revealSelected();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Expands every ancestor of `widget.selected` so its row actually exists
  /// in the flattened list (only expanded subtrees are walked at all — see
  /// [_flatten]) and scrolls it into view once the resulting frame has laid
  /// out. Without this, a live-page click landing on a deeply-nested
  /// element (routine on a real page) would tint a tree row that's never
  /// rendered at all — the default two-level auto-expand rarely reaches it.
  /// Field mutations here need no `setState`: both call sites
  /// ([initState]/[didUpdateWidget]) are already followed by a build this
  /// same cycle.
  void _revealSelected() {
    final el = widget.selected;
    if (el == null) return;
    var n = el.parent;
    while (n != null) {
      _expanded.add(n);
      if (identical(n, widget.root)) break;
      n = n.parent;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final index = _flatten().indexWhere((r) => identical(r.element, el));
      if (index == -1) return;
      final target = (index * 20.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// A document can run to thousands of elements; expanding everything by
  /// default would both be slow to flatten and impossible to usefully
  /// scan. Two levels is enough to see real structure (the listing
  /// container, then its item cards) without drowning in it — deeper is a
  /// deliberate, one-tap choice from there.
  void _expandShallow(dom.Element el, int depth) {
    if (depth >= 2 || el.children.isEmpty) return;
    _expanded.add(el);
    for (final child in el.children) {
      _expandShallow(child, depth + 1);
    }
  }

  List<_TreeRow> _flatten() {
    final rows = <_TreeRow>[];
    void walk(dom.Element el, int depth) {
      rows.add(_TreeRow(el, depth));
      if (_expanded.contains(el)) {
        for (final child in el.children) {
          walk(child, depth + 1);
        }
      }
    }

    walk(widget.root, 0);
    return rows;
  }

  void _toggle(dom.Element el) {
    setState(() {
      if (!_expanded.remove(el)) _expanded.add(el);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _flatten();
    return ListView.builder(
      controller: _scrollController,
      itemCount: rows.length,
      itemExtent: 20,
      itemBuilder: (context, i) => _row(theme, rows[i]),
    );
  }

  Widget _row(ThemeData theme, _TreeRow row) {
    final el = row.element;
    final hasChildren = el.children.isNotEmpty;
    final isSelected = identical(widget.selected, el);
    final isHighlighted = widget.highlightedGroup?.contains(el) ?? false;
    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer
          : isHighlighted
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onTap(el),
        child: Row(
          children: [
            SizedBox(width: row.depth * 14.0),
            SizedBox(
              width: 18,
              height: 18,
              child: hasChildren
                  ? InkResponse(
                      onTap: () => _toggle(el),
                      radius: 12,
                      child: Icon(
                        _expanded.contains(el)
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 16,
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: Text.rich(
                _nodeSpan(el, theme),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextSpan _nodeSpan(dom.Element el, ThemeData theme) {
    final tag = el.localName ?? '?';
    final id = el.attributes['id'];
    final classes = (el.attributes['class'] ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((c) => c.isNotEmpty)
        .toList();
    final baseStyle = theme.textTheme.bodySmall!.copyWith(
      fontFamily: 'monospace',
      fontSize: 11.5,
    );
    return TextSpan(
      style: baseStyle,
      children: [
        TextSpan(
          text: '<$tag',
          style: TextStyle(color: theme.colorScheme.tertiary),
        ),
        if (id != null && id.isNotEmpty)
          TextSpan(
            text: '#$id',
            style: TextStyle(color: theme.colorScheme.secondary),
          ),
        for (final c in classes)
          TextSpan(
            text: '.$c',
            style: TextStyle(color: theme.colorScheme.primary),
          ),
        const TextSpan(text: '>'),
      ],
    );
  }
}
