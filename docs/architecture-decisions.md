# Architecture decisions

Short-form record of the design choices behind `Source` and its supporting
types, kept current (unlike a design-draft doc, this describes what's
actually shipped; check the referenced files if this ever drifts).

## One concrete `Source` type, never subclassed

`Source` (`lib/src/source.dart`) is the one value every source is, built by
`htmlSource`/`apiSource` (the declarative engines) or hand-written for
imperative sources. Nothing does `class XSource extends Source`. Reuse comes
from composing shared pieces, not implementation inheritance: the trap
inheritance-for-reuse tends to produce is a fragile base class where every
site's drift forces a leaky flag or a fork.

Operations are function values (`SourceOps`'s `ListingOp`/`DetailsOp`/
`ChaptersOp`/`PagesOp`/`FiltersOp`/`TagOp` typedefs), not overridden methods:
`SourceOps.copyWith` swaps one op without touching the rest. Cross-cutting
concerns (Cloudflare clearance, consent-preference overrides) are injected
seams set after construction (`Source.clearanceStore`,
`Source.localStoragePreferenceStore`, see `docs/public-api.md`), not
transport middleware; there's no `Fetch -> Fetch` composition layer in the
shipped engine.

## Opaque refs, immutable returns

`MangaRef(url)` / `ChapterRef(url)` carry only the source-relative id (never
a cached "hint", nothing has needed one yet). `details(MangaRef)` returns a
**fresh** `SourceManga` each call; the caller (the app's library layer) is
what merges a listing result with a details fetch. Mutate-in-place was
deliberately rejected: shared mutable state reached through a composed
closure is exactly the kind of bug that's hardest to trace back.

## Filters are an operation, not a separate concept

`FiltersOp` returns the available filter groups (memoized by the builder
that constructs it); `ListingQuery.filters` carries the caller's selection,
applied by the same listing builder that applies `page`/`query`.
`Source.hasFilters` is a plain flag derived from whether a `FiltersOp` was
supplied.

## Identifier stability is an authoring contract, not machinery

A source's `id` should be the site's most stable natural key (a slug or
permalink, not an incrementing integer) and must stay stable across a
source's own updates: library entries are keyed `sourceId + url`, and
nothing else assigns or migrates ids. This is discipline enforced by review,
not code.

## `PageRef` carries `{url, headers}`

`PageRef(url, {headers})`: everything a downloader or the reader needs to
fetch a page directly, without re-running any of the source's own transport.
Covers both a plain open-CDN image host and a header-auth/signed-URL one;
`fetchBytes`'s `warmByUrl`/`viaImgTag` (`lib/src/web_view_fetcher.dart`) are
the two recovery paths for hosts that need more than a bare request.
