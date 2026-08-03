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
