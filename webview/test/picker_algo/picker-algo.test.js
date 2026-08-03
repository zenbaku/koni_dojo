// Headless test for the element-picker's selector-generation algorithm.
//
// The algorithm can't be Dart (it walks a live DOM at click time, which
// only exists inside the WebView), so it's authored as a JS string embedded
// in `_pickerScript` in ../../lib/koni_dojo_webview.dart. Rather than
// maintaining a hand-copied duplicate here that could silently drift from
// what actually ships, `loadAlgoFromSource()` below extracts the algorithm
// verbatim from that Dart file (between the `picker-algo:start`/`:end`
// markers) and evaluates it directly — this test always exercises the
// exact code the WebView will run.
//
// Not wired into `task check` (Node/jsdom is a scoped exception to this
// project's Dart-only tooling norm, not a general addition) — run manually:
//   npm install && npm test
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { JSDOM } = require('jsdom');

function loadAlgoFromSource() {
  const dartPath = path.join(__dirname, '..', '..', 'lib', 'koni_dojo_webview.dart');
  const src = fs.readFileSync(dartPath, 'utf8');
  const startMarker = '// picker-algo:start';
  const endMarker = '// picker-algo:end';
  const startIdx = src.indexOf(startMarker);
  const end = src.indexOf(endMarker);
  if (startIdx === -1 || end === -1 || end < startIdx) {
    throw new Error(
      'picker-algo:start/end markers not found in koni_dojo_webview.dart -- ' +
        'did the _pickerScript constant move, get renamed, or lose its markers? ' +
        'This test can only verify code it can find.',
    );
  }
  // Extraction starts on the line *after* the marker comment, not right
  // after the marker token itself -- the marker's own line has trailing
  // prose after it (a `--` explanation), which would otherwise be spliced
  // into the extracted source as un-commented text.
  const startOfBlock = src.indexOf('\n', startIdx) + 1;
  const jsSource = src.slice(startOfBlock, end);
  const factory = new Function(
    `${jsSource}\nreturn { classList, sharedClasses, cssEscape, tagSelector, computeItemCandidate, computeRelativeCandidate, seedRowFieldFromClick };`,
  );
  return factory();
}

const {
  classList,
  computeItemCandidate,
  computeRelativeCandidate,
  seedRowFieldFromClick,
} = loadAlgoFromSource();

let failures = 0;
function check(label, cond, detail) {
  if (cond) {
    console.log(`PASS  ${label}`);
  } else {
    failures++;
    console.log(`FAIL  ${label}${detail ? '  -- ' + detail : ''}`);
  }
}

function fixture(name) {
  return fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
}

// ---------------------------------------------------------------------
// Sanity: the extraction itself found real functions, not undefined stubs
// (a silent extraction failure would make every check below vacuously
// pass/fail in confusing ways otherwise).
// ---------------------------------------------------------------------
assert.strictEqual(typeof classList, 'function', 'classList did not extract as a function');
assert.strictEqual(
  typeof computeItemCandidate,
  'function',
  'computeItemCandidate did not extract as a function',
);
assert.strictEqual(
  typeof computeRelativeCandidate,
  'function',
  'computeRelativeCandidate did not extract as a function',
);
assert.strictEqual(
  typeof seedRowFieldFromClick,
  'function',
  'seedRowFieldFromClick did not extract as a function',
);

