---
title: Quickstart
description: Clone the repo, build the index, and live-probe your first source.
---

Everything here needs only the **Dart SDK**, no Flutter, no app checkout. (The
optional GUI needs Flutter; this docs site needs Node; neither is required for
the core loop.)

## 1. Clone and bootstrap

```sh
git clone git@github.com:zenbaku/koni_dojo.git
cd koni_dojo
task setup      # dart pub get + build the index
task check      # the full gate: analyze + test + verify build outputs
```

`task setup` builds the **default workspace** (`../koni_dojo_repo/`), the
curated collection of sources that ships as the installable repository.

:::tip[Don't have `task`?]
`task` is [go-task](https://taskfile.dev) (`brew install go-task`). Every task
is a thin wrapper; you can always run the underlying `dart run tool/…​` command
directly. `task --list` shows them all.
:::

## 2. Live-probe a source

The tight loop is `task probe`: it runs the full reader path (popular →
details → chapters → pages) against a real site and prints what resolved. No
app, no build:

```sh
# Copy an existing config to iterate on:
cp test/fixtures/workspace/extensions/alpha.json /tmp/mysite.json

task probe -- /tmp/mysite.json
```

You'll see something like:

```
── Alpha <https://alpha.example> ──
POPULAR: 24 items; first='…' url=…
DETAILS: title='…' author='…'
CHAPTERS: 220; first='Chapter 1' url=…
PAGES: 18; first=https://…/01.jpg
```

Edit the JSON, re-run, repeat. When all four stages resolve, the config works.

## 3. Promote a source into the workspace

Land a working config so it ships in the built index:

```sh
mv /tmp/mysite.json ../koni_dojo_repo/extensions/mysite.json  # filename == source id
task capture-icons      # fetch its site icon (skips existing)
task build-repo         # validate every config through the engine + rebuild the index
task check              # full gate: run before every commit
```

That's the whole author → verify → ship loop.

## 4. Serve it to a device

The built index is a plain `index.min.json` any reader app can install:

```sh
task serve     # LAN: point "Add repository" at http://<lan-ip>:<port>/index.min.json
task publish   # public: deploy to the workspace's Cloudflare Pages project
```

## 5. (Optional) The GUI

Prefer a visual workbench? `task playground` runs a Flutter desktop app: browse
every source in a sortable table, edit configs with a live probe pane, inspect
covers/pages/traces, and switch between workspaces. It's the one part that needs
Flutter.

## Next

- [Core ideas](/koni_dojo/start/concepts/): the vocabulary (configs,
  engine, tiers, workspaces).
- [Workspaces](/koni_dojo/reference/workspaces/): how a source collection is
  laid out, selected, served, and published.
