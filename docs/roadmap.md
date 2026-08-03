# Roadmap

What's known-open, and what's been deliberately deferred. **Not a commitment
and not a backlog** — nothing here is scheduled. Its job is to stop settled
questions from being re-litigated from scratch, so each entry records the
*reasoning*, not just the item.

## Known gaps

Things the declarative engine can't express today. A source that needs one of
these is marked **Blocked** in a collection's curation state rather than
archived — the config isn't wrong, the engine just can't run it yet.

- **`CfGate` seam — an interactive Cloudflare solve.** Auto-clearing "managed"
  challenges already work through `webview: true`. An interactive Turnstile
  needs a human, which means a host-side seam the engine can call into and
  wait on, rather than anything the config can describe.
- **`Signer` seam — request signing.** Sources that mint a per-request
  signature or token in their own JS. The `js` step covers the cases where the
  site's own code can be run as-is; this is for the ones needing a real
  signing routine the host provides.
- **Image decryption.** Readers that serve scrambled or encrypted page images
  and unscramble them client-side. `crypto_decrypt.dart` handles the decrypt
  shapes seen so far; the general case is open.

Each is a *seam*, not engine logic — the engine deliberately doesn't know what
"solve a challenge" or "sign this request" means. See
[`docs/public-api.md`](public-api.md) for the seams that already exist.

## Smaller known gaps

- **Picker: genre selection over-matches.** The element picker's
  selector-generation algorithm can't scope a genre/tag `<span>` that shares
  no distinguishing class with its siblings, so it also matches structurally
  identical neighbours (an author span, say). Pinned as a passing test that
  documents the behaviour rather than hiding it — see the `KNOWN GAP` case in
  `webview/test/picker_algo/picker-algo.test.js`. The `rows` picker is the
  workaround where a details page uses a label/value table.
- **`FieldStep.previewIsImage` is Details-only.** The listing picker's cover
  step is structurally identical and could opt in; it wasn't, to keep that
  round's scope to the Details palette. A one-word change if wanted.

## Open design questions

Carried in [`docs/source-pipeline-engine.md`](source-pipeline-engine.md)'s
"Open questions" section — sugar permanence, `parse: regexJson` naming, and
where per-step field extraction should live. Each has a stated lean; none
blocks anything.

## Might do

Speculative. Recorded so the reasoning survives, not because they're planned.

### Publish to pub.dev

**Deferred — there is currently no consumer that needs it.** Every consumer
already resolves the engine without it: the app uses a git dependency pinned
to a commit, and `webview/`, `playground/`, and a workspace's curation tooling
all use path dependencies. Publishing would add discoverability and semver
ranges for third parties, neither of which anyone has asked for.

Against that: the package name is claimed permanently, published versions can
be retracted but never deleted or reused, and every later breaking change
becomes a MAJOR release that strangers' builds depend on — where today it
costs one commit and a ref bump.

The one real argument for it: an immutable published version can't be
rewritten out from under a consumer, whereas a git-dependency pin breaks if
history is ever rewritten. That's a genuine hazard, just a rare one.

Revisit if someone outside this project wants to depend on the engine, or if
discoverability becomes something worth having on purpose.

*Prep is done and doesn't rot:* `.pubignore` is correct (441 KB archive,
`dart pub publish --dry-run` reports 0 warnings), and `pana` scores 150/160 —
the only deduction is `dart format` on two `lib/` files. The mechanical steps
are a version bump in `pubspec.yaml`, the matching `x-engineVersion` in
`docs/source-config.schema.json`, promoting the CHANGELOG's `Unreleased`
heading, and `dart pub publish`. Decide on a verified publisher before a first
publish rather than after — attribution is awkward to change later.

### A custom `Locator` type

Sketched in the pipeline design doc as an alternative to reusing the existing
CSS/JSON value structs per step. The lean has been to reuse what exists; this
is the road not taken, kept in case per-step extraction grows enough surface
to justify its own type.