// ---------------------------------------------------------------------
// Test 1: a WordPress-shaped blog listing (synthetic, but reproducing
// stock `post_class()` output and a real theme's wrapper nesting). 10
// <article> items, each carrying a UNIQUE per-post class ("post-14153")
// and an ALTERNATING category class ("category-field-notes" /
// "category-uncategorized") on top of shared role classes -- exact-class-
// set matching would silently fragment this into 10 separate "groups" of
// one; the algorithm must key off the *shared* subset instead.
// ---------------------------------------------------------------------
{
  const html = fixture('wp-blog-listing.html');
  const dom = new JSDOM(html);
  const document = dom.window.document;

  const firstArticle = document.querySelector('article');
  check('wp-blog: fixture has a first <article>', !!firstArticle);
  const titleLink = firstArticle.querySelector('h2.entry-title a');
  check('wp-blog: fixture has a title link inside first article', !!titleLink);

  const item = computeItemCandidate(titleLink);
  check('wp-blog: item candidate found', !!item);
  if (item) {
    check('wp-blog: item tag is article', item.tag === 'article', `got ${item.tag}`);
    check(
      'wp-blog: item group size is 10 (all articles found)',
      item.groupSize === 10,
      `got ${item.groupSize}`,
    );
    check(
      'wp-blog: shared-class signature excludes the per-post unique class',
      !item.sharedClasses.some((c) => /^post-\d+$/.test(c)),
      JSON.stringify(item.sharedClasses),
    );
    check(
      'wp-blog: shared-class signature excludes the alternating category class',
      !item.sharedClasses.some((c) => c.startsWith('category-')),
      JSON.stringify(item.sharedClasses),
    );
    check(
      'wp-blog: computed selector re-selects exactly the 10 articles globally',
      document.querySelectorAll(item.selector).length === 10,
      `selector="${item.selector}" matched ${document.querySelectorAll(item.selector).length}`,
    );

    const itemRoots = Array.from(document.querySelectorAll(item.selector));

    const titleRel = computeRelativeCandidate(itemRoots, titleLink);
    check(
      'wp-blog: relative title selector matches all 10 item roots',
      titleRel.matchCount === 10,
      `selector="${titleRel.selector}" matched ${titleRel.matchCount}/10`,
    );
    check(
      'wp-blog: relative title preview is the clicked link\'s own text (no previewAttr = text mode)',
      titleRel.preview.includes('Field Notes'),
      `preview="${titleRel.preview}"`,
    );

    const thumbLink = firstArticle.querySelector('a.entry-thumbnail img');
    check('wp-blog: fixture has a thumbnail image inside its link', !!thumbLink);
    const urlRel = computeRelativeCandidate(itemRoots, thumbLink, {
      preferAncestorTag: 'a',
      previewAttr: 'href',
    });
    check(
      'wp-blog: relative url selector (img click, walks up to <a>) matches all 10 item roots',
      urlRel.matchCount === 10,
      `selector="${urlRel.selector}" matched ${urlRel.matchCount}/10`,
    );
    check(
      'wp-blog: relative url selector resolves to an <a> tag, not the clicked <img>',
      urlRel.tag === 'a',
      `got tag=${urlRel.tag}`,
    );
    check(
      'wp-blog: relative url preview is the resolved <a>\'s href, not the clicked <img>\'s src',
      urlRel.preview ===
        'https://blog.example.com/2026/07/14/field-notes-volume-one-in-depth-analysis/',
      `preview="${urlRel.preview}"`,
    );

    const laterArticle = document.querySelectorAll('article')[6];
    const laterTitleLink = laterArticle.querySelector('h2.entry-title a');
    const laterRel = computeRelativeCandidate(itemRoots, laterTitleLink);
    check(
      'wp-blog: relative title pick made inside the 7th card still matches all 10 roots',
      laterRel.matchCount === 10,
      `selector="${laterRel.selector}" matched ${laterRel.matchCount}/10`,
    );

    const wider = computeItemCandidate(titleLink, { minLevel: item.level + 1 });
    check(
      'wp-blog: minLevel adjustment does not throw and returns null or a valid, larger candidate',
      wider === null || wider.groupSize >= item.groupSize,
      wider ? `groupSize=${wider.groupSize}` : 'null',
    );
  }
}

