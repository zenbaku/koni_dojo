# Proposal: a declarative JS step

A design sketch for adding a JavaScript-execution step to the declarative
pipeline: the single feature that would let the engine absorb the class of
sources currently forced to be imperative because they mint a request/reader
token by running the site's own JS. A fictional site ("Zeta", see
`lib/src/imperative_sources.dart`'s doc) needing exactly that shape is the
worked example.

> Status: **implemented.** The JS step and its supporting primitives ship in
> `lib/src/pipeline.dart`; the trust gate is enforced in `tool/build_repo.dart`;
> the QuickJS runtime is wired in the app (`ExtensionManager`) and the
> playground (`flutter_js`). A source needing this shape ports from an
> imperative Dart source to a `js`-step config the same way the worked
> example below does, and the reader flow is proven end-to-end in
> `test/js_step_test.dart`. This document is kept as the rationale/spec; a
> few details below (e.g. exact field names) match the final code.

## The gap

The declarative engine has no way to run code. A `Step` fetches, parses
(`html` / `json` / `regexJson`), and extracts values by CSS selector or JSON
path (`Locator`); `extractCaptures` never evaluates anything (pipeline.dart).
That is deliberate and covers ~85 sources. But a handful of sites gate their
reader behind a JavaScript challenge: the server ships a snippet, the page runs
it (seeded with a per-load secret) to compute an `answer`, and the `answer`
buys a token that every page image URL then carries. There is no selector or
path that yields the `answer`: it only exists after the code runs. This is
the "JS-signed request token" wall: the only fix is running the site's own
JS.

The seam already exists: `JsRunner` (`lib/src/js_runner.dart`),
`Future<String> eval(String code)`, is injected by the app (flutter_js /
QuickJS) exactly like `http.Client` and `ClearanceStore`. Today only imperative
sources reach it. This proposal threads it into the pipeline.

## Principle: JS is just another capability that captures a var

A JS step does not add control flow. It fits the existing model exactly: like a
request step captures scalars from a response into the threaded `vars`, a JS
step captures the result of an evaluation into the threaded `vars`. Everything
downstream (`{answer}` in a later request body, `{token}` in a generated image
URL) is the machinery that already exists.

## Schema

