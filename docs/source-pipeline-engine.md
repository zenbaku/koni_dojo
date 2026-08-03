# Design: a pipeline (step) engine for declarative sources

> Status: **implemented.** Every operation of both engines runs through the
> pipeline runner (`lib/src/pipeline.dart`), and configs accept an explicit
> per-operation `steps:` pipeline — the shipping format, documented in
> `docs/extensions.md`. This document is kept as the rationale and spec: why
> the engine is shaped this way, what the alternatives were, and which
> trade-offs were taken deliberately. The migration plan and open questions
> below are preserved as authored, so the reasoning stays legible; a few
> details (exact field names, phase ordering) were settled differently in the
> final code.

Companion to `docs/extensions.md`, which documents the config format as it
actually ships.

## As built

*Every* operation of *both* engines runs through the pipeline runner
(`lib/src/pipeline.dart`), and configs accept an explicit per-operation
`steps:` pipeline.

- **HTML (`ConfigSource`)**: pages/chapters/popular/search route through
  `runFlatListPipeline`/`runRecordListPipeline` (records: `{field: value}` maps,
  plus document-level `meta` for has-next; cover chains travel as a `Locator`
  fallback chain). Details route through `runBodyPipeline` (terminal body, parsed
  inline) because label-rows need the whole document and browsing parses on the
  calling isolate by design. The old `_extractChapters`/two-phase fetch and the
  per-item listing extraction are deleted.
- **JSON (`ApiSource`)**: all four operations fetch through `runJsonPipeline`
  (walk steps + capture, decode the terminal root off-isolate); the engine's
  richer evaluators (`JsonValueSpec`/`JsonNameSpec`/`JsonListSpec`) still read
  that root, since a flat string-record would lose multi-part names, genres lists
  and defaults. So the API engine gains step orchestration without changing its
  field model.

What stays in each adapter is *not* extraction: filter-param building, pagination
framing (`hasNext`/`totalPath`), query sanitization, the API chapters page loop,
the pages "malformed response" throw, label-rows + status mapping. Both engines
are now request-build → run pipeline → map records/evaluate-root.

Each per-op config block (HTML and API) carries an optional `steps: Pipeline?`
(parsed + round-tripped, validated at load by `generated_index_test`); the
engines prefer it over the desugarer (`config.pages.steps ?? pagesPipeline(...)`,
and `ApiSource._root(steps, fallbackUrl, vars)`). Object-keyed JSON lists work
via `Locator.values`. Cross-format (`HTML → capture id → JSON ajax`) and
cross-request JSON (`capture → request`) hops are proven in `test/pipeline_test.dart`,
and the loader+engine paths end-to-end in `config_source_test`/`api_dialect_test`.

**Runner output shapes are complete**, including the count-generate page
yield (shape (c): `count` + a `{n}`/vars template, readers that give a page
count and a URL template, no per-page tags; the flat-list extractor threads the
pipeline vars). All three `yield` shapes from the model are implemented.

Three design leans confirmed in the build: today's field shapes stay permanent
sugar (the desugarers); `ScriptPagesConfig` maps onto `parse: regexJson`; the
per-step locators reuse the CSS/JSON value structs.

## Why

The declarative source engine was designed for two clean shapes:

- **Pure HTML scraping** with fixed URLs (the common case): each operation is
  one request → parse HTML → pull values out with CSS selectors.
- **Pure JSON API** (a JSON:API-style source): each operation is one request
  → parse JSON → pull values out with JSON paths.

`ConfigSource` and `ApiSource` are two separate engines, each locked to one
response format for an operation's whole lifecycle. That covered the first
sources and most of the two dominant themes (Madara, MangaThemesia).

The remaining clusters don't fit, because **they hop**: fetch a bit of one
thing, pull a token out, fetch a second thing in a *different* format, pull the
real answer out of that. We have already been bolting these hops on as
special-case config fields, one site shape at a time:

| Bolt-on field | What it really is |
|---|---|
| `RequestTransform.body` / `method` | a request that is a POST, not a GET |
| `RequestTransform.idSelector`/`idAttr` + `url` | "fetch page, capture an id, then fetch a second URL with it": a **two-step pipeline**, hand-coded |
| `PagesConfig.script` / `ScriptPagesConfig` | "parse this response as regex→JSON instead of HTML": a **per-step format switch**, hand-coded |
| `ApiPagesConfig.template` per-item | field extraction off each element |

