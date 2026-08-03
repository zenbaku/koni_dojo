---
title: Tooling & tasks
description: Every task and tool, and the two GUIs.
---

`Taskfile.yml` wraps the common commands; every task needs only the Dart SDK
(the exceptions are noted). All tasks take `WORKSPACE=<name>` and all Dart tools
take `--workspace <name|path>`; unset, the `task` layer defaults to the sibling
`../koni_dojo_repo` (a bare `dart run` falls back to `workspaces/default`).

## Tasks

| Command | What it does |
|---|---|
| `task setup` | Fresh clone → working tree: deps + build-repo. |
| `task check` | The gate: analyze + test. |
| `task build-repo` | Validate every `extensions/*.json` through the engine; write `repo/index.min.json`. |
| `task capture-icons` | Fetch a site icon per config into `extensions/icons/` (skips existing; `-- --force` refetches). |
| `task serve` | LAN-serve the workspace's `repo/` on its manifest `servePort`. |
| `task publish` | Deploy `repo/` to the workspace manifest's Cloudflare `publish.cfProject`. |
| `task probe -- <config>` | Live-probe one config file (popular→details→chapters→pages). |
| `task probe-pipeline` | Live smoke test of the pipeline engine's cross-format capability. |
| `task playground` | The Flutter desktop GUI (needs Flutter). |

## Dart tools (direct)

The dev-loop tools are usually run directly rather than via a task:

| Command | What it does |
|---|---|
| `dart run tool/live_probe.dart <config>` | Same as `task probe`. |
| `dart run tool/build_repo.dart` · `serve_repo.dart` · `publish_repo.dart` · `capture_icons.dart` | What the tasks wrap. |

## The playground

`task playground`, a Flutter **desktop** workbench over one or more workspaces:

- Every source (active + dormant) in one sortable, filterable table (by tier,
  engine, language, probe status, 18+, archived).
- A config editor (raw JSON or a structured form) beside a live probe pane:
  covers, pages, and a step-by-step request/response trace.
- A per-stage runner (probe just `popular`, or `pages` with a custom input).
- Probe history persisted to SQLite; a collection's own bulk-probe tooling can
  record into the same DB, so the table reflects the latest run.
- An app-bar **workspace switcher** across several registered workspaces.
