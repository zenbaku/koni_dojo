# Dojo playground

A Flutter **desktop** workbench for authoring and testing
[`koni_dojo`](../) source configs against their real sites, the visual
counterpart to the `task probe` CLI loop.

Desktop on purpose: a real HTTP client (no browser CORS) is what makes
live-probing actual sites possible, and an embedded WebView (`flutter_inappwebview`)
drives the same `WebViewFetcher` / `ClearanceStore` seams the engine exposes, so
Cloudflare-walled and JS-gated sources behave here as they would in a host app.
It's the one Flutter-dependent corner of the project: the engine package itself
stays pure Dart, and nothing in `task check` touches this.

## Run it

Needs the Flutter SDK (macOS, Linux, or Windows desktop).

```sh
task playground        # from the repo root
# or, from this directory:
flutter run
```

Point it at a workspace (a source collection) and go.

## What it does

- **Browse every source in one table**: active (`extensions/*.json`) and
  dormant (converted-but-unverified) tiers together, sortable and searchable,
  each row showing its characteristics, catalog status/notes, and a live probe
  column. "Probe all" runs the whole tier through `probeSource` with a small
  worker pool. A filter bar narrows by tier, engine (HTML/API), language, probe
  status, and 18+; archived sources hide unless you ask for them.

- **Edit configs two ways**: a raw, syntax-highlighted JSON view, or a
  structured **Form** view with typed fields and per-operation sections, beside
  a live probe pane.

- **Run one stage at a time**: the stage runner executes any single operation
  (popular / search / details / chapters / pages) with a custom input (a manga
  URL, a search query, a page number), so you can iterate on one selector
  without re-running the whole chain.

- **Inspect everything**: resolved covers, details, chapters, and page images
  (every item tappable to see the exact parsed JSON), plus a step-by-step
  pipeline trace showing each step's request, captured variables, and full
  response body.

- **Remember runs**: each probe is saved to a small SQLite database in your
  home directory: the last status per source across restarts, a per-source
  history, and the latest run's captured request/response (handy offline
  fixtures).

- **Clear challenges**: a Cloudflare-walled source can clear its challenge
  headlessly, or through an interactive solver window from the row's detail
  screen; captured clearance is replayed per host and persists across launches.

## Relationship to the engine

The playground is a *consumer* of `koni_dojo`, wired up the same way a real app
is: it implements the injected seams (`WebViewFetcher`, `ClearanceStore`, the
extension stores) and calls the exact same `probeSource` chain the CLI and a
host app use, so a config that works here works anywhere.
