---
title: Workspaces
description: The project's first-class unit of a source collection. One repo, several collections.
---

A **workspace** is a source collection: a directory with a `workspace.json`
manifest plus everything that defines and builds one installable repository.
This engine repo ships no workspace of its own. Clone your own as a
sibling (the tooling's examples use the conventional local name
`../koni_dojo_repo/`); you can maintain several, each built, served, and
published independently.

## Layout

```
../koni_dojo_repo/
  workspace.json        # {name, description, servePort, publish:{cfProject}}
  extensions/*.json     # curated, hand-authored configs (+ icons/)
  repo/index.min.json             # the built, servable index
  repo/generated-index.min.json   # a second, unverified tier, if the collection keeps one
  curation/archived.json          # sources deliberately not pursued
  sources-catalog.md    # this collection's curation log / status
```

The engine (`lib/`), tooling (`tool/`), and engine docs (`docs/`) stay at the
repo root; only the **source-collection data** lives per-workspace.

## Selecting a workspace

Every task takes `WORKSPACE=<name>`; every Dart tool takes
`--workspace <name|path>`. Both default to the sibling `../koni_dojo_repo` (the
Taskfile passes it as `WORKSPACE`), so day-to-day work needs neither. A bare
name resolves to `workspaces/<name>/`; a path is used as-is (so an external
directory works too). A raw `dart run tool/…` with neither set falls back to
`workspaces/default`.

```sh
task build-repo                      # default: ../koni_dojo_repo
task build-repo WORKSPACE=nsfw       # workspaces/nsfw/
task serve      WORKSPACE=nsfw       # LAN-serve it on its manifest port
task publish    WORKSPACE=nsfw       # deploy to its Cloudflare project
dart run tool/build_repo.dart --workspace ../some/external/collection
```

## Why several

One engine, many collections: per-language repos, themed collections, or a
public and a private one. Each has its own manifest (its own serve port and
Cloudflare project), its own catalog, and its own built index, so serving or
publishing any of them is a one-liner.

## Serving & publishing are first-class

These are manifest-driven operations, not hardcoded targets:

- **`task serve`** reads the workspace's `servePort` and serves its `repo/` over
  the LAN: point a phone's "Add repository" at
  `http://<lan-ip>:<port>/index.min.json`.
- **`task publish`** reads the workspace's `publish.cfProject` and deploys its
  `repo/` to that Cloudflare Pages project, the public URL a reader installs.

## In the playground

The desktop [playground](/koni_dojo/reference/tooling/#the-playground)
registers **several** workspaces and switches between them from the app bar. It
opens any workspace directory (nested under `workspaces/` or external) and reads
its manifest, catalog, and both tiers.
