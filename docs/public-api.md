# Public API

What a consuming app is expected to build against:
the surface a version bump's semver classification (see `CHANGELOG.md`) is
actually about. `lib/koni_dojo.dart` exports more than this list wholesale
(Dart's export model is coarse), but anything not named here is incidental:
reachable, not a contract; changing it isn't a breaking release even though
it technically could break code that imported it directly.

## Repository management

- **`ExtensionManager`**: the entry point. Repo add/remove/list, index
  fetch/parse (`fetchIndex`), install/uninstall, `buildSource(s)` (turns
  installed configs into live `Source` values). Constructed with the app's
  own seams: `storage` (`ExtensionBlobStore`), `meta` (`ExtensionMetaStore`),
  `clearance` (`ClearanceStore`), `repoAuth` (`RepoAuthStore?`),
  `localStoragePreferences` (`LocalStoragePreferenceStore?`),
  `webViewFetcher`, `jsRunner`.
- **`ExtensionInfo`**: one installed/available extension: `name`, `pkg`,
  `version` (an opaque content hash, not semver, see its doc), `updatedAt`,
  `lang`, `nsfw`, `sources`.
- **`AnySourceConfig`** / **`SourceConfig`** / **`ApiSourceConfig`**: the
  parsed config models, for anything that reads config fields directly (the
  Extensions UI, the config editor).

## The source facade

- **`Source`**: the one concrete type every source is:
  `popular`/`search`/`details`/`chapters`/`pages`/`filters`/`tag` ops, plus
  `id`/`name`/`lang`/`baseUrl`/`icon`, `loginUrl`,
  `localStoragePreferences`, `warmImageByUrl`/`warmImageViaImgTag`,
  `imageHeadersFor(url)`, `throttle()`. `clearanceStore` and
  `localStoragePreferenceStore` are settable after construction;
  `ExtensionManager.buildSource` wires both in.
- **`Source.requiresWebView`**: a capability marker a host is expected to
  read. True means this source's requests must go through a real browser, so
  it cannot be served by a transport that builds a request ahead of time and
  performs it elsewhere (an OS-level background downloader, a pre-signed
  batch) — such a transport carries only a fixed URL and header map, and
  can neither refresh an expired clearance nor escalate to the browser.
  Keeping such a source off that path is a decision only the host can make.
- Result/ref types: **`SourceManga`**, **`SourceChapter`**, **`CatalogPage`**,
  **`FilterGroup`**/**`FilterOptionSpec`**, **`MangaRef`**, **`ChapterRef`**,
  **`PageRef`** (`{url, headers}`, see `docs/architecture-decisions.md`),
  **`FilterSelection`**.

## Injected seams (implement these in the app)

- **`ClearanceStore`**: replay a host's Cloudflare clearance.
- **`WebViewFetcher`**: browser transport for a config's `webview` operations
  (implemented by the separate `koni_dojo_webview` package, along with
  `openLoginSession`, `solveCloudflare`, `warmCookieJar`,
  `createWebViewFetcher`, `cloudflareSolveSupported`).
- **`JsRunner`**: evaluates `js`-step code (QuickJS/JavaScriptCore).
- **`LocalStoragePreferenceStore`**: per-source consent-toggle overrides
  (`SourceConfig.localStoragePreferences`).
- **`RepoAuthStore`**: Basic Auth for repos that need it.
- **`ExtensionBlobStore`** / **`ExtensionMetaStore`**: where
  `ExtensionManager` persists installed extensions and small metadata.

## Not part of the app contract

- **`probeSource`**, **`runWithTrace`**: the full reader-path smoke test and
  step-trace sink. Built for the playground/curation tooling; an app could
  call them, but they're not something a semver bump promises to keep stable
  for app use.

## Versioning

See `CHANGELOG.md`'s header for the semver policy, and
`docs/source-config.schema.json`'s `x-engineVersion` for how the config
schema tracks the package version.