// ---------------------------------------------------------------------
// Test 2: synthetic Madara-style grid (the real shape behind several
// catalog sources whose live pages sit behind Cloudflare and can't be
// curl'd for a fixture): div.page-item-detail items, each with an extra
// alternating "featured"/"new" badge class and a unique data-id,
// div.post-title a for title, and a lazy-loaded cover image using
// data-src ahead of a placeholder src.
// ---------------------------------------------------------------------
{
  const badges = ['featured', 'new', '', 'new', '', '', 'featured', '', 'new', ''];
  const items = badges
    .map(
      (badge, i) => `
    <div class="page-item-detail manga ${badge}" data-id="${1000 + i}">
      <div class="item-thumb">
        <a href="/manga/title-${i}/">
          <img class="lazyload" src="/placeholder.png" data-src="/covers/title-${i}.jpg" alt="cover" />
        </a>
      </div>
      <div class="post-title">
        <h3><a href="/manga/title-${i}/">Manga Title ${i}</a></h3>
      </div>
    </div>`,
    )
    .join('\n');
  const html = `<!doctype html><html><body>
    <div class="page-listing-item">
      <div class="row c-tabs-item__content">
        ${items}
      </div>
    </div>
  </body></html>`;

  const dom = new JSDOM(html);
  const document = dom.window.document;
  const cards = document.querySelectorAll('div.page-item-detail');
  check('madara: fixture has 10 synthetic cards', cards.length === 10);

  const firstCard = cards[0];
  const titleLink = firstCard.querySelector('div.post-title a');

  const item = computeItemCandidate(titleLink);
  check('madara: item candidate found', !!item);
  if (item) {
    check('madara: item group size is 10', item.groupSize === 10, `got ${item.groupSize}`);
    check(
      'madara: shared-class signature excludes the alternating badge class',
      !item.sharedClasses.includes('featured') && !item.sharedClasses.includes('new'),
      JSON.stringify(item.sharedClasses),
    );
    check(
      'madara: shared-class signature keeps the real role classes',
      item.sharedClasses.includes('page-item-detail') && item.sharedClasses.includes('manga'),
      JSON.stringify(item.sharedClasses),
    );
    check(
      'madara: computed selector re-selects exactly the 10 cards',
      document.querySelectorAll(item.selector).length === 10,
      `selector="${item.selector}"`,
    );

    const itemRoots = Array.from(document.querySelectorAll(item.selector));
    const titleRel = computeRelativeCandidate(itemRoots, titleLink);
    check(
      'madara: relative title selector matches all 10 item roots',
      titleRel.matchCount === 10,
      `selector="${titleRel.selector}"`,
    );

    const coverImg = firstCard.querySelector('img');
    const coverRel = computeRelativeCandidate(itemRoots, coverImg, {
      previewAttr: 'src',
    });
    check(
      'madara: relative cover selector matches all 10 item roots',
      coverRel.matchCount === 10,
      `selector="${coverRel.selector}"`,
    );
    // The picker doesn't do lazy-load attribute sniffing (by design -- see
    // the ConfigForm attr field, which is where a user overrides this): the
    // preview honestly shows the placeholder `src`, not the real
    // `data-src`, so this pins that known, deliberate limitation instead of
    // silently "fixing" it here and drifting from what the dialog actually
    // shows.
    check(
      'madara: relative cover preview is the literal src attr (placeholder, not the lazy data-src)',
      coverRel.preview === '/placeholder.png',
      `preview="${coverRel.preview}"`,
    );

    const urlRel = computeRelativeCandidate(itemRoots, coverImg, {
      preferAncestorTag: 'a',
      previewAttr: 'href',
    });
    check(
      'madara: relative url selector (cover click, walks up to <a>) matches all 10',
      urlRel.matchCount === 10 && urlRel.tag === 'a',
      `selector="${urlRel.selector}" tag=${urlRel.tag}`,
    );
    check(
      'madara: relative url preview is the resolved <a>\'s href',
      urlRel.preview === '/manga/title-0/',
      `preview="${urlRel.preview}"`,
    );

    const laterCard = cards[6];
    const laterCover = laterCard.querySelector('img');
    const laterCoverRel = computeRelativeCandidate(itemRoots, laterCover);
    check(
      'madara: relative cover pick made inside the 7th card still matches all 10 roots',
      laterCoverRel.matchCount === 10,
      `selector="${laterCoverRel.selector}" matched ${laterCoverRel.matchCount}/10`,
    );

    const outside = document.querySelector('.page-listing-item');
    const outsideRel = computeRelativeCandidate(itemRoots, outside);
    check('madara: click outside every item root returns null instead of throwing', outsideRel === null);
  }
}

