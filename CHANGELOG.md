# Changelog

Semver, applied to the public API (see `docs/public-api.md`) and the
declarative config shape (`docs/source-config.schema.json`, whose
`x-engineVersion` tracks the version below):

- **MAJOR**: a field removed/renamed, a required-status change, or any
  other change an existing config or an app built against this package
  couldn't parse/compile against unmodified.
- **MINOR**: a new optional field or capability (a config that doesn't use
  it is unaffected either way).
- **PATCH**: behavior fixes with no shape change.

## Unreleased

Additive to the public API and to config behaviour; nothing here is
breaking, so this classifies as a MINOR release when cut.

- **`webview` names operations, not just a source** (`SourceConfig.webviewOps`,
  `SourceOp`, `SourceConfig.webviewFor`). `"webview": true` still means every
  operation and parses exactly as before; a new sibling key,
  `"webviewOps": ["chapters"]`, narrows it to the ones that actually need a
  rendered DOM. `SourceConfig.webview` is now a getter — "does any operation
  need a browser" — so capability gating is unchanged. Schema
  `x-engineVersion` 0.3.0.

  The narrowing is a *separate key* rather than a widened `webview`, and that
  is a compatibility decision: an engine older than this parses `webview` with
  a hard `as bool?` cast, and `loadInstalled` catches the resulting `TypeError`
  by dropping the whole extension — a narrowed config would have made the
  source silently vanish from every install that hadn't updated. Verified
  against the previously pinned build: it reads a narrowed real config,
  sees `webview: true`, and renders everything, which is only the old
  behaviour. So a narrowed config can ship without waiting on app releases.

  The flag was all-or-nothing while the need almost never is: on one real
  source, measured 2026-08-26, only the chapter list differs between a plain
  fetch and a rendered page (2 `<option>` entries against 2754), while the
  page list is identical either way — so the hottest path in the app was
  paying a full browser page load per chapter for markup it already had. That
  is expensive natively and much worse on web, where the renderer is a
  background tab: timers clamped to one per second, `requestAnimationFrame`
  and `IntersectionObserver` never firing at all.

  The share scope's key gains the transport, since two operations on one URL
  can now legitimately want different bodies — a plain body must never satisfy
  an operation that was narrowed to `webview` because a plain body is not
  enough.
- **A listing with no `nextPageSelector` paginates on `pageSize`**: a page
  returning exactly that many items was capped rather than exhausted, so
  another follows.

  For the site whose pagination is infinite scroll — no next-page control in
  the markup at all, live or raw, while `?page=N` works server-side. Such a
  listing could only ever return its first page, which the app shows as "no
  more results" rather than "the engine had no way to ask". Opt-in (it needs
  `pageSize`), self-terminating (a short page ends the walk), and inert for any
  listing that declares a selector — that site has already answered, and its
  last page is allowed to be exactly full.

- **`pad` on the generate shape**: zero-pads `{n}` to a fixed width, for a host
  that names its files `p0001.jpg` and will not answer `p1.jpg`.

  Small, and it decides whether a source is readable at all. One real source's
  reader keeps every page path in the response (91 of them) while rendering
  only the six near the viewport — so rendering it would have produced a
  six-page chapter out of ninety-one, silently. Reading the count and
  regenerating the URL shape gets the whole chapter with no browser, but only
  if the shape is reproduced exactly.