Every one of these is a fragment of a workflow encoded as a bespoke field.
That is the "accidentally building an interpreter, one special case at a time"
smell. The clusters still blocked are exactly the ones that need *more* hops or
a *format switch mid-hop*, and continuing to add fields (`count`, `seriesId`,
`valuesMode`, …) makes the format wider and muddier without ever naming the
thing underneath.

The thing underneath is: **an operation is a short, linear pipeline of steps,
each of which makes a request, parses the response in some format, and either
captures a value for a later step or yields the result.** Name that explicitly
and the bolt-ons collapse into it.

## What this is *not*

Not a general state machine. These sources need **no branching, no loops, no
conditionals**: just an ordered sequence that threads captured variables
forward. Keeping it linear and total is the whole point: a step-list you can
read top to bottom, statically validate, and debug by dumping the vars between
steps. A Turing-complete DSL would be unauthorable and is unnecessary.

## The model

An **operation** (`popular`, `latest`, `search`, `details`, `chapters`,
`pages`) is a `Pipeline`: an ordered `steps: [...]`. Execution threads a
**vars** map forward; the engine seeds it per operation:

| Operation | Seed vars |
|---|---|
| popular / latest / search | `{baseUrl}` `{page}` `{offset}` `{query}` + filter params |
| details / chapters | `{baseUrl}` `{mangaUrl}` `{mangaId}` (if known) |
| pages | `{baseUrl}` `{chapterUrl}` `{chapterId}` |

A **step**:

```jsonc
{
  // 1. REQUEST: where to fetch. Templated over the current vars.
  "request": {
    "url":     "{baseUrl}/ajax/image/list/{id}",  // relative resolves against baseUrl/apiUrl
    "method":  "GET",                              // GET | POST
    "body":    "action=get&manga={id}",            // templated; sent when present
    "headers": { "X-Requested-With": "XMLHttpRequest" }
  },

  // 2. PARSE: how to read the response body for THIS step.
  "parse": "html",          // html | json | regexJson
  "regex": "ts_reader\\.run\\((\\{.*?\\})\\);",   // when parse=regexJson: group 1 → JSON, then read as json

  // 3a. CAPTURE: scalars threaded to later steps (intermediate steps).
  "capture": {
    "id": { "selector": "#manga-chapters-holder", "attr": "data-id" }   // html: selector/attr
    // json: { "path": "data.id" }
  },

  // 3b. YIELD: present on the LAST step only; produces the operation's result.
  "yield": { /* see below */ }
}
```

`capture` and `yield` are format-polymorphic: under `parse: html` a locator is
`{selector, attr}`; under `parse: json`/`regexJson` it is `{path, template}`
(the existing `JsonValueSpec`). The step's `parse` decides which is meaningful:
that is the entire mechanism for "HTML then JSON," with no engine seam between
the two dialects.

`yield` has three shapes, which is where the blocked clusters land:

```jsonc
// (a) EXTRACT a list: listings, chapters (item objects with fields)
"yield": {
  "list":   { "selector": ".chapter li" },          // json: { "path": "chapters" }
  "fields": { "url":  { "selector": "a", "attr": "href" },
              "name": { "selector": "a" },
              "cover":{ "selector": "img", "attr": "src" } }
}

// (b) EXTRACT a flat list of strings: pages from <img>/script/json
"yield": { "list": { "selector": "img.page" }, "value": { "attr": "src" } }

// (c) GENERATE from a count: readers that give count + URL template, no per-page tags
"yield": { "count": { "selector": "#reader", "attr": "data-pages" },
           "template": "{baseUrl}/ch/{chapterId}/{n}.jpg", "start": 1 }
```

Object-keyed lists (chapters as `{"1":{…},"2":{…}}`) are a flag on the locator:
`"list": { "path": "chapters", "values": true }` iterates the map's values.

So the four currently-blocked clusters are not four features: they are
`parse: json` on a later step (mangareader/zeist), `yield` shape (c)
(synthesized count), a second `capture` threaded into a later request (multi-id
API), and `list.values` (object-keyed). They become **compositions of existing
primitives**, mostly needing zero new engine code per source.

## Worked examples

**HTML-dialect pages (today, one step):**
```jsonc
"pages": { "steps": [
  { "request": { "url": "{chapterUrl}" }, "parse": "html",
    "yield": { "list": { "selector": "img.page" }, "value": { "attr": "src" } } }
]}
```