// ---------------------------------------------------------------------
// Test 3: the real click sequence, not just the pure algorithm. In the
// actual picker script, a mouseover handler adds a "__koni_hover" class to
// whatever's under the cursor *before* every click (the click target IS
// the hovered element), and a confirmed item step highlights every matched
// item root with "__koni_group". If classList() doesn't filter these out,
// every relative-selector candidate built from the click target bakes the
// housekeeping class in, and the resulting selector then matches nothing
// once the picker's own classes are gone (i.e. against the clean,
// already-probed HTML the Dart side cross-checks against). This exact
// scenario caught a real bug: computeRelativeCandidate was returning
// "h3.entry-title.__koni_hover" instead of "h3.entry-title", which would
// have stuck every user at the title step on their very first pick.
// ---------------------------------------------------------------------
{
  const html = fixture('wp-blog-listing.html');
  const dom = new JSDOM(html);
  const document = dom.window.document;

  const itemRoots = Array.from(document.querySelectorAll('article'));
  check('hover-pollution: fixture has 10 item roots', itemRoots.length === 10);
  itemRoots.forEach((el) => el.classList.add('__koni_group'));

  const clickedCard = itemRoots[3];
  const titleLink = clickedCard.querySelector('h2.entry-title a');
  titleLink.classList.add('__koni_hover');

  const rel = computeRelativeCandidate(itemRoots, titleLink);
  check(
    'hover-pollution: relative selector contains no __koni token',
    !rel.selector.includes('__koni'),
    `selector="${rel.selector}"`,
  );
  check(
    'hover-pollution: relative selector still matches all 10 item roots despite housekeeping classes',
    rel.matchCount === 10,
    `selector="${rel.selector}" matched ${rel.matchCount}/10`,
  );

  const dom2 = new JSDOM(html);
  const document2 = dom2.window.document;
  const freshTitleLink = document2.querySelector('article h2.entry-title a');
  freshTitleLink.classList.add('__koni_hover');
  const item = computeItemCandidate(freshTitleLink);
  check(
    'hover-pollution: item candidate selector contains no __koni token',
    !!item && !item.selector.includes('__koni'),
    item ? `selector="${item.selector}"` : 'null',
  );
  check(
    'hover-pollution: item candidate still finds all 10 despite the hovered click target',
    !!item && item.groupSize === 10,
    item ? `groupSize=${item.groupSize}` : 'null',
  );
}

// ---------------------------------------------------------------------
// Test 4: the `details` field palette's usage shape. Unlike every test
// above (N confirmed item roots from a repeating list), the details dialog
// has no item container of its own — it seeds computeRelativeCandidate with
// a single-element itemRoots array ([document.body], see `forceMode` in
// _pickerScript's click handler) for title/author/description/cover, and
// still uses computeItemCandidate directly for genreSelector (an unlabeled
// *list* field, the one details field that's still repeating-group shaped).
// Neither function needed to change for this — computeRelativeCandidate's
// `hits === itemRoots.length` verification degenerates cleanly to
// `hits === 1` for a one-element root array — but this exact shape (a
// single, whole-document root) was never exercised until now.
// ---------------------------------------------------------------------
{
  const html = `<!doctype html><html><body>
    <div class="post-title"><h1>Manga Title Deluxe</h1></div>
    <span class="author-content">Some Mangaka</span>
    <div class="summary__content"><p>A thrilling tale.</p></div>
    <div class="summary_image"><img src="/covers/big.jpg" /></div>
    <div class="genres-content">
      <a href="/genre/action">Action</a>
      <a href="/genre/drama">Drama</a>
      <a href="/genre/fantasy">Fantasy</a>
    </div>
  </body></html>`;
  const dom = new JSDOM(html);
  const document = dom.window.document;
  const singleRoot = [document.body];

  const titleEl = document.querySelector('.post-title h1');
  const titleRel = computeRelativeCandidate(singleRoot, titleEl);
  check(
    'details: title selector matches exactly the single (whole-document) root',
    titleRel.matchCount === 1,
    `selector="${titleRel.selector}" matched ${titleRel.matchCount}/1`,
  );
  check(
    'details: title preview is the element\'s own text (text mode)',
    titleRel.preview === 'Manga Title Deluxe',
    `preview="${titleRel.preview}"`,
  );

  const coverEl = document.querySelector('.summary_image img');
  const coverRel = computeRelativeCandidate(singleRoot, coverEl, { previewAttr: 'src' });
  check(
    'details: cover selector (attr mode) matches the single root',
    coverRel.matchCount === 1,
    `selector="${coverRel.selector}" matched ${coverRel.matchCount}/1`,
  );
  check(
    'details: cover preview is the src attribute, not the text content',
    coverRel.preview === '/covers/big.jpg',
    `preview="${coverRel.preview}"`,
  );

  // genreSelector: still item-mode (a repeating group), not relative — the
  // one details field shaped like popular/pages, not like title/author.
  const firstGenre = document.querySelector('.genres-content a');
  const genreItem = computeItemCandidate(firstGenre);
  check('details: genre candidate found (a repeating group of tags)', !!genreItem);
  if (genreItem) {
    check(
      'details: genre group size is 3 (all genre tags found)',
      genreItem.groupSize === 3,
      `got ${genreItem.groupSize}`,
    );
    check(
      'details: genre selector re-selects exactly the 3 tags globally',
      document.querySelectorAll(genreItem.selector).length === 3,
      `selector="${genreItem.selector}"`,
    );
  }
}