- **A `parse: json` step is never rendered** (`StepFetch` gains a `document`
  flag, which the pipeline runner sets from the step's own parse mode). A
  browser navigation always produces a document — a JSON endpoint opened in a
  tab comes back wrapped in `<html><body><pre>` — so routing a JSON step
  through the browser hands the decoder markup every time. A type mismatch
  rather than a tuning question, which is why the runner answers it and not the
  config.

  What it unlocks is bigger than the bug it prevents: a config can move an
  endpoint onto its site's own JSON API without breaking the platforms where
  `webview` is doing real work. One real source's chapter list turned out to
  be exactly that — a paginated JSON endpoint that answers a plain client with
  200 while the site's HTML pages answer 403 — so its whole
  chapter list is one request and needs no browser anywhere. Measured live
  through the shipped config with a plain HTTP client: **1377 chapters in
  1146 ms**, against two browser page loads before.
- **`SourceConfig.challengesPlainClients`**, and the `clientIsBrowserSession`
  argument to `htmlSource`/`ExtensionManager`. A bare `webview: true` meant
  two things at once — "this content is script-built" and "this host refuses
  anything that isn't a real browser" — and only the first is a property of
  the *content*. The second depends on what the client is, so narrowing a
  config without separating them would have moved a Cloudflare-hard source
  onto a plain HTTP client: web fixed by breaking every native build.

  `webview: true` implies it, so nothing existing changes. A host whose client
  fetches from inside the user's own browser session sets
  `clientIsBrowserSession` and pays for a render only where the content really
  is script-built.
- **`Source.requiresWebView`**: a capability marker on the value itself,
  populated from the config's `webview` flag. The fact that a source needs a
  real browser previously lived only inside the HTML engine, where it routes
  fetches — nothing on `Source` said so, so a host had no way to ask before
  handing the source to a transport that can't provide one. See
  `docs/public-api.md`.
- **`probeSource` can skip unwritten stages**: `detailsConfigured`,
  `chaptersConfigured`, `pagesConfigured` (all default true, so existing
  callers are unaffected). A half-written config's blank `details` block
  doesn't fail — it "succeeds" with an all-blank result that looks like a
  working probe, which is worse. A skipped stage never sets `failedStage`.
- **`rows` values are normalized**: internal whitespace collapses to single
  spaces, and one trailing `,`/`;` is dropped. A `rows` value selector often
  lands on a whole row wrapper spanning several children of pretty-printed
  HTML, so `.trim()` alone left the source's own newlines and indentation
  embedded in the extracted value; and a common markup shape wraps a tag
  *and* its list separator in one element, so the separator arrived as if it
  were data.
- **An empty listing `path` resolves to `baseUrl`**: a listing that lives at
  the site root is a valid config. It previously went through `absoluteUrl`,
  whose empty-in/empty-out contract exists so an *unmatched selector* can't
  become a phantom baseUrl link — a different question, wrongly shared.

## 0.2.0

- **Per-source login** (`SourceConfig.loginUrl`): a UI trigger for the
  app's WebView-based login capture; the engine never knows what "logged
  in" means, the session lives in the shared WebView cookie jar.
- **`localStorageSeed` / `localStoragePreferences`**: for a purely
  client-side gate (an age/content-warning interstitial) that isn't session
  state: the fetcher seeds declared `localStorage` values into its own
  persistent WebView before the first fetch to an origin, and
  `localStoragePreferences` layers user-facing toggles on top via a new
  `LocalStoragePreferenceStore` seam.
- **`ExtensionInfo.version` retired from hand-maintained semver to a
  content hash** (a truncated SHA-256 of the curated file's raw bytes,
  stamped in by `tool/build_repo.dart`), plus a new `ExtensionInfo.updatedAt`
  date. Not a breaking shape change (`version` stays a `String`), but a
  semantic one: a content hash changes only when the curated file's bytes do,
  decoupled from the engine's own serialization.
- **`warmImageViaImgTag`**: a second cover/page image-warming strategy for
  `webview` sources (navigate + inject `<img crossorigin>` + canvas-read),
  recovering hosts `warmImageByUrl` can't.
- API dialect: relative page URLs now resolve against `apiUrl` (previously
  only ever produced absolute URLs, which some sources' bare-path chapter
  responses need); `ApiSourceConfig.tag` (a JSON-API tag listing, mirroring
  the HTML dialect's) is now covered by the config schema.
- `docs/public-api.md` (this package's actual app-facing surface, as
  opposed to everything `lib/koni_dojo.dart` happens to export) and
  `test/schema_sync_test.dart` (fails the suite if a config class's
  `toJson()` field set drifts from `docs/source-config.schema.json`).

## 0.1.0

Initial release: the declarative manga/comic source engine, extracted as a
standalone pure-Dart library.

- **Two config dialects:** HTML scraping (CSS selectors) and JSON API (JSON
  paths + templates), both driven entirely by a JSON `SourceConfig`.
- **Five reader operations** per source: popular, search, details, chapters,
  pages (no per-site code).
- **Linear pipeline runner** every operation compiles to, with explicit
  `steps:` for harder sites (POST requests, two-phase lookups, script-blob
  readers, and a trust-gated `js` step that runs site JavaScript).
- **Transport seams** injected by the host: `ClearanceStore` (Cloudflare
  clearance replay), `WebViewFetcher` (WebView transport for CF-hard sources),
  and `JsRunner` (a JS runtime for `js`-step sources).
- **`ExtensionManager`** for repository install/uninstall and building live
  sources; **`probeSource`** to smoke-test a config end to end.
- **`runWithTrace`** captures each pipeline step's request/response for
  debugging a config.
