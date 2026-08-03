<p align="center">
  <img src="koni_dojo_icon.png" alt="Dojo" width="150" height="150">
</p>

# Dojo: `koni_dojo`

A **pure-Dart declarative source engine**: it turns a JSON config into a live
content source (fetching, parsing, and paginating an HTML or JSON-API site)
with no per-site code. You describe *where* each piece of data lives (CSS
selectors or JSON paths); the engine does the rest. No Flutter dependency;
everything runs on just the Dart SDK.

> **Docs:** <https://zenbaku.github.io/koni_dojo/>, the guided overview,
> quickstart, architecture, and curation walkthrough. This README is the terse
> reference; source for the site lives in [`docs-site/`](docs-site/).

The name: **Dojo** is the project, `koni_dojo` the Dart package: a library for
building scraping pipelines from a JSON config.

## What's in this repo

This repo is the **engine + tooling + docs, no content data.** It holds:

- the pure-Dart engine (`lib/`),
- the authoring and build tooling (`tool/`),
- the docs (`docs/`, `docs-site/`),
- the desktop [`playground/`](playground/) for developing configs.

The actual **source collections**, the curated configs and built indexes,
are *data*, and live in their own repositories (**workspaces**), kept separate
so the engine stays code-only. You point the tooling at a workspace with
`--workspace`.

## Quickstart

Everything needs only the Dart SDK. [`Taskfile.yml`](Taskfile.yml) wraps the
common commands ([go-task](https://taskfile.dev); `task --list` shows them all).

```sh
task setup    # fresh clone → install deps + build
task check    # the gate: analyze + test
```

The tight authoring loop is a live probe: run one config against its real
site (popular → details → chapters → pages) and see what resolved:

```sh
cp test/fixtures/workspace/extensions/alpha.json /tmp/mysite.json
task probe -- /tmp/mysite.json
# edit the JSON → rerun → repeat
```

No app build, no boot. Prefer a GUI? `task playground` opens the desktop
workbench (see [`playground/`](playground/)).

## How it works

**A source is a config.** One JSON document describes a site for five
operations (popular, search, details, chapters, pages) in one of two
dialects:

- **HTML** (default): CSS selectors + attributes for scraping pages.
- **API** (`"type": "api"`): JSON paths + templates for a JSON API.

**The engine compiles it to a pipeline.** `htmlSource` / `apiSource` read a
config and produce a `Source` (a composed value, never subclassed). Every
operation compiles down to one linear pipeline runner. When a site needs more
than plain selectors (POST requests, two-phase lookups, script-blob readers,
or running the site's own JavaScript), the config gains an explicit `steps:`
pipeline instead of bespoke Dart.

**A workspace is a source collection.** A directory (its own repo) with a
`workspace.json` manifest, one config per source under `extensions/`, and a
built `repo/index.min.json` that any compatible reader can install. Clone one
as a sibling and drive it with the tools; you can keep several, each built,
served, and published independently. The default `--workspace` is the sibling
`../koni_dojo_repo`, but any directory with that layout works. Point
`--workspace` wherever it lives.

Full design docs: [`docs/`](docs/) (architecture, public API, config schema,
the pipeline engine) and the [docs site](https://zenbaku.github.io/koni_dojo/).

## The toolkit

| Command | What it does |
|---|---|
| `task probe -- <config>` | Live-probe one config end to end. |
| `task build-repo` | Validate a workspace's configs and (re)build its index. |
| `task capture-icons` | Fetch a site icon per source. |
| `task serve` | Serve a workspace's index over the LAN for a device to install. |
| `task publish` | Deploy a workspace's index to its Cloudflare Pages project. |
| `task playground` | Open the desktop config workbench (needs Flutter). |
| `task docs` | Run the docs site locally (needs Node). |

Each data-facing task takes `WORKSPACE=<path>` (or `--workspace` on the
underlying `dart run tool/…` command) to target a specific collection.

## Using it in an app

The engine is a library; a host app supplies the environment-specific pieces
through injected seams rather than the package depending on any app:

- **`http.Client`**: a plain client is enough; a host can add retry/relay.
- **`ClearanceStore`** (`lib/src/source.dart`): replays a solved Cloudflare
  clearance onto requests (null when unused).
- **`ExtensionBlobStore` / `ExtensionMetaStore`** (`lib/src/extension_manager.dart`):
  where installed extensions and small JSON state persist.
- **`JsRunner` / `WebViewFetcher`**: a JS runtime and WebView transport for
  JS-gated / Cloudflare-hard sources; both optional (null in tests/web).

`ExtensionManager` handles repository install/uninstall and builds live
sources; `probeSource` (`lib/src/source_probe.dart`) smoke-tests a config end to
end; `runWithTrace` captures each pipeline step's request/response for
debugging. See [`docs/public-api.md`](docs/public-api.md) for the app-facing
surface.

## Scope & legal

This repo is a **content-neutral engine**, not a service. It doesn't fetch,
host, cache, or distribute anyone's content. It's a library that turns a JSON
config into an HTTP/HTML-parsing pipeline, run entirely on the end-user's own
device. It ships **no bundled site list and no hosted index**: an app built on
it reaches a site only when the person running it points a user-supplied config
there. Whether using a given config against a given site complies with that
site's own terms is between that user and that site. The engine has no say in
and takes no part in that.

## License

MIT. See [`LICENSE`](LICENSE).