// ---------------------------------------------------------------------
// Test 5: a decoy element, shaped after a real details page
// (confirmed live via curl during the picker UX fixes session -- see
// the workspace's own hand-written `details`
// block for the real, working selectors on this exact site). A classless
// cover <img> sits *after* an earlier, unrelated classless <img> (the
// site's own header logo) -- so the bare selector 'img' "matches
// something" but not the right thing.
//
// This was a real bug, not hypothetical: computeRelativeCandidate's old
// existence-only verify() (`itemRoots[i].querySelector(relSelector)` truthy)
// accepted 'img' immediately, because *a* match existed somewhere on the
// page -- for the details palette's single-global-root case (itemRoots is
// always [document.body]), that's true for almost any tag+class combo that
// appears anywhere at all. The picker's own live preview looked correct
// (it reads the clicked element directly, never re-querying by selector),
// which is exactly why this only surfaced once a real probe re-queried the
// page with the picked selector and landed on the logo instead of the
// cover. The fix: verify() must check that the *first* match in the
// containing root actually *is* the clicked element, matching what the
// engine's own querySelector-based extraction will do at scrape time.
// ---------------------------------------------------------------------
{
  const html = `<!doctype html><html><body>
    <header>
      <img src="/static/logo.png" alt="Site logo">
    </header>
    <main>
      <section class="flex items-center justify-center">
        <picture>
          <source srcset="/covers/normal.webp">
          <img src="/covers/fallback.jpg" alt="Blue Lock cover">
        </picture>
      </section>
      <ul>
        <li><strong>Author(s): </strong><span><a href="/search?author=A">A</a></span></li>
        <li><strong>Tags(s): </strong>
          <span><a href="/search?included_tag=Action">Action</a>,</span>
          <span><a href="/search?included_tag=Drama">Drama</a>,</span>
        </li>
      </ul>
      <section>
        <picture><img src="/covers/related-1.jpg" alt="Other cover"></picture>
      </section>
    </main>
  </body></html>`;
  const dom = new JSDOM(html);
  const document = dom.window.document;
  const singleRoot = [document.body];

  const coverEl = document.querySelector('main section img');
  const coverRel = computeRelativeCandidate(singleRoot, coverEl, { previewAttr: 'src' });
  check(
    'details-page-shaped: cover selector is not the bare, over-matching "img"',
    coverRel.selector !== 'img',
    `selector="${coverRel.selector}"`,
  );
  check(
    'details-page-shaped: cover selector\'s first global match really is the clicked cover, not the earlier decoy <img>',
    document.querySelector(coverRel.selector) === coverEl,
    `selector="${coverRel.selector}" resolved to ` +
      (document.querySelector(coverRel.selector)
        ? document.querySelector(coverRel.selector).outerHTML
        : 'nothing'),
  );

  // Genre is a DOCUMENTED, still-open gap, not a passing feature: it uses
  // computeItemCandidate (item mode), which this session's fix doesn't
  // touch. The live page's tag <span>s share no class with each other, and
  // their only shared parent (a bare <li>) also wraps the structurally
  // identical author <span>, so no class/id-based ancestor scope
  // disambiguates them -- the real hand-written config sidesteps this
  // entirely via a `rows` (label/value) extraction the picker doesn't
  // generate. This assertion pins *today's* known-wrong fallback so a
  // future genre fix changes this test on purpose, instead of the gap
  // silently drifting unnoticed.
  const firstGenre = document.querySelector('li:nth-of-type(2) a');
  const genreItem = computeItemCandidate(firstGenre);
  check(
    'details-page-shaped: genre KNOWN GAP -- still over-matches today (span ' +
      'also matches the author span, no class-based scope exists to fix ' +
      'this without the rows-style extraction the real config actually uses)',
    genreItem &&
      genreItem.selector === 'span' &&
      document.querySelectorAll(genreItem.selector).length !== genreItem.groupSize,
    genreItem
      ? `selector="${genreItem.selector}" groupSize=${genreItem.groupSize} ` +
          `globalMatches=${document.querySelectorAll(genreItem.selector).length}`
      : 'no candidate found at all',
  );
}

