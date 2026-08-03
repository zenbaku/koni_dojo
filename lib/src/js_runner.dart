/// An injected JavaScript-execution seam, for the rare **imperative** sources
/// whose reader/anti-bot flow requires running site-supplied JS (the declarative
/// engines never need this). The pure-Dart package can't run JS, so the app
/// provides a runtime: `flutter_js` (QuickJS via FFI, or JavaScriptCore on
/// Apple). Null where no runtime is available (e.g. web), in which case sources
/// that need it surface a clear error instead of half-working.
///
/// This is the same composition pattern as the `http.Client` and
/// [ClearanceStore] seams: capability injected from the app, kept out of the
/// engine. See `docs/architecture-decisions.md`.
abstract interface class JsRunner {
  /// Evaluates [code] in a fresh-enough global scope and returns the value of
  /// its last expression as a string.
  Future<String> eval(String code);
}
