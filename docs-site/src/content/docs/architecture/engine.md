---
title: The engine
description: How a declarative config becomes a running Source, and the seams that keep it app-agnostic.
---

The engine is a **pure-Dart package** (`lib/`): the linear pipeline runner,
JSON-path evaluation, the declarative config models, and the two scraping
engines. No Flutter, no per-site code.

:::note[Deep reference]
This page is the tour. The exhaustive design docs live in the repo:
[`docs/architecture-decisions.md`](https://github.com/zenbaku/koni_dojo/blob/main/docs/architecture-decisions.md)
(the `Source`/`SourceOps` design choices),
[`docs/public-api.md`](https://github.com/zenbaku/koni_dojo/blob/main/docs/public-api.md)
(what a consuming app is expected to depend on), and
[`docs/source-pipeline-engine.md`](https://github.com/zenbaku/koni_dojo/blob/main/docs/source-pipeline-engine.md)
(the pipeline internals).
:::

## `Source`: one composed value

A source is never a subclass. It's a `Source` value (`source.dart`):
`SourceInfo` (id, name, baseUrl, …) plus `SourceOps`: closures for `popular`,
`search`, `details`, `chapters`, `pages`. The two builders produce it from a
config:

- **`htmlSource`** (`config_source.dart`): the HTML-scraping dialect (CSS
  selectors + attributes).
- **`apiSource`** (`api_source.dart`): the JSON-API dialect (JSON paths +
  templates), evaluated by `json_path.dart`.

Because a `Source` is just data + closures, the imperative escape hatch
(`imperative_sources.dart`), a hand-written `Source` for a site the declarative
engine can't express, composes the exact same way, never `extends Source`.

## Everything compiles to one pipeline

Each of the five operations compiles down to the **linear pipeline runner** in
`pipeline.dart`. A simple selector-based config desugars into a trivial
pipeline; a complex site declares its pipeline explicitly with `steps:`. Same
runner either way. See [The pipeline](/koni_dojo/architecture/pipeline/).

`pipeline.dart` also carries `StepTrace` / `runWithTrace`: an ambient trace
sink that records every request, captured variable, and response body. That's
what powers the playground's step-by-step trace view.

## App-agnostic by construction

The engine never depends on the app. Everything app-specific is an **injected
seam**, the same composition pattern throughout:

| Seam | What it provides | Absent when… |
|---|---|---|
| `http.Client` | the HTTP transport (retry / Cloudflare / relay in the app) | a plain client works standalone |
| `ClearanceStore` | replays a solved Cloudflare clearance onto requests | null → no replay |
| `JsRunner` | a JS runtime for `js`-step configs | null on web/tests → those sources error clearly |
| `WebViewFetcher` | a WebView transport for `webview:true` (CF-hard) sources | null → falls back to the HTTP client |
| `ExtensionBlobStore` / `ExtensionMetaStore` | where installed extensions + state persist | the app supplies a DB-backed impl |

`ExtensionManager` (`extension_manager.dart`) ties these together: repo CRUD,
index fetch/parse, install/uninstall, and `buildSources()`. **Nothing is
bundled**: a fresh install has zero sources until a repository is added.

## The config models

The declarative shapes live in `extension_models.dart`: `ExtensionInfo` (one
index entry) wraps one or more `SourceConfig` / `ApiSourceConfig`. A build-time
**lossless round-trip** (`fromJson` → `toJson` → compare) rejects any config the
runtime can't faithfully represent, so a typo fails the build instead of
shipping. Full field reference: [Config format](/koni_dojo/reference/config-format/).