// ---------------------------------------------------------------------
// computeItemCandidate's `loose` opt -- the rows-only relaxation backing
// the picker's "row container" step (both the escalation auto-seed and a
// manual live-page click). Confirmed on a real, live details
// page, not hypothetical: its row list's own <ul> shares its class
// with one *other*, unrelated two-item <ul> elsewhere (so a class-scoped
// itemSelector over-matches by design), and one real row ("Track:")
// carries an extra class the other nine rows don't share. Without `loose`
// (the default, correct for the grid pickers), both of those trip the
// strict rules and the algorithm ends up several levels too high, on an
// unrelated pair of layout <section>s -- exactly the bug a screenshot
// surfaced this session. `{loose: true}` fixes both without touching
// default behavior at all (see the two checks below, and dom_tree_algo.dart's
// matching Dart-port tests for the fuller narrative).
// ---------------------------------------------------------------------
{
  const html = `<!doctype html><html><body>
    <nav><ul class="breadcrumbs"><li>Home</li><li>Manga</li></ul></nav>
    <main>
      <ul class="details-list">
        <li><strong>Author(s): </strong><span><a href="/search?author=A">A</a></span></li>
        <li><strong>Tags(s): </strong>
          <span><a href="/search?included_tag=Action">Action</a>,</span>
          <span><a href="/search?included_tag=Drama">Drama</a>,</span>
        </li>
        <li><strong>Type: </strong><a href="/search?type=Manhwa">Manhwa</a></li>
        <li><strong>Status: </strong><a href="/search?status=Ongoing">Ongoing</a></li>
        <li class="flex gap-4"><strong>Track: </strong><a href="/track">Add</a></li>
      </ul>
      <aside>
        <ul class="details-list"><li>Related A</li><li>Related B</li></ul>
      </aside>
    </main>
  </body></html>`;
  const dom = new JSDOM(html);
  const document = dom.window.document;

  // Click the "Track:" row itself -- the one whose own extra class trips
  // the strict guard. Without `loose`, this must NOT find the real,
  // 5-row group (the guard skips past it, same as the live page).
  const trackLi = document.querySelector('li.flex.gap-4');
  const strict = computeItemCandidate(trackLi);
  check(
    'loose opt: without it, a row with an outlier class ("Track:") skips ' +
      'past the real <li> group (grids need this; rows don\'t)',
    !strict || strict.tag !== 'li',
    strict ? `selector="${strict.selector}" tag=${strict.tag}` : 'no candidate at all',
  );

  const loose = computeItemCandidate(trackLi, { loose: true });
  check(
    'loose opt: with it, the same click finds the real, scoped 5-row group ' +
      '(over-matching the 2 unrelated "Related" items, which is fine -- ' +
      '_applyRows drops any row whose label doesn\'t match a configured field)',
    !!loose && loose.selector === 'ul.details-list > li' && loose.groupSize === 5,
    loose
      ? `selector="${loose.selector}" groupSize=${loose.groupSize} ` +
          `globalMatches=${document.querySelectorAll(loose.selector).length}`
      : 'no candidate found at all',
  );
}