A new optional `js` block on a `Step` (mutually exclusive with `request` on that
step: a JS step computes, it doesn't fetch):

```jsonc
{
  "js": {
    // Wrapper code. Runs in the JsRunner; its last expression is the result.
    // `$` is a bound object holding the resolved `args` below (JSON-injected,
    // never string-spliced: no structural injection). Site-supplied code is
    // run only where the author explicitly writes eval($.something).
    "code": "…; eval($.challengeJs)",

    // Named inputs. Each value is a normal {var} template resolved from the
    // threaded vars, then the whole map is JSON-encoded and exposed as `$`.
    "args": { "k2codes": "{k2codes}", "challengeJs": "{challengeJs}" },

    // Capture the string result into one var …
    "capture": "answer"

    // … or, when the result is a JSON object, capture several by path:
    // "captureJson": { "token": "token", "chapterId": "chapterId" }
  }
}
```

## Semantics

- **Resolution.** `args` values are `{var}`-substituted from the current
  threaded vars (same `_subst` the request path uses), the map is JSON-encoded,
  and the engine prepends `const $ = <that JSON>;\n` to `code`. So data crosses
  the boundary as data: a captured blob that contains `{`, quotes, or newlines
  can't break out of a string or inject structure.
- **Running site code** is opt-in and visible: the author writes
  `eval($.challengeJs)`. There is no implicit code splicing.
- **Result → capture.** `JsRunner.eval` returns the last expression as a
  string. `capture` stores it in one var; `captureJson` JSON-parses it and
  applies a path per var (reusing `readJsonPath`).
- **Isolate.** The step runs on the calling isolate, exactly where `fetch`
  already runs (`_runPipeline` only offloads `runParse`). flutter_js needn't be
  isolate-safe.
- **No runtime.** When the injected `JsRunner` is null (web, tests, or an app
  build without a JS runtime) a JS step throws a typed `JsUnavailable`, the
  same "surface a clear error instead of half-working" contract every
  imperative source needing a JS runtime already follows.
- **Trace.** The step emits a `StepTrace` like any other: no `requestUrl`, the
  captured var(s), and a **redacted** body preview (the code + a truncated
  result, never the raw args, which may hold secrets). The playground renders
  it in the step trace unchanged.

## Trust: this is a real escalation, gate it

A declarative config that runs `eval(remote JS)` is running untrusted remote
code: a genuine step up from "pull strings out of HTML." Mitigations are
structural, not incidental:

- **Sandbox.** QuickJS via flutter_js has no DOM, no network, no filesystem:
  only compute. The challenge JS can't exfiltrate or fetch.
- **Data boundary.** `args` are JSON-injected; site code runs only through an
  explicit `eval`.
- **Capability flag + tier gate.** Mirror `webview: true`: a source must opt in
  with `js: true`, and the engine only honours a `js` step for **curated-repo**
  sources (`extensions/*.json`), never for the bulk machine-converted dormant
  tier (`generated-index.min.json`). `tool/build_repo.dart` rejects a `js` step
  in a non-curated entry at build time.
- **Budget.** A per-op eval count + wall-clock cap, so a pathological snippet
  can't hang the reader.

## Worked example: a JS-gated reader's `pages()` becomes declarative

A representative six-request imperative flow (a series page hands out an
obfuscated seed value, a JS challenge derives an answer from it, the answer
buys a reader token, and the token signs every page image URL) maps to one
`steps:` pipeline. The **only** new engine primitive load-bearing here is the JS
step (steps marked ★); the two small helpers (⁑) are noted in the next section.

```jsonc
"pages": {
  "steps": [
    // 0 ⁑ series page → capture the obfuscated seed value by regex
    { "request": { "url": "/series.php?id={seriesId}" },
      "capture": {
        "seed": { "regex": "seed['\"]?\\]?\\.value\\s*=\\s*String\\.fromCharCode\\(([\\d,\\s]+)\\)" }
      } },

    // 1  challenge JSON → challengeJs + challengeId
    { "request": { "url": "/ajax/get_challenge.php?chapter={chapterId}&s={seriesId}",
                   "headers": { "X-Requested-With": "XMLHttpRequest" } },
      "parse": "json",
      "capture": { "challengeJs": { "path": "challenge_js" },
                   "challengeId": { "path": "challenge_id" } } },

    // 2 ★ run the challenge in the sandbox → answer
    { "js": {
        "code": "var window={};var document={getElementById:function(){return {elements:{seed:{value:String.fromCharCode.apply(null,$.seed.split(',').map(Number))}}}};};eval($.challengeJs)",
        "args": { "seed": "{seed}", "challengeJs": "{challengeJs}" },
        "capture": "answer" } },

    // 3  POST answer → reader token
    { "request": { "url": "/ajax/get_reader_token.php", "method": "POST",
                   "body": "chapter={chapterId}&challenge_id={challengeId}&answer={answer}",
                   "headers": { "X-Requested-With": "XMLHttpRequest" } },
      "parse": "json",
      "capture": { "token": { "path": "token", "encode": true },
                   "realChapter": { "path": "chapterId" } } },

    // 4 ⁑ open reader, read totalPages by regex, generate the image URLs
    { "request": { "url": "/reader_v2.php?chapter={realChapter}&token={token}&page=1" },
      "yield": {
        "count": { "regex": "totalPages:\\s*(\\d+)" },
        "value": { "template": "{baseUrl}/image-proxy-v2.php?chapter={realChapter}&page={n}&token={token}&context=reader" } } }
  ]
}
```

Everything except step 2 is already expressible: the capture-threading
(`challengeJs`/`challengeId`/`answer`/`token`/`realChapter`), the POST body
template, `encode` on the token, and the `count`→`value.template` **generate**
shape that renders `{realChapter}`/`{token}`/`{n}` per page
(`_generatePages`, `lib/src/pipeline.dart`). They only fail today because
`answer` can't be produced, which step 2 fixes.

An imperative `chapterId`/`seriesId` split of `ref.url` on `#` becomes two
`regex` captures off `chapterUrl`; a `total <= 0` inline-`<img>` fallback is
a conditional the single-pass pipeline doesn't model: a non-blocking edge
(drop it, or add a `fallbackYield`).

## Two small helpers this leans on (independent of the JS step)

1. **Regex scalar capture**: a `Locator` with a `regex` field that yields
   capture group 1 (against the body, or a var via `from`). Covers `k2codes`,
   `total`, and the `#`-split. Small, broadly useful, no JS.
2. **`count` by regex under `html` parse**: today `generate` only reads
   `count` from decoded JSON (`lib/src/pipeline.dart`); allow a regex against
   an HTML body so `totalPages: 12` in a `<script>` works. Falls out of (1).

Not needed for the worked example above but the other half of "shrink the
imperative surface" (a chapter list that's HTML-inside-JSON, seen on other
sites): a `parse: "jsonHtml"` mode that lifts a JSON string field and
re-parses it as an HTML document, plus HTML-dialect chapter pagination
mirroring `ApiChaptersConfig.totalPath`.

