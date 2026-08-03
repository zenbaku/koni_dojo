/// Pure-Dart port of the picker's selector-generation algorithm (the JS
/// version lives embedded in `_pickerScript` in `koni_dojo_webview.dart`,
/// between the `picker-algo:start`/`:end` markers), operating on
/// `package:html`'s already-parsed [dom.Element]/[dom.Document] instead of a
/// live browser DOM — what the DOM-tree sidebar's "direct pick" needs, since
/// it browses the same static `_engineDoc` the picker already cross-checks
/// WebView clicks against, not the live render.
///
/// Deliberately a hand port, not a shared/generated source (a dart2js
/// compile-and-share approach was investigated and rejected earlier — see
/// the playground-app project memory): the two are kept honest against each
/// other by shared *fixture* tests (`test/dom_tree_algo_test.dart` runs the
/// same fixture HTML `test/picker_algo/picker-algo.test.js` already uses for
/// the JS side), not shared code. Every function here mirrors its JS
/// counterpart function-for-function; keep them in sync by hand if either
/// changes.
library;

import 'package:html/dom.dart' as dom;

/// A found repeating-group candidate — [dom_tree_algo]'s counterpart to the
/// JS algorithm's item-phase return object.
class DomItemCandidate {
  const DomItemCandidate({
    required this.selector,
    required this.tag,
    required this.sharedClasses,
    required this.groupSize,
    required this.globalMatchCount,
    required this.level,
  });

  final String selector;
  final String tag;
  final List<String> sharedClasses;
  final int groupSize;
  final int globalMatchCount;
  final int level;
}

/// A field selector relative to a confirmed set of item roots (or a single
/// synthetic root, for a single-element pick) — [dom_tree_algo]'s
/// counterpart to the JS algorithm's relative-phase return object.
class DomRelativeCandidate {
  const DomRelativeCandidate({
    required this.selector,
    required this.tag,
    required this.matchCount,
    required this.totalItems,
    required this.preview,
  });

  final String selector;
  final String tag;
  final int matchCount;
  final int totalItems;
  final String preview;
}

/// Every class on [el], excluding the picker's own hover/highlight
/// bookkeeping classes — there's no live-DOM mutation against a parsed
/// [dom.Document] the way the WebView script hovers/highlights, so this
/// filter can never actually trigger here, but it's kept for exact parity
/// with the JS `classList()` it mirrors.
List<String> classList(dom.Element el) {
  final raw = el.attributes['class'] ?? '';
  return raw
      .trim()
      .split(RegExp(r'\s+'))
      .where((c) => c.isNotEmpty && !c.startsWith('__koni'))
      .toList();
}

/// The classes every element in [els] shares, sorted.
List<String> sharedClasses(List<dom.Element> els) {
  if (els.isEmpty) return const [];
  final shared = classList(els[0]).toSet();
  for (var i = 1; i < els.length; i++) {
    final cls = classList(els[i]).toSet();
    shared.removeWhere((c) => !cls.contains(c));
  }
  final result = shared.toList()..sort();
  return result;
}

String cssEscape(String s) =>
    s.replaceAllMapped(RegExp(r'[^a-zA-Z0-9_-]'), (m) => '\\${m[0]}');

String tagSelector(String tag, List<String> classes) => classes.isEmpty
    ? tag
    : '$tag${classes.map((c) => '.${cssEscape(c)}').join()}';

/// Candidate scoping prefixes to disambiguate an item selector that matches
/// too broadly on its own (an empty prefix first, then `#id >`, then
/// `tag.class >`) — tried in order until one narrows the match count down
/// to exactly the sibling group size.
List<String> parentScopeCandidates(dom.Element? parent) {
  final candidates = <String>[''];
  if (parent == null || parent.localName == 'body') return candidates;
  final parentId = parent.attributes['id'] ?? '';
  if (parentId.isNotEmpty) candidates.add('#${cssEscape(parentId)} > ');
  final pClasses = classList(parent);
  final tag = parent.localName ?? '';
  if (pClasses.isNotEmpty) {
    candidates.add('$tag.${pClasses.map(cssEscape).join('.')} > ');
  } else {
    candidates.add('$tag > ');
  }
  return candidates;
}