// ---------------------------------------------------------------------
// seedRowFieldFromClick -- the live-click rows-escalation orchestration
// (guess a labeled container, find which row the click landed in, read its
// label + a value selector scoped to it). Previously this was a one-off
// `evaluateJavascript` string template in `_seedRowFieldFromLiveClick`
// (koni_dojo_webview.dart) with no automated coverage at all -- the genre
// live-click bug this session (escalating from a clicked "Drama" tag
// produced an empty checklist) was only ever caught and verified by hand
// against the real page. Extracting the orchestration into the
// tested picker-algo block closes that gap: this fixture mirrors the real
// page shape (decoy <ul> sharing a class with the real one, one outlier-
// classed row) and clicks the *second* tag specifically, to rule out a fix
// that only happens to work for whichever element is first in document
// order.
// ---------------------------------------------------------------------
{
  const html = `<!doctype html><html><body>
    <nav><ul class="breadcrumbs"><li>Home</li><li>Manga</li></ul></nav>
    <main>
      <ul class="details-list">
        <li><strong>Author(s): </strong><span><a href="/search?author=A">A</a></span></li>
        <li><strong>Tags(s): </strong>
          <span><a href="/search?included_tag=Action">Action</a>,</span>
          <span><a href="/search?included_tag=Drama">Drama</a>,</span>
        </li>
        <li><strong>Type: </strong><a href="/search?type=Manhwa">Manhwa</a></li>
        <li><strong>Status: </strong><a href="/search?status=Ongoing">Ongoing</a></li>
        <li class="flex gap-4"><strong>Track: </strong><a href="/track">Add</a></li>
      </ul>
      <aside>
        <ul class="details-list"><li>Related A</li><li>Related B</li></ul>
      </aside>
    </main>
  </body></html>`;
  const dom = new JSDOM(html);
  const document = dom.window.document;

  const genreLinks = document.querySelectorAll('li:nth-of-type(2) a');
  check('seed: fixture has 2 genre tags', genreLinks.length === 2);
  const dramaLink = genreLinks[1];
  check('seed: second tag is Drama', dramaLink.textContent === 'Drama');

  const seed = seedRowFieldFromClick(dramaLink, 'strong');
  check('seed: finds a container', !!seed, 'no result at all');
  if (seed) {
    check(
      'seed: container is the scoped 5-row group, not a bare tag',
      seed.containerSelector === 'ul.details-list > li',
      `containerSelector="${seed.containerSelector}"`,
    );
    check(
      'seed: label text is the Tags(s) row\'s own label, not some other row\'s',
      seed.labelText === 'Tags(s):',
      `labelText="${seed.labelText}"`,
    );
    check(
      'seed: value selector, scoped to just this row, captures both real ' +
        'tags -- not the author row\'s value, and not every <a> on the page',
      (() => {
        if (!seed.valueSelector) return false;
        const row = dramaLink.closest('li');
        const matches = Array.from(row.querySelectorAll(seed.valueSelector)).map((el) => el.textContent);
        return matches.length === 2 && matches[0] === 'Action' && matches[1] === 'Drama';
      })(),
      `valueSelector="${seed.valueSelector}"`,
    );
  }

  const nullSeed = seedRowFieldFromClick(null, 'strong');
  check('seed: a null clicked element returns null instead of throwing', nullSeed === null);

  const logo = document.querySelector('.breadcrumbs li');
  const noLabelSeed = seedRowFieldFromClick(logo, 'strong');
  check(
    'seed: an element with no labeled ancestor group returns null',
    noLabelSeed === null,
    noLabelSeed ? JSON.stringify(noLabelSeed) : 'null',
  );
}

console.log(failures === 0 ? '\nAll tests passed.' : `\n${failures} test(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
