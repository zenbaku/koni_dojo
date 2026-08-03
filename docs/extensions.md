# Extensions

**Extensions** are installable content sources that a reader app pulls from
online sites, modeled on Mihon's extension system and repositories such as
[keiyoushi/extensions](https://github.com/keiyoushi/extensions).

Mihon extensions are Android APKs containing compiled Kotlin sources, which a
Dart/Flutter app cannot load. This engine instead uses **declarative
extensions**: each source is a JSON document describing the site's endpoints and
CSS selectors, interpreted at runtime by the scraping engine (`ConfigSource`).

Extensions install from a repository URL, or directly from a downloaded
`.json` file (Extensions → *Install from file*), handy for devices that
can't reach the machine serving an index: download or AirDrop the file
and pick it from the filesystem. Both paths accept the same formats: a
repository index or a single extension entry.

This repo is engine + tooling only: no curated source data lives here (see
the README's "Workspaces" section). A **workspace** (its own repo,
conventionally cloned as a sibling named `koni_dojo_repo`, but any name/
location works with `--workspace`) publishes its own index at
`repo/index.min.json`. That file is **generated**: the source
of truth is one readable config per extension under the workspace's
`extensions/`, assembled into the index by `dart run tool/build_repo.dart
--workspace <path>` (`task build-repo`), which validates every config
through the real engine first. Edit `extensions/<name>.json`, rebuild, and
you're done. Download the index and *Install from file*, serve it yourself,
or add the published raw URL as a repository directly.

A workspace may also keep a second, machine-generated index at
`repo/generated-index.min.json`: configs it produced in bulk rather than by
hand, held separately until each is live-verified. The engine reads both the
same way; `test/generated_index_test.dart` pins the generated index's
structural invariants, since nothing hand-reviews it.

[`docs/source-config.schema.json`](source-config.schema.json) is a JSON
Schema (draft 2020-12) covering this whole format, hand-maintained
alongside `lib/src/extension_models.dart` (the authoritative model) and this
doc, checked against every real `extensions/*.json` and cross-checked
against the playground's Form editor's known-field list
(`playground/test/config_form_test.dart`). Point an editor at it (a
`"$schema"` key in a config file, or your editor's schema-association
settings) for autocomplete and inline validation while hand-editing.

## Repositories

A repository is any URL serving a JSON index, the same concept as keiyoushi's
`index.min.json`, and the index entry shape is intentionally compatible
(`name`, `pkg`, `version`, `lang`, `nsfw`, `sources`). Add it in the app under
**Extensions → Add repository**. Entries whose `sources` carry no declarative
config (e.g. APK-only entries from a Mihon repo) are ignored.

```json
[
  {
    "name": "Example Source",
    "pkg": "app.konimanga.extension.en.example",
    "version": "1.0.0",
    "lang": "en",
    "nsfw": 0,
    "sources": [ { ...source config, see below... } ]
  }
]
```

A static file host is enough, e.g. a GitHub repo served through
`raw.githubusercontent.com`, exactly like keiyoushi does it.

## Source config format

```json
{
  "id": "example",
  "name": "Example",
  "lang": "en",
  "baseUrl": "https://example.com",
  "headers": { "Referer": "https://example.com/" },

  "popular": {
    "path": "/popular?page={page}",
    "itemSelector": "div.item",
    "titleSelector": "a.title",
    "urlSelector": "a.title",
    "urlAttr": "href",
    "coverSelector": "img",
    "coverAttr": "src",
    "nextPageSelector": "a.next"
  },

  "search": {
    "path": "/search?q={query}&page={page}",
    "itemSelector": "div.item",
    "titleSelector": "a.title"
  },

  "details": {
    "titleSelector": "h1.manga-title",
    "authorSelector": "span.author",
    "descriptionSelector": "p.summary",
    "coverSelector": "img.cover-img"
  },

  "chapters": {
    "itemSelector": "li.chapter",
    "nameSelector": "a",
    "urlSelector": "a",
    "urlAttr": "href",
    "dateSelector": "span.date",
    "reversed": true
  },

  "pages": {
    "imageSelector": "div.reader img",
    "imageAttr": "src"
  }
}
```

Notes:

- `{page}` and `{query}` placeholders are substituted into `path`.
- All scraped URLs (manga, covers, pages) may be relative or
  protocol-relative; they are resolved against `baseUrl`.
- For any `*Selector`/`*Attr` pair, an empty attr means "use the element's
  text" (the default for titles and chapter names).
- `chapters.reversed: true` (default) means the site lists newest chapters
  first; the engine flips them into reading order.
- `chapters.dateSelector` (optional, with `dateAttr`) reads a chapter's upload
  date; it's parsed leniently (ISO-8601 or epoch seconds/ms), so unparseable
  formats (relative strings like "2 days ago") just yield no date. Omit it to
  skip date parsing entirely.
- `chapters.lockedSelector` (optional) flags a chapter as locked behind
  payment (a "coin"/premium plugin) when this selector matches *something*
  inside the chapter item: a lock icon, a price badge, whatever the theme
  uses. It's a presence check, not a value read (the element itself is often
  empty, e.g. `<i class="fa-lock"></i>`), so don't set an attr for it. Locked
  chapters still appear in the list (correct chapter count, accurate "latest
  chapter"). The app is a content-neutral reader and never facilitates
  payment, so it shows them disabled rather than hiding or attempting to
  unlock them. Omit it for sources with no such concept.
- `chapters.officialSelector` (optional, with `officialAttr`/`officialValue`)
  flags a chapter as an official (licensed) translation rather than a fan
  scanlation: some sites upload a chapter as a fan translation first, then
  replace it in place with the official release once one exists, same
  chapter slot, different pages. Unlike `lockedSelector` this is a **value**
  check, not presence: `officialSelector` locates an element, `officialAttr`
  reads an attribute from it (empty reads text), and the chapter is flagged
  official when that value *contains* `officialValue`. Needed because some
  themes render the identical badge element for every chapter and only vary
  an attribute on it (confirmed live: one real source renders the same
  checkmark `<svg>` for every chapter, distinguishing official vs fan only
  by its `stroke` color): a presence-only check can't tell those apart.
  Omit `officialValue` for sources with no such concept.
- `pages.imageAttr` falls back to `data-src` for lazy-loaded readers.
- `search` is optional; sources without it simply return no search results.

## Advanced scraping

Fragment-driven sites (htmx and friends) usually need a few more tools; all
of the following are optional and compose with the basic format above. See
`test/fixtures/workspace/extensions/alpha.json` for a minimal starting point,
or a workspace's own curated `extensions/` for a complete config using
several of them together.

### Selector portability

Selectors are evaluated by Dart's `package:html`, not Jsoup, so selectors
lifted from Mihon extension source need care:

- A child combinator followed by a descendant combinator (`a > b c`)
  silently matches nothing. Prefer descendant-first shapes:
  `section[x-data] ul > li`, not `section[x-data] > section ul > li`.
- Jsoup treats `[attr~=x]` as a regex match; real CSS (and this engine)
  treats it as a whitespace-separated word match. Port it as a presence
  test (`[attr]`) or a different attribute selector.
- `:has()` and `:contains()` are not supported at all: that is what label
  rows (below) are for.

### Offset pagination

```json
"popular": {
  "path": "/search/data?limit=32&offset={offset}",
  "pageSize": 32
}
```

`{offset}` is replaced with `(page - 1) * pageSize`.

### Rate limiting

```json
"rateLimit": { "requests": 1, "perMs": 2000 }
```

Top-level; at most `requests` HTTP requests per `perMs` milliseconds to this
source, enforced for listings, details, chapters, pages **and** image
downloads.

### Query sanitization

```json
"search": {
  "queryReplace": { "pattern": "[!#:(),-]", "replace": " " }
}
```

Rewrites the raw query (regex `pattern` or literal `find`) before `{query}`
is substituted.

For a fixed vocabulary whose site-side browse value doesn't derive from its
display text by any rule at all, a `tag` value like a genre label ("Sci-fi")
that browses under an unrelated slug ("sf"), `queryMap` is a case-insensitive
exact-match lookup, checked before `queryReplace`:

```json
"tag": {
  "path": "/en/genres/{query}?sortOrder=MANA",
  "queryMap": { "Sci-fi": "sf", "Superhero": "super-hero", "Informative": "tiptoon" },
  "queryReplace": { "pattern": " ", "replace": "-" }
}
```

A query that isn't a `queryMap` key falls through to `queryReplace`/the raw
query unchanged, same precedent/shape as `details.statusMap`. Available
wherever `queryReplace` is (`popular`/`latest`/`search`/`tag`), though the
irregular-value problem it solves is really a `tag` (genre/label-browsing)
concern.

### Cover chains

```json
"cover": [
  { "selector": "source", "attr": "srcset",
    "replace": { "find": "small", "replace": "normal" } },
  { "selector": "img", "attr": "src" }
]
```

Tries each step in order; the first non-empty value (after the optional
`replace` rewrite) wins. Valid wherever `coverSelector`/`coverAttr` is;
those remain as shorthand for a one-step chain.

### Banner and background (details)

`details.bannerSelector`/`bannerAttr` (and the `banner` chain form, same
shape as `cover` above) capture a wide hero image distinct from `cover`:
some sites render both, a poster-shaped cover *and* a separate wide
character-art banner behind the title (confirmed live: one real source's
`og:image` meta tag is the cover, while a separate `<img>` deeper in the
page markup is the banner):

```json
"details": {
  "coverSelector": "meta[property='og:image']",
  "coverAttr": "content",
  "bannerSelector": ".header .thumb img"
}
```

`details.backgroundSelector`/`backgroundAttr` (and the `background` chain
form) capture a third, distinct image: a tiled backdrop meant to sit
*beneath* the banner, often a near-solid per-series mood color rather than
character art, a cleaner tint-color source than `banner` tends to be. A CSS
`background-image` doesn't live in a plain `src`/`href` attribute, so
extracting it needs `attr: "style"` plus a chain `rewrite` pulling the URL
out of the raw `url('...')` value; no dedicated engine support, the
existing chain `rewrite` (a regex `pattern`/`replace` with `$1`..`$9` group
refs, same as everywhere else) already does this:

```json
"details": {
  "background": [
    {
      "selector": "div.backdrop",
      "attr": "style",
      "replace": { "pattern": "^.*url\\('([^']+)'\\).*$", "replace": "$1" }
    }
  ]
}
```

No selector, or nothing matches, leaves `SourceManga.bannerUrl`/
`backgroundUrl` empty, not an error, most sources have neither image.

### Label rows (details)

Many sites present metadata as `<li><strong>Label:</strong> value</li>`
rows. Jsoup-based extensions target these with `:has(:contains())`
selectors, which our HTML engine cannot evaluate; declare the rows instead:

```json
"details": {
  "rows": {
    "itemSelector": "section ul > li",
    "labelSelector": "strong",
    "fields": {
      "author":      { "label": "Author", "valueSelector": "span > a", "join": ", " },
      "status":      { "label": "Status", "valueSelector": "a" },
      "genres":      { "label": ["Tag", "Type"], "valueSelector": "a" },
      "description": { "label": "Description", "valueSelector": "p" }
    }
  },
  "statusMap": { "complete": "completed", "canceled": "cancelled" }
}
```

A row binds to a field when its label text contains any of the field's
`label` strings (case-insensitive). Every `valueSelector` match in every
binding row contributes: `genres` collects a list, the other fields join
their matches with `join`. Values found here override the flat
`authorSelector`/`descriptionSelector` results. `statusMap` translates the
site's status text into one of `ongoing`, `completed`, `hiatus`,
`cancelled` (text that already equals one of those needs no map entry).

### Unlabeled genre/tag lists (details)

Some sites render tags as a bare list of links with nothing marking what
kind of row it is: no `"Tags:"` prefix to key a `rows` label match off of
(confirmed live: one real source renders `<a href="/tags/…">Model</a><a
href="/tags/…">Type</a>`, no label at all). For that shape, skip `rows` and
use `genreSelector` instead:
every matching element contributes one genre (its text, or `genreAttr`
when set):

```json
"details": {
  "genreSelector": "div.tags a"
}
```

### Chapters the site advertises but doesn't list (details)

Some sites hold back the newest chapters from the surface a config actually
scrapes, not gated per-chapter like `chapters.lockedSelector` (which flags a
chapter that *does* appear in the list), but chapters that never appear in the
list at all, only mentioned as a count elsewhere (confirmed live: one real
source's web listing tops out at 36 chapters with a "12 more episodes,
app-only" banner, when the real total is 48). `details.unlistedChaptersSelector`
(and optional `unlistedChaptersAttr`, empty = text) captures that count:

```json
"details": {
  "unlistedChaptersSelector": "div.app-promo strong em"
}
```

The matched text is parsed leniently: the first run of digits found, so
surrounding prose ("12 more episodes…") doesn't need to be stripped by the
selector. Absent selector, no match, or unparseable text all mean 0. Most
sources have no such concept.

`rows`' own `genres` field, when also configured and it matches, overrides
this.

### Derived request URLs

When the chapter list or page list lives at a URL computed from the stored
one rather than at the manga/chapter URL itself:

```json
"chapters": {
  "request": { "pattern": "^(.*/series/[^/]+)/.*$", "replace": "$1/full-chapter-list" }
},
"pages": {
  "request": { "suffix": "/images?reading_style=long_strip" }
}
```

`pattern`/`replace` is a regex rewrite (`$1`–`$9` reference groups; a
non-matching pattern leaves the URL unchanged), `suffix` is appended after.
A relative result is resolved against `baseUrl`.

### POST requests

Listings (`popular`/`latest`/`search`) and the `chapters`/`pages` `request`
block accept `"method": "POST"` for endpoints that only answer POST, e.g.
WordPress AJAX (`admin-ajax.php`) and Madara's `ajax/chapters/`:

```json
"popular": {
  "path": "/wp-admin/admin-ajax.php",
  "method": "POST",
  "body": "action=madara_load_more&page={page}&template=madara-core/content/content-archive",
  "headers": { "X-Requested-With": "XMLHttpRequest" },
  "itemSelector": "div.page-item-detail"
},
"chapters": {
  "request": { "suffix": "ajax/chapters/", "method": "POST" },
  "itemSelector": "li.wp-manga-chapter > a"
}
```

A listing `body` takes the same `{page}`/`{offset}`/`{query}` substitutions
as `path`; a `request` `body` expands `$1`–`$9` from its `pattern` match on
the source URL (so an id pulled from the URL can ride in the body). A
non-empty body defaults to `application/x-www-form-urlencoded`; `headers`
override or extend the source headers for that request only.

### Script-blob pages

Readers that emit page URLs inside a JavaScript blob rather than `<img>`
tags (MangaThemesia's `ts_reader.run({...})`, many Madara variants) declare
a `pages.script` instead of an `imageSelector`:

```json
"pages": {
  "script": {
    "pattern": "ts_reader.run\\((.*?)\\);",
    "itemsPath": "sources[0].images"
  }
}
```

`pattern`'s first capture group must yield JSON; `itemsPath` is a JSON path
(same grammar as API sources) to the image-URL list inside it (omit it when
the captured JSON is itself the list). An optional `template` renders each
element (`{value}` = the element). A blob that doesn't match or parse yields
no pages, exactly like a selector that finds nothing.

### Explicit step pipelines (`steps:`)

The sugar fields above each describe a *single* request whose response is one
format. When a site needs more (a cross-format hop, a second request keyed by a
value lifted from the first, an object-keyed list) any operation block
(`popular`, `latest`, `search`, `details`, `chapters`, `pages`, in either
dialect) may carry a `steps:` array that **overrides** the sugar fields for that
operation. Each step makes a request, parses the body in *its own* format, and
either **captures** scalars for later steps or **yields** the result:

```json
"pages": {
  "steps": [
    { "request": { "url": "{chapterUrl}" }, "parse": "html",
      "capture": { "id": { "selector": "#wrapper", "attr": "data-reading-id" } } },
    { "request": { "url": "{baseUrl}/ajax/image/list/{id}", "headers": { "X-Requested-With": "XMLHttpRequest" } },
      "parse": "json",
      "yield": { "list": { "path": "images" }, "value": { "template": "{url}" } } }
  ]
}
```

- `request`: `url` (templated over the threaded vars; relative resolves against
  the base/API URL), optional `method` (`GET`/`POST`), `body`, `headers`.
- `parse`: `html` (locators are `{selector, attr}`), `json` (`{path, template}`),
  or `regexJson` (lift `regex`'s first group, then read as JSON).
- `capture`: `{ name: locator }` scalars threaded into later steps as `{name}`.
- `decrypt` (instead of `request`): a compute step: `{ "data": "{var}", "password": "{var}" }`
  decrypts an already-captured `{"ct": "…", "iv": "…", "s": "…"}` envelope
  (CryptoJS's passphrase-mode `AES.encrypt` with an explicit-IV JSON formatter,
  a shape a few sites' "protect the page list" schemes ship, not tied to one
  plugin) with OpenSSL's `EVP_BytesToKey`/MD5 key derivation and AES-256-CBC. On
  an intermediate step the plaintext goes to `capture`; paired with `yield` on
  the terminal step, the plaintext stands in for a fetched body: `parse`/`regex`
  extract from it exactly as they would a real response (`parse: "json"`
  transparently unwraps a double-JSON-encoded root too, since some of these
  schemes `json_encode` their page list twice server-side). See the
  `jinmangas` writeup in `sources-catalog.md` for a full worked example.
- `yield` (terminal step): the operation's result. A **record list**
  (`{ list, fields: {…}, meta: {…} }`) for listings/chapters, a **flat list**
  (`{ list, value }`) for pages, or a **generate** shape
  (`{ count: {…}, value: { template }, start }`) for readers that report a page
  count and a `{n}`-templated URL with no per-page tags: the template renders
  for each index in `[start, start+count)` over the seed vars. A list locator
  with `"values": true` iterates a JSON object's *values* (object-keyed chapter
  maps). A locator may carry `"fallbacks": [...]` (first non-empty wins) and a
  `"rewrite"`, and `meta` reads document/root-level values such as a has-next
  flag (`{ "selector": "a.next", "exists": true }`).

Seed vars by operation: listings get `{baseUrl}` `{page}` `{offset}` `{query}`;
details/chapters get `{baseUrl}` `{mangaUrl}` (HTML) or `{url}` `{page}`
`{offset}` (API); pages get `{baseUrl}` `{chapterUrl}`/`{chapterId}` (HTML) or
`{url}` (API). API steps also get `{apiUrl}`. Declarative `filters` are not
applied in steps mode (template them into the steps instead). Full model and
the runner internals: `docs/source-pipeline-engine.md`.

### Latest listing

A `latest` block with the same shape as `popular` is accepted and carried
by the format. The engine does not surface it in the UI yet.

### Search filters

A top-level `filters` array declares filter groups (genres, status, …)
shown in the Browse filter sheet. Selected options are appended to the
**search** listing's URL as query parameters, so filters require a
`search` block, and the site must accept the filter parameters on its
search endpoint. `filters` (with or without `optionsFrom`) is for an
*enumerable* vocabulary small enough to present as a checklist: a curated
genre taxonomy, a handful of statuses. For a tag space too large or
open-ended to enumerate up front (one tag per model or uploader, not a
fixed set of ~40 genres), see `tag` below instead.

```json
"filters": [
  {
    "id": "genres",
    "name": "Genres",
    "param": "genre",
    "excludeParam": "genre_exclude",
    "options": [
      { "value": "horror", "label": "Horror" },
      { "value": "romance", "label": "Romance" }
    ]
  },
  {
    "id": "status",
    "name": "Status",
    "param": "status",
    "join": ",",
    "options": [
      { "value": "ongoing", "label": "Ongoing" },
      { "value": "completed", "label": "Completed" }
    ]
  }
]
```

- `param`: query parameter carrying *included* options.
- `excludeParam`: optional; when present the UI offers a third, excluded
  state per option (off → include → exclude) and sends those values under
  this parameter.
- `join`: how multiple values serialize: omitted/empty repeats the
  parameter (`?genre=a&genre=b`), any other string joins them into one
  value (`?status=ongoing,completed`).
- Filters combine freely with the text query; the query may be empty when
  only filters are set.

Instead of (or in addition to) a static `options` list, a filter can
discover its options from the site at runtime with `optionsFrom`; the
list is scraped once per session, and static `options` serve as the
fallback when the fetch fails:

```json
{
  "id": "genres", "name": "Genres", "param": "genre",
  "optionsFrom": {
    "path": "/advanced-search",
    "itemSelector": "select.genres option",
    "valueAttr": "value",
    "labelSelector": ""
  }
}
```

`valueAttr` (default `value`) reads the option's value off the matched
element; the label comes from `labelSelector`/`labelAttr`, defaulting to
the element's text. Discovered options are sorted by label.

### Tag browsing

A `tag` block, same shape as `popular`/`search`, is an exact-match listing
for one or more already-known tag values, e.g. an entry out of a manga's
own `details.genres` (populated by `genreSelector`; extraction and
browsing are named differently on purpose: a manga's descriptive tags
are its `genres`, but *browsing by* one of them is a `tag` lookup), tapped
to browse everything else carrying it. Unlike `filters`, there's no
option list to enumerate up front: the tag value the app already has in
hand is substituted straight into `{query}`.

```json
"tag": {
  "path": "/tags/{query}?page={page}",
  "itemSelector": "#main > div.grid > div",
  "titleSelector": "h2",
  "urlSelector": ".relative a",
  "urlAttr": "href",
  "coverSelector": ".relative img",
  "nextPageSelector": "a[rel=next]"
}
```

The one difference from `search`: `{query}` here is escaped for a URL
*path* segment (`%20` for spaces), not a query string (`+` for spaces);
`tag.path` typically puts the tag in the path itself (`/tags/{query}`),
where `search.path` puts the free-text query in a query parameter
(`?kw={query}`). If the site's own tag links use different percent-encoding
for special characters than Dart's `Uri.encodeComponent` produces (parens
are a real example: some routers normalize this transparently, some
don't), verify a tag with punctuation actually resolves before shipping;
don't assume text round-trips through re-encoding unchanged.

By default a `tag` listing only browses **one** tag at a time (the value
substituted into `{query}`) and can't exclude anything. A source whose
own endpoint supports more declares it with `tagParam`/`tagExcludeParam`,
the same query-parameter-plus-join shape `filters` already uses:

```json
"tag": {
  "path": "/browse?page={page}",
  "tagParam": "tag",
  "tagExcludeParam": "exclude",
  "tagJoin": "",
  "itemSelector": "div.item",
  ...
}
```

`tagParam`, when set, carries *every* included tag (not just the extras
beyond the one already in `{query}`: a source using this typically
doesn't also rely on `{query}` in `path` for the primary tag; `path` would
just be a fixed listing URL with no tag in it at all). `tagExcludeParam`
carries excluded tags the same way. `tagJoin` follows `FilterConfig.join`:
empty repeats the parameter (`?tag=a&tag=b`), any other string joins
values into one (`?tag=a,b`).

The caller never has to guess what a source supports: whether `tagParam`/
`tagExcludeParam` are set *is* the capability declaration (`TagCapabilities.multiple`/
`.exclusion` in the engine, `Source.tagCapabilities`), nothing to
separately keep in sync. A source that only browses one tag at a time
just leaves them unset; passing more than one included tag, or any
excluded tag, then has no effect rather than erroring.

`filters`/`search`/`tag` all reach for the same problem, narrowing what's
browsed, at three different vocabulary sizes: a handful of fixed choices,
free text, and everything in between. Pick whichever matches what the site
actually exposes.

## API sources (`"type": "api"`)

Sites that expose a JSON API instead of scrapeable HTML use the API
dialect: the same declarative idea with JSON paths and templates where the
HTML dialect has CSS selectors. A fully-worked fictional reference example
lives at `test/fixtures/workspace/extensions/delta.json`, an ordinary
repository extension like every other source.

```json
{
  "type": "api",
  "id": "example", "name": "Example", "lang": "en",
  "baseUrl": "https://example.org",
  "apiUrl": "https://api.example.org",
  "manga": {
    "url": "id",
    "title": {"paths": ["attributes.title.{lang}", "attributes.title.*"], "default": "Untitled"},
    "author": "relationships[type=author].attributes.name",
    "cover": {"path": "coverFile", "template": "https://cdn.example.org/{id}/{value}.jpg"},
    "genres": {"items": "attributes.tags", "value": "name"}
  },
  "popular": {"path": "/manga?limit=20&offset={offset}", "pageSize": 20, "items": "data", "totalPath": "total"},
  "search": {"path": "/manga?limit=20&offset={offset}&title={query}", "pageSize": 20, "items": "data", "totalPath": "total"},
  "details": {"path": "/manga/{url}", "item": "data"},
  "chapters": {
    "path": "/manga/{url}/feed?limit=100&offset={offset}",
    "pageSize": 100, "items": "data", "totalPath": "total",
    "chapter": {
      "url": "id", "number": "attributes.chapter", "skipIf": "attributes.externalUrl",
      "date": "attributes.publishAt",
      "name": {"parts": [{"path": "attributes.chapter", "template": "Ch. {value}"}, {"path": "attributes.title"}], "join": " ", "default": "Oneshot"}
    }
  },
  "pages": {"path": "/pages/{url}", "items": "chapter.data", "template": "{baseUrl}/{chapter.hash}/{value}"}
}
```

The pieces:

- **JSON paths** address response values: dotted keys
  (`attributes.title.en`), list indexes (`data[0]`), first-match list
  filters (`relationships[type=author]`) and `*` for "first value"
  (language fallbacks). Misses resolve to null, like a non-matching CSS
  selector.
- **Value specs** are a path (string shorthand), or an object with
  `paths` (first non-empty hit wins), an optional `template` (`{value}` is
  the hit; other placeholders resolve as paths against the item, then the
  response root) and a `default`.
- **Listings** (`popular`, `search`) substitute `{page}`, `{offset}`,
  `{query}` and `{lang}` into `path`; `items` locates the result array,
  `totalPath` a total count for pagination (defaulting to "the page was
  full"). Query parameters left empty by substitution are dropped, so a
  filters-only search doesn't send `title=`.
- **Chapters** fetch the feed page by page until `totalPath` is reached
  (`maxItems`, default 1000, caps runaway feeds); `skipIf` drops items
  with a value at that path. The chapter `name` can be assembled from
  `parts`, skipping the ones that are missing. The optional `date` value
  spec reads the upload date (ISO-8601 or epoch), shown on chapter rows.
  The optional `locked` path flags a chapter as gated behind payment (a
  "coin"/premium API, common on heancms-style sites): read "truthy" in a
  JS-like sense, so it covers both a boolean flag (`"premium": true`) and a
  price field (`"price": 99` locked / `"price": 0` free) with the same
  mechanism. Unlike `skipIf`, a locked chapter still appears in the list,
  disabled, not hidden or dropped. The optional `official` path flags a
  chapter as an official (licensed) translation rather than a fan
  scanlation, read "truthy" the same way `locked` is.
- **Pages** render each element of `items` through `template`: `{value}`
  is the element itself, and any other `{placeholder}` resolves as a JSON
  path against the element first, then the response root, so page objects
  like `{"url": "…", "order": 1}` use `"template": "{url}"`. A placeholder
  that cannot be resolved fails the fetch (malformed response) instead of
  producing broken URLs.
- **Filters** work exactly as in the HTML dialect (same `param` /
  `excludeParam` / `join`), with the JSON flavor of `optionsFrom`
  (`items` + `value`/`label` specs) plus optional `groupBy` to split
  discovered options into several groups, e.g. a taxonomy split into
  genre/theme/format/content tag groups:

```json
"optionsFrom": {
  "path": "/titles/tags", "items": "data",
  "value": "id", "label": {"paths": ["attributes.name.en", "attributes.name.*"]},
  "groupBy": {"path": "attributes.group", "names": {"genre": "Genres"}, "order": ["genre"]}
}
```

Repositories can ship API-dialect sources like any other entry; the
`type` field selects the engine.

## No built-in sources

The engine bundles nothing. It has no source list, no default repository,
and no network activity of its own: it reaches a site only when a host
passes it a config that points there, and that config arrives because
someone installed it. A host built on this package starts with zero sources
until a repository URL is added. Every source, including API-dialect ones,
is an ordinary config on the same engine — there is no privileged or
built-in kind.

## Web targets

Browsers block cross-origin HTML, so HTML-dialect sources can't be scraped
directly from a web build: they need the host's `http.Client` to route
through a relay (see the seams list in the README). API-dialect sources
work without one when the API sends CORS headers. Nothing else about the
engine differs on web — parsing moves off-isolate via
`lib/src/parse_isolate_web.dart`, which is transparent to a config.
