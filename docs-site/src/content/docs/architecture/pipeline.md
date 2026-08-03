---
title: The pipeline
description: The linear step runner every operation compiles to, and what it can express.
---

Every operation is a **linear pipeline**: an ordered list of steps that thread
variables from one to the next. A plain selector config desugars into a trivial
pipeline; a hard site declares one explicitly with `steps:`. One runner
(`pipeline.dart`) executes both.

:::note[Deep reference]
Full internals and worked examples:
[`docs/source-pipeline-engine.md`](https://github.com/zenbaku/koni_dojo/blob/main/docs/source-pipeline-engine.md).
:::

## What a step can do

- **request**: fetch a URL (GET or POST), with templated paths/bodies that
  interpolate variables captured earlier (`{seriesId}`, `{page}`, …).
- **parse**: interpret the response as `html`, `json`, `regexJson`, or
  `jsonHtml` (lift an HTML fragment out of a JSON envelope).
- **capture**: pull scalars into variables by selector, JSON path, or regex
  (from the body or a threaded variable).
- **yield**: emit the operation's result list (items, chapters, or page URLs),
  optionally via a `count`-by-regex + templated URL synthesis.
- **js**: run JavaScript in the injected runtime and capture its result
  (trust-gated; see below).

## Why a pipeline, not just selectors

Real sites need more than "select these elements." The pipeline expresses the
patterns that used to force per-site code:

| Pattern | How the pipeline handles it |
|---|---|
| **POST** listings / chapters | a `request` step with `method: POST` + templated body |
| **Two-phase lookup** (Madara) | fetch the manga page, `capture` a hidden id, POST it for the chapter list |
| **Script-blob readers** (MangaThemesia `ts_reader.run`) | regex-capture the images out of the inline script, with a base64 `data:` decode fallback |
| **Cross-format** (JSON list → HTML detail) | `jsonHtml` parse mode mid-pipeline |
| **JS-signed tokens** | a `js` step runs the site's own challenge script to mint a token |

## The `js` step

The declarative engine deliberately can't run arbitrary JS, except through one
explicit, **trust-gated** door. A `js` step runs sandboxed JavaScript in the
injected `JsRunner` (QuickJS in the app/playground) to compute a value the rest
of the pipeline threads onward. It's allowed **only** when the source opts in
with `"js": true`, and `build-repo` fails any config that uses a `js` step
without it. This is what lets a source whose reader is gated by a per-load
JS challenge become an ordinary declarative config instead of hand-written
Dart. See `docs/js-step-proposal.md` for the worked example.

## Tracing

`runWithTrace` wraps any operation and records each step's request, captured
variables, and full response body into a `StepTrace`. The playground renders
this as a step-by-step trace pane; any caller can tap the same sink to debug a
config.