/// Walks up from [clicked] looking for the shallowest ancestor level (at or
/// above [minLevel]) whose parent has more than one same-tag child — the
/// "repeating group" guess. [doc] is used to verify the computed selector's
/// global match count, resolving ambiguity with [parentScopeCandidates] when
/// the bare tag+class selector over-matches. Null when no such group is
/// found within [maxLevels].
///
/// [skipAmbiguousClasses] (on by default — this is what grid pickers
/// Popular/Chapters/Genre use) skips a level whose siblings' own classes
/// are inconsistent (some have one, some don't, or they differ) rather
/// than settling for a classless itemSig there — **load-bearing for
/// grids**: confirmed via the JS jsdom suite that without it, a
/// Madara-style card's own thumbnail-wrapper/title-wrapper children (same
/// tag, no shared class) get mistaken for the repeating group instead of
/// climbing to the real one (the cards themselves). Rows wants the
/// opposite: pass `false` via [domItemCandidateLoose] — confirmed on a
/// live page that a real row list can have one classed outlier row
/// (e.g. a "Track:" row with its own inline-layout class) that would
/// otherwise trip this guard and skip straight past the correct `<li>`
/// level. See [guessRowContainer]'s doc comment for the full story.
DomItemCandidate? domItemCandidate(
  dom.Document doc,
  dom.Element clicked, {
  int minLevel = 0,
  int maxLevels = 6,
  bool skipAmbiguousClasses = true,
}) {
  var node = clicked;
  for (var level = 0; level <= maxLevels; level++) {
    final parent = node.parent;
    if (parent == null) break;
    final sameTag = parent.children
        .where((c) => c.localName == node.localName)
        .toList();
    if (sameTag.length > 1 && level >= minLevel) {
      final shared = sharedClasses(sameTag);
      if (skipAmbiguousClasses) {
        final anyHasClass = sameTag.any((c) => classList(c).isNotEmpty);
        if (shared.isEmpty && anyHasClass) {
          node = parent;
          continue;
        }
      }
      final itemSig = tagSelector(node.localName ?? '', shared);
      var selector = itemSig;
      var matchedGlobally = doc.querySelectorAll(selector).length;
      if (matchedGlobally != sameTag.length) {
        // Prefer the *closest available* scope over giving up and keeping
        // the bare, unscoped selector: every candidate here is `scope +
        // itemSig`, and every sibling in `sameTag` is a direct child of
        // `parent` matching `itemSig` by construction, so scoping via
        // parent's own id/class can only ever ADD matches beyond the
        // original group, never drop any of it (matchedGlobally can't go
        // below sameTag.length). An exact match is still the best
        // possible outcome and wins outright; short of that, the smallest
        // available over-match beats reverting to the unscoped selector,
        // which over-matches at least as much and often far more.
        for (final scope in parentScopeCandidates(parent)) {
          if (scope.isEmpty) continue;
          final candidate = '$scope$itemSig';
          final n = doc.querySelectorAll(candidate).length;
          if (n < matchedGlobally) {
            selector = candidate;
            matchedGlobally = n;
            if (n == sameTag.length) break;
          }
        }
      }
      return DomItemCandidate(
        selector: selector,
        tag: node.localName ?? '',
        sharedClasses: shared,
        groupSize: sameTag.length,
        globalMatchCount: matchedGlobally,
        level: level,
      );
    }
    node = parent;
  }
  return null;
}

/// [domItemCandidate] with `skipAmbiguousClasses: false` — the
/// rows-specific relaxation. A named wrapper (over just passing the flag
/// at each call site) so every rows call site reads the same,
/// self-explanatory way.
DomItemCandidate? domItemCandidateLoose(
  dom.Document doc,
  dom.Element clicked, {
  int minLevel = 0,
  int maxLevels = 6,
}) => domItemCandidate(
  doc,
  clicked,
  minLevel: minLevel,
  maxLevels: maxLevels,
  skipAmbiguousClasses: false,
);

bool _isAncestorOf(dom.Element ancestor, dom.Element node) {
  dom.Element? n = node;
  while (n != null) {
    if (identical(n, ancestor)) return true;
    n = n.parent;
  }
  return false;
}

