// Parity test for the Dart port of the picker's selector algorithm
// (lib/dom_tree_algo.dart) against the same fixture HTML the JS version's
// jsdom suite (test/picker_algo/picker-algo.test.js) is already verified
// against — the anti-drift mechanism is shared *fixtures*, not shared
// source (see dom_tree_algo.dart's doc comment for why). Plain `flutter
// test` — no Node/jsdom, no WebView: this is the whole reason the DOM-tree
// sidebar's algorithm was hand-ported to Dart rather than run through
// dart2js.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:koni_dojo_webview/dom_tree_algo.dart';

void main() {
  group('WordPress-shaped blog listing fixture', () {
    final html = File(
      'test/picker_algo/fixtures/wp-blog-listing.html',
    ).readAsStringSync();
    final doc = html_parser.parse(html);

    test('finds the repeating article group', () {
      final titleLink = doc.querySelector('article h2.entry-title a');
      expect(titleLink, isNotNull);

      final item = domItemCandidate(doc, titleLink!);
      expect(item, isNotNull);
      expect(item!.tag, 'article');
      expect(item.groupSize, 10);
      expect(doc.querySelectorAll(item.selector).length, 10);
      expect(
        item.sharedClasses.any((c) => RegExp(r'^post-\d+$').hasMatch(c)),
        isFalse,
        reason: 'excludes the per-post unique class',
      );
      expect(
        item.sharedClasses.any((c) => c.startsWith('category-')),
        isFalse,
        reason: 'excludes the alternating category class',
      );
    });

    test('relative title selector matches all 10 item roots, correct '
        'preview', () {
      final titleLink = doc.querySelector('article h2.entry-title a')!;
      final item = domItemCandidate(doc, titleLink)!;
      final itemRoots = doc.querySelectorAll(item.selector);

      final titleRel = domRelativeCandidate(itemRoots, titleLink);
      expect(titleRel, isNotNull);
      expect(titleRel!.matchCount, 10);
      expect(titleRel.preview, contains('Field Notes'));
    });

    test('relative url selector (image click, walks up to <a>) matches all '
        '10, preview is the href not the src', () {
      final firstArticle = doc.querySelector('article')!;
      final titleLink = firstArticle.querySelector('h2.entry-title a')!;
      final item = domItemCandidate(doc, titleLink)!;
      final itemRoots = doc.querySelectorAll(item.selector);
      final thumbLink = firstArticle.querySelector('a.entry-thumbnail img')!;

      final urlRel = domRelativeCandidate(
        itemRoots,
        thumbLink,
        preferAncestorTag: 'a',
        previewAttr: 'href',
      );
      expect(urlRel, isNotNull);
      expect(urlRel!.matchCount, 10);
      expect(urlRel.tag, 'a');
      expect(
        urlRel.preview,
        'https://blog.example.com/2026/07/14/field-notes-volume-one-in-depth-analysis/',
      );
    });

    test('a pick made inside a later card (not the first) still matches '
        'all 10 item roots', () {
      final titleLink = doc.querySelector('article h2.entry-title a')!;
      final item = domItemCandidate(doc, titleLink)!;
      final itemRoots = doc.querySelectorAll(item.selector);
      final laterCard = doc.querySelectorAll('article')[6];
      final laterTitleLink = laterCard.querySelector('h2.entry-title a')!;

      final rel = domRelativeCandidate(itemRoots, laterTitleLink);
      expect(rel, isNotNull);
      expect(rel!.matchCount, 10);
    });

    test('minLevel adjustment does not throw and returns null or a valid, '
        'larger candidate', () {
      final titleLink = doc.querySelector('article h2.entry-title a')!;
      final item = domItemCandidate(doc, titleLink)!;
      final wider = domItemCandidate(doc, titleLink, minLevel: item.level + 1);
      expect(wider == null || wider.groupSize >= item.groupSize, isTrue);
    });
  });

  group('synthetic Madara-style grid', () {
    // Mirrors picker-algo.test.js's madara fixture exactly: alternating
    // "featured"/"new" badge classes and a unique data-id per card, a
    // lazy-loaded cover image using data-src ahead of a placeholder src.
    final badges = [
      'featured',
      'new',
      '',
      'new',
      '',
      '',
      'featured',
      '',
      'new',
      '',
    ];
    final items = [
      for (var i = 0; i < badges.length; i++)
        '''
    <div class="page-item-detail manga ${badges[i]}" data-id="${1000 + i}">
      <div class="item-thumb">
        <a href="/manga/title-$i/">
          <img class="lazyload" src="/placeholder.png" data-src="/covers/title-$i.jpg" alt="cover" />
        </a>
      </div>
      <div class="post-title">
        <h3><a href="/manga/title-$i/">Manga Title $i</a></h3>
      </div>
    </div>''',
    ].join('\n');
    final html =
        '''
    <!doctype html><html><body>
      <div class="page-listing-item">
        <div class="row c-tabs-item__content">
          $items
        </div>
      </div>
    </body></html>''';
    final doc = html_parser.parse(html);

    test('finds all 10 synthetic cards, excluding the alternating badge '
        'class but keeping the real role classes', () {
      final firstCard = doc.querySelector('div.page-item-detail')!;
      final item = domItemCandidate(doc, firstCard);
      expect(item, isNotNull);
      expect(item!.groupSize, 10);
      expect(doc.querySelectorAll(item.selector).length, 10);
      expect(item.sharedClasses, contains('page-item-detail'));
      expect(item.sharedClasses, contains('manga'));
      expect(
        item.sharedClasses.any((c) => c == 'featured' || c == 'new'),
        isFalse,
      );
    });

    test('relative cover selector (attr mode) matches all 10, preview is '
        'the literal placeholder src, not the lazy data-src', () {
      final firstCard = doc.querySelector('div.page-item-detail')!;
      final item = domItemCandidate(doc, firstCard)!;
      final itemRoots = doc.querySelectorAll(item.selector);
      final coverImg = firstCard.querySelector('img')!;

      final coverRel = domRelativeCandidate(
        itemRoots,
        coverImg,
        previewAttr: 'src',
      );
      expect(coverRel, isNotNull);
      expect(coverRel!.matchCount, 10);
      expect(coverRel.preview, '/placeholder.png');
    });

    test('click outside every item root returns null instead of throwing', () {
      final firstCard = doc.querySelector('div.page-item-detail')!;
      final item = domItemCandidate(doc, firstCard)!;
      final itemRoots = doc.querySelectorAll(item.selector);
      final outsider = doc.querySelector('html')!;

      expect(domRelativeCandidate(itemRoots, outsider), isNull);
    });
  });

  group('details field-palette shape: single-root relative picks + '
      'item-mode genre', () {
    // Mirrors the JS test's "details" block: no repeating item container of
    // its own — the whole document (well, its body) is the one item root,
    // the exact seeding the details palette dialog uses ([engineDoc.body!]).
    final html = '''
    <!doctype html><html><body>
      <div class="post-title"><h1>Manga Title Deluxe</h1></div>
      <span class="author-content">Some Mangaka</span>
      <div class="summary__content"><p>A thrilling tale.</p></div>
      <div class="summary_image"><img src="/covers/big.jpg" /></div>
      <div class="genres-content">
        <a href="/genre/action">Action</a>
        <a href="/genre/drama">Drama</a>
        <a href="/genre/fantasy">Fantasy</a>
      </div>
    </body></html>''';
    final doc = html_parser.parse(html);
    final singleRoot = [doc.body!];

    test('title selector matches exactly the single (whole-document) root', () {
      final titleEl = doc.querySelector('.post-title h1')!;
      final titleRel = domRelativeCandidate(singleRoot, titleEl);
      expect(titleRel, isNotNull);
      expect(titleRel!.matchCount, 1);
      expect(titleRel.preview, 'Manga Title Deluxe');
    });

    test('cover selector (attr mode) matches the single root, preview is '
        'the src attribute', () {
      final coverEl = doc.querySelector('.summary_image img')!;
      final coverRel = domRelativeCandidate(
        singleRoot,
        coverEl,
        previewAttr: 'src',
      );
      expect(coverRel, isNotNull);
      expect(coverRel!.matchCount, 1);
      expect(coverRel.preview, '/covers/big.jpg');
    });

    test('genre is still item-mode: a repeating group of 3 tags, not a '
        'relative single-element pick', () {
      final firstGenre = doc.querySelector('.genres-content a')!;
      final genreItem = domItemCandidate(doc, firstGenre);
      expect(genreItem, isNotNull);
      expect(genreItem!.groupSize, 3);
      expect(doc.querySelectorAll(genreItem.selector).length, 3);
    });
  });

  group('details-page-shaped: a decoy element ahead of the real one, confirmed '
      'live via curl during the picker UX fixes session (see '
      'the workspace\'s own hand-written `details` '
      'block for the real selectors on this exact site)', () {
    // A classless cover <img> sits *after* an earlier, unrelated classless
    // <img> (the site's own header logo) -- so the bare selector 'img'
    // "matches something" but not the right thing. Real bug: the old
    // existence-only verify() accepted 'img' immediately because *a*
    // match existed anywhere on the page -- for the details palette's
    // single-global-root case (itemRoots is always [engineDoc.body]),
    // that's true for almost any tag+class combo that appears anywhere at
    // all. The picker's own live preview looked correct (it reads the
    // clicked element directly, never re-querying by selector), which is
    // exactly why this only surfaced once a real probe re-queried the
    // page with the picked selector and landed on the logo instead.
    final html = '''
      <!doctype html><html><body>
        <header><img src="/static/logo.png" alt="Site logo"></header>
        <nav><ul class="breadcrumbs"><li>Home</li><li>Manga</li></ul></nav>
        <main>
          <section class="flex items-center justify-center">
            <picture>
              <source srcset="/covers/normal.webp">
              <img src="/covers/fallback.jpg" alt="Blue Lock cover">
            </picture>
          </section>
          <ul class="details-list">
            <li><strong>Author(s): </strong><span><a href="/search?author=A">A</a></span><span><a href="/search?author=B">B</a></span></li>
            <li><strong>Tags(s): </strong>
              <span><a href="/search?included_tag=Action">Action</a>,</span>
              <span><a href="/search?included_tag=Drama">Drama</a>,</span>
            </li>
            <li><strong>Type: </strong><a href="/search?type=Manhwa">Manhwa</a></li>
            <li><strong>Status: </strong><a href="/search?status=Ongoing">Ongoing</a></li>
            <li class="flex gap-4"><strong>Track: </strong><a href="/track">Add</a></li>
          </ul>
          <aside>
            <!-- A second, unrelated list sharing the same class as the real
                 details list -- mirrors that page exactly:
                 its details <ul class="flex flex-col gap-4"> shares that
                 class with one other, unrelated two-item <ul> elsewhere, so
                 a class-scoped itemSelector over-matches by design and must
                 still be accepted, not rejected for being inexact. -->
            <ul class="details-list"><li>Related A</li><li>Related B</li></ul>
          </aside>
          <section>
            <picture><img src="/covers/related-1.jpg" alt="Other cover"></picture>
          </section>
        </main>
      </body></html>''';
    final doc = html_parser.parse(html);
    final singleRoot = [doc.body!];

    test('cover selector is not the bare, over-matching "img", and its '
        'first global match really is the clicked cover', () {
      final coverEl = doc.querySelector('main section img')!;
      final coverRel = domRelativeCandidate(
        singleRoot,
        coverEl,
        previewAttr: 'src',
      );
      expect(coverRel, isNotNull);
      expect(coverRel!.selector, isNot('img'));
      expect(identical(doc.querySelector(coverRel.selector), coverEl), isTrue);
    });

    test('genre KNOWN GAP -- still over-matches today (item-mode, untouched '
        'by this fix; span also matches the author span, no class-based '
        'scope exists to fix this without the rows-style extraction the '
        'real config actually uses). Pinned on purpose so a future genre '
        'fix changes this test intentionally, not by silent drift', () {
      // Index 3, not 1: the two breadcrumb-nav decoy <li>s (added for the
      // guessRowContainer tests below) sort before the details <ul>'s rows.
      final firstGenre = doc.querySelectorAll('li')[3].querySelector('a')!;
      final genreItem = domItemCandidate(doc, firstGenre);
      expect(genreItem, isNotNull);
      expect(genreItem!.selector, 'span');
      expect(
        doc.querySelectorAll(genreItem.selector).length,
        isNot(genreItem.groupSize),
      );
    });

    test('rowsMatchingLabels finds exactly the rows whose label contains a '
        'checked label string, case-insensitively — and every row when '
        'multiple labels are checked (mirrors genres: ["Tag","Type"] in the '
        'real config)', () {
      final rows = doc.querySelectorAll('li');
      final authorRows = rowsMatchingLabels(rows, 'strong', {'author'});
      expect(authorRows.length, 1);
      expect(
        authorRows.first.querySelector('strong')!.text,
        contains('Author'),
      );

      final genreRows = rowsMatchingLabels(rows, 'strong', {'tag', 'type'});
      expect(genreRows.length, 2);
    });

    test('rowsMatchingLabels is empty with no checked labels, or when no row '
        'label matches any of them', () {
      final rows = doc.querySelectorAll('li');
      expect(rowsMatchingLabels(rows, 'strong', {}), isEmpty);
      expect(rowsMatchingLabels(rows, 'strong', {'nonexistent'}), isEmpty);
    });

    test('simulateRowsFieldValue collects every value from a matching row, '
        'not just the one a click would land on — a click that only reaches '
        'the *second* author must still count as a working pick, since '
        '_applyRows collects every match per row, not just the first', () {
      final authorRows = rowsMatchingLabels(
        doc.querySelectorAll('li'),
        'strong',
        {'author'},
      );
      final sim = simulateRowsFieldValue(authorRows, 'a', join: ', ');
      expect(sim.rowsWithValue, 1);
      expect(sim.totalRows, 1);
      expect(sim.texts, ['A', 'B']);
      expect(sim.preview, 'A, B');
    });

    test('simulateRowsFieldValue across multiple matching rows (genres: Tag + '
        'Type) collects values from every one, matching the real '
        'real config shape', () {
      final genreRows = rowsMatchingLabels(
        doc.querySelectorAll('li'),
        'strong',
        {'tag', 'type'},
      );
      final sim = simulateRowsFieldValue(genreRows, 'a');
      expect(sim.rowsWithValue, 2);
      expect(sim.totalRows, 2);
      expect(sim.texts, ['Action', 'Drama', 'Manhwa']);
    });

    test('simulateRowsFieldValue with an empty valueSelector uses the row\'s '
        'own text — the "use whole row text" mode for a row with nothing '
        'distinct to click around the value', () {
      final statusRows = rowsMatchingLabels(
        doc.querySelectorAll('li'),
        'strong',
        {'status'},
      );
      final sim = simulateRowsFieldValue(statusRows, '');
      expect(sim.rowsWithValue, 1);
      expect(sim.texts.single, contains('Ongoing'));
    });

    test('simulateRowsFieldValue reports zero when nothing matches at all', () {
      final sim = simulateRowsFieldValue(const [], 'a');
      expect(sim.rowsWithValue, 0);
      expect(sim.totalRows, 0);
      expect(sim.preview, '');
    });

    test('simulateRowsFieldValue collapses internal whitespace and strips '
        'a lone trailing list-separator char -- both confirmed live on the '
        'live page. (1) Real pretty-printed HTML puts '
        'newlines/indentation between a row\'s child elements; a bare '
        '.trim() left them embedded in "whole row text" mode\'s value. '
        '(2) The real markup wraps each tag *and* its own separator comma '
        'in one element (`<span><a>Action</a>,</span>`) -- clicking that '
        'wrapper instead of the inner <a> (confirmed live: the two '
        'overlap almost pixel-for-pixel, a click near a tag\'s edge lands '
        'on the wrapper) produced values like "Action," with the '
        'separator baked in as if it were real data. Both mirrored by '
        '_applyRows in lib/src/config_source.dart, which this simulates.',
        () {
      final html = '''
        <!doctype html><html><body>
          <ul class="details-list">
            <li>
              <strong>Tags(s): </strong>
              <span><a>Action</a>,</span>
              <span><a>Drama</a>,</span>
              <span><a>Sports</a></span>
            </li>
          </ul>
        </body></html>''';
      final doc = html_parser.parse(html);
      final row = doc.querySelector('li')!;

      // Whole-row-text mode (empty valueSelector) -- the value spans every
      // child, so it's the case most exposed to embedded whitespace, and
      // ends in the last tag's own separator (there is none after the
      // final tag, "Sports", matching the real page's last-tag shape).
      final wholeRow = simulateRowsFieldValue([row], '');
      expect(wholeRow.texts.single, 'Tags(s): Action, Drama, Sports');
      expect(wholeRow.texts.single, isNot(contains('\n')));

      // The wrapper <span>s, not the <a>s inside them -- the realistic
      // "clicked the wrong element" case. Every tag but the last carries
      // its separator comma inside the wrapper; the fix strips exactly
      // one trailing separator, leaving clean values across the board
      // (including the already-clean last one, confirming the fix is a
      // no-op when there's nothing to strip).
      final wrapperMode = simulateRowsFieldValue([row], 'span');
      expect(wrapperMode.texts, ['Action', 'Drama', 'Sports']);

      // The <a> links directly -- the ideal click target, unaffected by
      // either fix since it never carried the separator or stray
      // whitespace to begin with.
      final linkMode = simulateRowsFieldValue([row], 'a');
      expect(linkMode.texts, ['Action', 'Drama', 'Sports']);
    });

    test('guessRowContainer, escalating from a clicked genre tag, widens past '
        'the over-matching bare "li" (this page also has two unrelated '
        'breadcrumb <li>s) to a scoped container — never presents a bare '
        'tag the way the cover selector bug did', () {
      final firstGenre = doc.querySelectorAll('li')[3].querySelector('a')!;
      final guess = guessRowContainer(doc, firstGenre);
      expect(guess, isNotNull);
      expect(guess!.selector, isNot('li'));
      expect(guess.selector, isNot('span'));
      final rows = doc.querySelectorAll(guess.selector);
      expect(rows.length, lessThan(doc.querySelectorAll('li').length));
      expect(rows.where((r) => r.querySelector('strong') != null).length, 5);
    });

    test(
      'guessRowContainer accepts an over-matching but well-scoped '
      'container rather than rejecting it for being inexact — the real '
      'live page\'s own details <ul> shares its class with one '
      'other, unrelated two-item <ul>, so an exact-match requirement '
      '(domItemCandidate\'s own rule, correct for grid pickers but wrong '
      'here) would reject the good selector and fall back to the far '
      'worse bare "li" instead. _applyRows tolerates the extra two rows '
      'by dropping any row whose label never matches a configured field.',
      () {
        final firstGenre = doc.querySelectorAll('li')[3].querySelector('a')!;
        final guess = guessRowContainer(doc, firstGenre);
        expect(guess, isNotNull);
        expect(guess!.selector, 'ul.details-list > li');
        final rows = doc.querySelectorAll(guess.selector);
        expect(rows.length, 7); // 5 real rows + 2 unrelated "Related" items
        expect(guess.groupSize, 5);
        expect(guess.globalMatchCount, 7);
      },
    );

    test('guessRowContainer does not skip past the real row level just '
        'because one sibling ("Track:") carries an extra class the others '
        'don\'t share — confirmed on a live page: domItemCandidate\'s '
        '"ambiguous classes, keep climbing" guard treated exactly this as a '
        'reason to skip straight past the <li> level and land several '
        'levels higher, on an unrelated pair of layout <section>s instead', () {
      final firstGenre = doc.querySelectorAll('li')[3].querySelector('a')!;
      final guess = guessRowContainer(doc, firstGenre);
      expect(guess, isNotNull);
      expect(guess!.selector, contains('li'));
      expect(guess.selector, isNot(contains('section')));
    });

    test('guessRowContainer returns null when climbing from an element with '
        'no ancestor that ever forms a labeled repeating group', () {
      final logo = doc.querySelector('header img')!;
      expect(guessRowContainer(doc, logo), isNull);
    });

    test('rowFieldSeed, given the already-confirmed row container, finds '
        'the clicked element\'s own row and derives label + a row-scoped '
        'value selector -- clicking the *second* tag specifically, to rule '
        'out a fix that only happens to work for whichever element is '
        'first in the row', () {
      final tagsRow = doc.querySelectorAll('li')[3];
      final dramaLink = tagsRow.querySelectorAll('a')[1];
      expect(dramaLink.text, 'Drama');

      final seed = rowFieldSeed(doc, 'ul.details-list > li', 'strong', dramaLink);
      expect(seed, isNotNull);
      expect(seed!.labelText, 'Tags(s):');
      expect(seed.valueSelector, isNotNull);
      final matches = tagsRow.querySelectorAll(seed.valueSelector!);
      expect(matches.map((e) => e.text), ['Action', 'Drama']);
    });

    test('rowFieldSeed returns null when the clicked element is not inside '
        'any of the container selector\'s matched rows', () {
      final logo = doc.querySelector('header img')!;
      expect(rowFieldSeed(doc, 'ul.details-list > li', 'strong', logo), isNull);
    });

    test('rowFieldSeed returns null when the row it lands in has no label '
        'match -- e.g. one of the unrelated "Related" rows the '
        'over-matching container also happens to pick up', () {
      final relatedRow = doc.querySelector('aside li')!;
      expect(
        rowFieldSeed(doc, 'ul.details-list > li', 'strong', relatedRow),
        isNull,
      );
    });
  });
}
