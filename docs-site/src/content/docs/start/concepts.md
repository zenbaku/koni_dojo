---
title: Core ideas
description: The vocabulary (configs, the engine, tiers, and workspaces) in one page.
---

Five concepts cover the whole system.

## 1. A source is a declarative config

A **source** (one manga site) is described by a JSON **config**, no per-site
code. Two dialects:

- **HTML** (default): CSS selectors + attributes for scraping HTML pages.
- **API** (`"type": "api"`): JSON paths + templates for sites with a JSON API.

The config names *where* each piece of data lives for the five operations
(**popular**, **search**, **details**, **chapters**, **pages**) and the engine
does the rest. Full syntax: [Config format](/koni_dojo/reference/config-format/).

## 2. The engine turns a config into a `Source`

The pure-Dart engine (`htmlSource` / `apiSource`) reads a config and produces a
`Source`, a composed value with closures for each operation. Every operation
compiles down to a single **linear pipeline runner**. When a site needs more
than plain selectors (POST requests, two-phase lookups, script-blob readers,
running the site's own JS), the config gains an explicit `steps:` pipeline
instead of bespoke Dart. See [The engine](/koni_dojo/architecture/engine/).

## 3. Sources move through tiers

A collection tracks each source's state, so the tooling (and the playground's
table) can tell a verified source from an unverified one:

| Tier / status | Meaning |
|---|---|
| **Candidate** | Known to exist, but no config written yet. |
| **Dormant** | A config that exists but isn't live-verified. |
| **Active** | Live-verified and curated: it ships in the installable index. |
| **Blocked** | Needs JS execution / request signing / an interactive Cloudflare solve the engine can't do headlessly. |
| **Archived** | Deliberately not pursued: dead host, or not worth the effort. |

How a given collection moves sources up these tiers is that collection's own
business; the engine only cares about the config it's handed.

## 4. Everything lives in a workspace

A **workspace** is a source collection: a directory with a `workspace.json`
manifest plus `extensions/` (configs), `repo/` (built + dormant indexes),
`curation/`, and a catalog. This engine repo ships no workspace of its own.
Clone your own as a sibling (the tooling's examples use the conventional
local name `../koni_dojo_repo/`); you can maintain several (per-language
repos, themed collections, a public and a private one), each built, served,
and published independently. Every tool takes `--workspace <name>` /
`WORKSPACE=<name>` (default `../koni_dojo_repo`). See
[Workspaces](/koni_dojo/reference/workspaces/).

## 5. The output is an installable repository

`task build-repo` produces `repo/index.min.json`, a plain index any
`index.min.json`-compatible reader can install. `task serve` exposes it on the
LAN; `task publish` deploys it to Cloudflare Pages. **Nothing is bundled into
any app**: a reader starts empty and adds a repository URL at runtime.

---

Next: the [Quickstart](/koni_dojo/start/quickstart/) and the
[config format](/koni_dojo/reference/config-format/).