/// Builds a CSS path from [clickedEl] up to (not including) whichever of
/// [itemRoots] contains it, verifying each candidate ancestor level against
/// every item root until one matches all of them (or falls back to the
/// clicked element's own tag+class signature if none do). [preferAncestorTag]
/// walks up to the nearest ancestor with that tag first (a url-style pick:
/// clicking the title text or cover image inside a link should still select
/// the link). [previewAttr] set means capture that attribute's value;
/// empty means the element's own text. Null when [clickedEl] isn't inside
/// any of [itemRoots] at all.
DomRelativeCandidate? domRelativeCandidate(
  List<dom.Element> itemRoots,
  dom.Element clickedEl, {
  String? preferAncestorTag,
  String previewAttr = '',
}) {
  String previewOf(dom.Element? el) {
    if (el == null) return '';
    if (previewAttr.isNotEmpty) return el.attributes[previewAttr] ?? '';
    return el.text.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  dom.Element? containingRoot;
  for (final root in itemRoots) {
    if (_isAncestorOf(root, clickedEl)) {
      containingRoot = root;
      break;
    }
  }
  if (containingRoot == null) return null;
  final root = containingRoot;

  List<dom.Element> pathFrom(dom.Element el) {
    final path = <dom.Element>[];
    dom.Element? n = el;
    while (n != null && !identical(n, root)) {
      path.add(n);
      n = n.parent;
    }
    return path.reversed.toList();
  }

  // A root's *first* match is what the engine's own querySelector-based
  // extraction will actually use at scrape time — so "the selector works"
  // has to mean "its first match in the containing root IS the element
  // that was clicked", not merely "it matches something". A bare
  // existence check (pre-fix: `r.querySelector(relSelector) != null`)
  // passes trivially for a single-global-root pick (the Details palette's
  // itemRoots is always `[doc.body]`) the instant *any* element anywhere
  // shares the clicked element's tag+class — confirmed on a live page,
  // where a classless cover `<img>` produced the bare selector `'img'`,
  // whose first document-order match is the site's header logo, not the
  // cover; the picker's own preview looked right only because it read the
  // clicked element directly, never re-querying by selector the way a real
  // probe does. Every *other* root (only possible in the multi-card
  // wizard) has no click of its own to compare against — for those,
  // existence is still the right (and only possible) check: it's asking
  // "does this same pattern also resolve to *something* in this sibling
  // card", which is what makes an item-relative selector reusable across a
  // listing in the first place.
  int verify(String relSelector, dom.Element target) {
    var hits = 0;
    for (final r in itemRoots) {
      final match = r.querySelector(relSelector);
      if (match == null) continue;
      if (identical(r, root)) {
        if (identical(match, target)) hits++;
      } else {
        hits++;
      }
    }
    return hits;
  }

  final candidates = <dom.Element>[];
  if (preferAncestorTag != null) {
    dom.Element? n = clickedEl;
    while (n != null && !identical(n, root)) {
      if (n.localName == preferAncestorTag) {
        candidates.add(n);
        break;
      }
      n = n.parent;
    }
  }
  candidates.add(clickedEl);

  for (final target in candidates) {
    final chain = pathFrom(target);
    for (var start = chain.length - 1; start >= 0; start--) {
      final segment = chain.sublist(start);
      final relSelector = segment
          .map((el) => tagSelector(el.localName ?? '', classList(el)))
          .join(' > ');
      final hits = verify(relSelector, target);
      if (hits == itemRoots.length) {
        return DomRelativeCandidate(
          selector: relSelector,
          tag: target.localName ?? '',
          matchCount: hits,
          totalItems: itemRoots.length,
          preview: previewOf(target),
        );
      }
    }
  }
  final fallbackTarget = candidates.last;
  final fallbackSelector = tagSelector(
    fallbackTarget.localName ?? '',
    classList(fallbackTarget),
  );
  return DomRelativeCandidate(
    selector: fallbackSelector,
    tag: fallbackTarget.localName ?? '',
    matchCount: verify(fallbackSelector, fallbackTarget),
    totalItems: itemRoots.length,
    preview: previewOf(fallbackTarget),
  );
}

/// Every element in [rows] whose [labelSelector] match's text contains any
/// of [labels] (case-insensitive) — the exact matching rule `_applyRows`
/// (`lib/src/config_source.dart`) uses at scrape time for the picker's
/// `rows`-authoring mode, mirrored here so a field's value pick is
/// verified against precisely the rows it'll actually apply to at scrape
/// time (never *all* rows — a field's `valueSelector` only needs to work
/// in the rows matching *its own* labels). Unlike the rest of this file,
/// this has no JS mirror to keep in sync by hand: the live-page equivalent
/// is a one-off `evaluateJavascript` snippet (see `_itemRootsJsExpr` in
/// `koni_dojo_webview.dart`), not the shared `picker-algo:start`/`:end`
/// block — rows label matching only ever needs to run against the parsed
/// `engineDoc`, whether for cross-checking a live pick or for the
/// picker's own live preview.
List<dom.Element> rowsMatchingLabels(
  List<dom.Element> rows,
  String labelSelector,
  Set<String> labels,
) {
  if (labels.isEmpty) return const [];
  final lowerLabels = labels.map((l) => l.toLowerCase()).toList();
  return rows.where((row) {
    final text =
        row.querySelector(labelSelector)?.text.trim().toLowerCase() ?? '';
    return text.isNotEmpty && lowerLabels.any(text.contains);
  }).toList();
}

/// [simulateRowsFieldValue]'s result: [rowsWithValue] of [totalRows] rows
/// (from the [rowsMatchingLabels] set passed in) produced at least one
/// non-empty value via [valueSelector]; [texts] is every value found
/// across every row, in row order; [preview] is [texts] joined the same
/// way `_applyRows` joins author/description (ignored for genres, which
/// keeps the raw list, and status, which only ever reads the first).
class RowsFieldSimulation {
  const RowsFieldSimulation({
    required this.rowsWithValue,
    required this.totalRows,
    required this.texts,
    required this.preview,
  });

  final int rowsWithValue;
  final int totalRows;
  final List<String> texts;
  final String preview;
}

/// Runs `_applyRows`'s own per-field extraction logic (`lib/src/
/// config_source.dart`) against [matchingRows] using [valueSelector] —
/// the picker's field-value live-sync gate *and* its human-readable
/// preview. Deliberately **not** identity-based like
/// [domRelativeCandidate]'s own `verify()`: `_applyRows` collects *every*
/// value a selector matches per row (`querySelectorAllExt`, not just the
/// first), so a selector that only matches the *second* element in a row
/// (e.g. the second author name) must still count as a working pick even
/// though it isn't literally the row's first match.
RowsFieldSimulation simulateRowsFieldValue(
  List<dom.Element> matchingRows,
  String valueSelector, {
  String join = ', ',
}) {
  var rowsWithValue = 0;
  final texts = <String>[];
  for (final row in matchingRows) {
    final elements = valueSelector.isEmpty
        ? [row]
        : row.querySelectorAll(valueSelector);
    var foundInThisRow = false;
    for (final el in elements) {
      // A common real-site markup shape wraps each tag/value plus its own
      // list-separator comma in one element (e.g. `<span><a>Action</a>,
      // </span>`) — the separator lives *inside* the wrapper, outside the
      // inner link. Clicking the wrapper instead of the link (confirmed
      // live: the two overlap almost pixel-for-pixel, and a click near a
      // tag's edge lands on the wrapper) is a realistic way to end up
      // with that wrapper as the value selector — its own .text then
      // includes the separator as real, if unwanted, data. Stripping one
      // trailing list-separator char is safe here: a genuine value ending
      // in a comma/semicolon is vanishingly rare, and _applyRows mirrors
      // this exactly so a scrape doesn't inherit the same artifact.
      final text = el.text
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceFirst(RegExp(r'[,;]$'), '');
      if (text.isEmpty) continue;
      foundInThisRow = true;
      texts.add(text);
    }
    if (foundInThisRow) rowsWithValue++;
  }
  return RowsFieldSimulation(
    rowsWithValue: rowsWithValue,
    totalRows: matchingRows.length,
    texts: texts,
    preview: texts.join(join),
  );
}

/// A crude, best-effort guess at a `rows.itemSelector` when escalating from
/// a single flat-field click (e.g. one genre `<span>`) into rows mode:
/// widens from [clicked] via [domItemCandidateLoose] — [domItemCandidate]'s
/// rows-relaxed sibling, which never bails to a bare, unscoped tag *and*
/// never skips a level just because its siblings' own classes are
/// inconsistent — trying increasing levels until the resulting group's rows
/// contain a [labelSelector] match. Same relaxation backs the manual "row
/// container" step's own live-page/DOM-tree clicks (see call sites of
/// [domItemCandidateLoose] in `koni_dojo_webview.dart`), so escalating from
/// a field and manually tapping "Row container" now agree.
///
/// Both relaxations were needed on a real, live details
/// page, confirmed directly (not guessed): its row list's own `<ul>`
/// shares its class with one *other* unrelated `<ul>` elsewhere (so
/// `ul.<class> > li` matches 12, not exactly the 10 real rows — plain
/// [domItemCandidate] would reject that and fall back to bare `li`,
/// matching all 36 `<li>` on the page), and one real row ("Track:") has an
/// extra class the other nine don't share (which would otherwise trip
/// [domItemCandidate]'s "ambiguous, keep climbing" guard and skip past the
/// correct `<li>` level entirely). Accepting the over-match is safe *for
/// rows* because `_applyRows` (`lib/src/config_source.dart`) already drops
/// any row whose label doesn't match a configured field — the real,
/// hand-written config for that source relies on exactly this tolerance
/// (`section[x-data] ul > li` matches every row-shaped `<li>` on the page,
/// not just the four fields it actually uses). That tolerance is *not*
/// safe for the grid pickers (Popular/Chapters/Genre), which is why both
/// relaxations stay opt-in via `skipAmbiguousClasses`/
/// [domItemCandidateLoose] rather than becoming [domItemCandidate]'s
/// default — confirmed via a real regression in the JS jsdom suite before
/// landing this (see [domItemCandidate]'s doc comment).
DomItemCandidate? guessRowContainer(
  dom.Document doc,
  dom.Element clicked, {
  String labelSelector = 'strong',
  int maxLevels = 6,
}) {
  var minLevel = 0;
  while (minLevel <= maxLevels) {
    final candidate = domItemCandidateLoose(
      doc,
      clicked,
      minLevel: minLevel,
      maxLevels: maxLevels,
    );
    if (candidate == null) return null;
    final rows = doc.querySelectorAll(candidate.selector);
    if (rows.any((r) => r.querySelector(labelSelector) != null)) {
      return candidate;
    }
    minLevel = candidate.level + 1;
  }
  return null;
}

/// What a click on one row of an *already-confirmed* rows container tells
/// us about that field: the row's own label text, plus a value selector
/// scoped to just that row.
class RowFieldSeed {
  const RowFieldSeed({required this.labelText, required this.valueSelector});

  final String labelText;
  final String? valueSelector;
}

/// Finds which of [containerSelector]'s matched rows contains [clicked] and
/// returns that row's own label text and a value selector scoped to it —
/// `null` if [clicked] isn't inside any matched row, or that row has no
/// [labelSelector] match.
///
/// Extracted as a pure, public function — rather than inlined into
/// `_seedRowFieldFromElement` in `koni_dojo_webview.dart`, which is what
/// this replaces — specifically so it's unit-testable directly against a
/// parsed [dom.Document] (see `dom_tree_algo_test.dart`) without a live
/// WebView or a pumped widget tree. Its JS counterpart is
/// `seedRowFieldFromClick` in `_pickerScript`'s picker-algo block, which
/// additionally runs its own [guessRowContainer]-style widen loop first —
/// the live-page-click call site can't assume a container is already known
/// the way this one can (see `_seedRowFieldFromLiveClick`'s doc comment for
/// why that call site can't reuse this function directly).
RowFieldSeed? rowFieldSeed(
  dom.Document doc,
  String containerSelector,
  String labelSelector,
  dom.Element clicked,
) {
  dom.Element? ownRow;
  for (final row in doc.querySelectorAll(containerSelector)) {
    if (identical(row, clicked) ||
        row.querySelectorAll('*').any((n) => identical(n, clicked))) {
      ownRow = row;
      break;
    }
  }
  if (ownRow == null) return null;
  final labelText = ownRow.querySelector(labelSelector)?.text.trim();
  if (labelText == null || labelText.isEmpty) return null;
  return RowFieldSeed(
    labelText: labelText,
    valueSelector: domRelativeCandidate([ownRow], clicked)?.selector,
  );
}