**JSON-API pages (today, one step):**
```jsonc
"pages": { "steps": [
  { "request": { "url": "{baseUrl}/pages/{chapterId}" }, "parse": "json",
    "yield": { "list": { "path": "chapter.data" },
               "value": { "template": "{root.baseUrl}/data/{root.chapter.hash}/{value}" } } }
]}
```

**Madara legacy chapters (today's two-phase id lookup, two steps):**
```jsonc
"chapters": { "steps": [
  { "request": { "url": "{mangaUrl}" }, "parse": "html",
    "capture": { "id": { "selector": "#manga-chapters-holder", "attr": "data-id" } } },
  { "request": { "url": "{baseUrl}/wp-admin/admin-ajax.php", "method": "POST",
                 "body": "action=manga_get_chapters&manga={id}" }, "parse": "html",
    "yield": { "list": { "selector": "li.wp-manga-chapter" },
               "fields": { "url": { "selector": "a", "attr": "href" }, "name": { "selector": "a" } } } }
]}
```

**mangareader (the blocked case: same two steps, step 2 is JSON):**
```jsonc
"pages": { "steps": [
  { "request": { "url": "{chapterUrl}" }, "parse": "html",
    "capture": { "id": { "selector": "#wrapper", "attr": "data-reading-id" } } },
  { "request": { "url": "{baseUrl}/ajax/image/list/chapter/{id}", "headers": { "X-Requested-With": "XMLHttpRequest" } },
    "parse": "json",
    "yield": { "list": { "path": "images" }, "value": { "template": "{url}" } } }
]}
```
The only difference from Madara is `parse: "json"` on step 2. The
"cross-format two-phase" gap I previously called invasive (Option A) **does not
exist in this model**: it was an artifact of having two engines.

## Desugaring: today's configs are a strict subset

The migration is safe because every current field maps mechanically onto the
pipeline. The existing JSON shapes stay valid and are read as **sugar** that the
loader expands into a 1- or 2-step pipeline:

| Current config | Desugars to |
|---|---|
| `popular/latest/search: ListingConfig` | one step: `request{path,method,body,headers}` · `parse: html` · `yield.list = itemSelector`, `fields = {title,url,cover}` from the `*Selector/*Attr` (+ `cover` chain) |
| `details: DetailsConfig` | one step: `parse: html` · `capture/yield` of title/author/desc/cover + `rows` |
| `chapters: ChaptersConfig` (no `request`) | one step on `{mangaUrl}` · `yield.list = itemSelector`, fields name/url/date |
| `chapters` with `request.idSelector` | **two** steps: step 1 `capture.id`, step 2 POST/GET `request` → yield |
| `pages: PagesConfig.imageSelector` | one step · `yield.list = imageSelector`, `value.attr = imageAttr` |
| `pages.script: ScriptPagesConfig` | one step · `parse: regexJson` (regex = `pattern`) · `yield.list = itemsPath`, `value.template` |
| `pages.request` (two-phase) | step 1 captures, step 2 yields |
| API `ApiListingConfig` / `ApiChaptersConfig` / `ApiPagesConfig` | one step · `parse: json` · paths→`list`/`fields`, `template`→`value.template` |

`AnySourceConfig.fromJson` keeps accepting both `SourceConfig` and
`ApiSourceConfig`; internally both build a `Pipeline` per operation. A source
that needs more than the sugar expresses sets `"steps": [...]` explicitly on
that one operation. Every existing curated config changes **not at all** on
disk.

## Migration plan (strangler, test-gated)

The existing suites are the safety net; the refactor is behaviour-preserving
iff they stay green: `test/config_source_test.dart`,
`test/api_dialect_test.dart`, `test/json_path_test.dart`, and
`test/generated_index_test.dart` (524 configs parse + round-trip).

1. **Interpreter, dormant.** Add `Pipeline`/`Step`/`StepResult` types and a
   `PipelineRunner` (request → parse → capture/yield) alongside the current
   engines. No wiring yet. Unit-tested in isolation against canned responses.
2. **Desugarers.** `SourceConfig`/`ApiSourceConfig` gain `pipelineFor(op)` that
   builds a `Pipeline` from today's fields (the table above). Pure, unit-tested.
3. **Route one operation through it** behind both engines, e.g. `fetchPages`,
   delegating to `PipelineRunner(pipelineFor('pages'))`. Run the full suite. If
   green, the desugaring is faithful for that operation.
4. **Route the rest** (popular/search/details/chapters) one at a time, suite
   green at each step. When all operations route through the runner, the old
   per-operation extraction code in `ConfigSource`/`ApiSource` is dead and
   deleted; the two classes become thin adapters (config → pipeline → runner).
5. **Explicit `steps:`** accepted in the loader as an escape hatch, with its own
   tests. Now the blocked clusters are authorable.
6. **Re-run the blocked clusters** through whatever bulk-conversion tooling
   a given collection uses, validate the output through the engine,
   live-probe representatives, and append to that collection's generated
   index. (That tooling is a collection concern and lives with the data, not
   in this repo.)

Each phase is independently revertable and leaves the app shippable.

## The de-risking spike (proposed first deliverable)

Before committing to the full migration, prove the model end-to-end on the
easy *and* the hard case with zero regressions:

- Build the interpreter (phase 1) + the `pages` desugarer (phase 2) + route
  `fetchPages` through it (phase 3).
- **Acceptance A:** the existing 500+ tests stay green: proves old configs are
  a faithful subset.
- **Acceptance B:** hand-author one explicit `steps:` pipeline for mangareader
  (HTML → capture id → JSON ajax) and live-probe it to real pages: proves the
  general form unblocks a real cluster.

If both hold, the rest is mechanical follow-through. If either doesn't, we've
spent a spike, not a rewrite.

## Risks & mitigations

- **Touches the most load-bearing code.** → Strangler + the four suites as the
  net; behaviour-preserving by construction, revertable per phase.
- **Authoring ergonomics**: a raw step-list is more abstract than
  `popular.itemSelector`. → Keep the sugar as the front door for the simple 95%;
  `steps:` is an escape hatch only hard sources reach for. Authors and the
  conversion agents keep writing the shapes they already write.
- **Config-format churn for 524 entries.** → None: they are sugar and stay
  byte-for-byte valid; `generated_index_test` proves it.
- **Scope creep into a general DSL.** → Linear only. No control flow. If a
  source needs branching/looping it is out of scope (see below).

## Non-goals / out of scope

The pipeline does **not** rescue sources that aren't declaratively expressible
at all: client-side-rendered/obfuscated JS readers, login/DRM/paywalls,
binary/protobuf APIs, and self-hosted sources whose base URL the user must
configure. These stay skipped regardless of engine. The pipeline's payoff is
the hop/format-switch sources **and** ending the special-case accretion, not
chasing every candidate.

"Client-side image decryption" was listed here too until `jinmangas`
(2026-07-10): that source's page list is AES-encrypted, and the initial
reflex was the same as an obfuscated JS reader: needs a real JS
engine running the site's own code, out of scope. Turned out narrower on
inspection: the site's own JS was reverse-engineered (executed for real in
Node/jsdom with `CryptoJS.AES.decrypt` hooked to capture its actual
arguments, not guessed), and the scheme is one well-defined, parameterized
crypto primitive (OpenSSL `EVP_BytesToKey`/MD5 + AES-256-CBC over an
explicit `{ct,iv,s}` envelope), not arbitrary site JS. That's declaratively
expressible (two template inputs, one deterministic operation), so it's a
`decrypt` step (`docs/extensions.md`), not a carve-out for a JS runtime. The
non-goal still stands for genuinely *arbitrary* client-side crypto/obfuscation
that isn't reducible to a named, parameterizable algorithm: the bar is
"can this be one declarative primitive," same as everything else on this
page.

## Open questions (for review)

1. ~~**Spike vs. full plan now**~~: *resolved: the spike ran, proved the
   model, and the full migration followed — see "As built" above.*
2. **Sugar permanence**: keep the current field shapes as first-class sugar
   indefinitely (recommended; bulk converters emit them), or treat them as
   transitional and eventually rewrite existing configs into explicit
   pipelines?
3. **`parse: regexJson` naming**: fold today's `ScriptPagesConfig` regex step
   under a general `parse: regexJson` + `regex`, or keep a distinct `script`
   verb? (Leaning: fold it, one fewer concept.)
4. **Where field extraction lives**: reuse `JsonValueSpec`/CSS-selector structs
   as the per-step locator types verbatim (less new surface), or introduce a
   unified `Locator` type the doc sketches? (Leaning: reuse what exists.)