## Encrypted / scrambled page images: declarable, with a byte seam

Worth stating plainly because it's easy to mis-file (this doc did, first draft):
**decrypting/descrambling page images is a config, not an imperative wall.** The
only reason it has nowhere to live today is architectural: the page pipeline
yields *URLs*, and the host (reader / downloader) fetches the bytes, so the
engine never touches an image byte. That's a missing seam, not a missing
capability.

Add two things and the whole "encrypted images" class becomes declarative:

1. A **byte-transform on the page output**: each `PageRef` carries an optional
   `decrypt` spec; the image-loading seam (precedent: `WebViewFetcher.fetchBytes`)
   fetches the bytes and applies it post-fetch, pre-display.
2. A small **built-in transform library** on the host: `aes-*`, `xor`, and a
   couple of known tile-unscramble schemes.

```jsonc
"pages": {
  "steps": [ /* … yield URLs, capturing {key}/{iv}/{seed} along the way … */ ],
  "decrypt": { "algo": "aes-cbc", "key": "{key}", "iv": "{iv}" }
  // or:      { "algo": "unscramble", "grid": "5x5", "seed": "{seed}", "scheme": "mangathemesia" }
}
```

Standard cipher + extractable key = pure config. A **custom key derivation**
folds into the JS step above (capture `{key}`, then apply). So it composes with
this proposal rather than sitting outside it.

## What genuinely stays imperative / native

- Sources needing a real DOM/WebView to *run* (not just clear a challenge):
  those stay on the `WebViewFetcher` path.
- Anything requiring branching/looping beyond capture-threading + `generate`.
- A **novel, perf-hot pixel transform**: a byte algorithm that is neither a
  standard cipher nor a parameterizable descramble, and is either not
  expressible in the sandboxed JS step or too heavy to run per-image through it
  (tile reassembly on every page often wants native canvas/isolate). This is a
  placement/performance call, not an expressibility limit: the narrow residue
  of "encrypted images", not the whole class.

## Rough implementation footprint

- `lib/src/pipeline.dart`: a `JsStep` value on `Step` (or a `js` field);
  `_runPipeline`/`runBodyPipeline` gain a `JsRunner? js` param and a branch that
  resolves `args`, evals, and captures; a redacted `StepTrace`; a `JsUnavailable`
  error.
- `lib/src/config_source.dart` / `lib/src/api_source.dart`: thread the injected
  `JsRunner` (already available to hosts) into the pipeline calls; expose it on
  the `Source` builders like `webViewFetcher`.
- `lib/src/extension_models.dart`: parse/serialize the `js` block; the `js: true`
  capability flag.
- `tool/build_repo.dart`: reject a `js` step outside curated entries; validate
  the block shape.
- Playground: the step trace already renders it; add a "JS step" affordance to
  the form editor.
- Tests: a fake `JsRunner` (echoing a canned answer) drives an end-to-end
  `steps:` pipeline in `dart test` with no real runtime.

## Verdict

One load-bearing feature (the JS step) plus one tiny primitive (regex scalar
capture) collapses a `pages()` flow like the worked example above into a
declarative config, and generalizes to every "run the site's JS to mint a
token" source. The cost isn't
engine complexity (the step is small and reuses capture-threading), it's the
**trust decision**: allowing curated configs to run sandboxed remote code. Gate
it behind `js: true` + curated-tier-only and it's a contained, high-leverage
addition.
