import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_source.dart';
import 'config_source.dart';
import 'extension_models.dart';
import 'imperative_sources.dart';
import 'js_runner.dart';
import 'request_timeout.dart';
import 'source.dart';
import 'web_view_fetcher.dart';

/// Where an [ExtensionManager] persists installed-extension blobs
/// (`extensions/<pkg>.json`) and the legacy `extensions/repos.json` file, the
/// same shape as the app's `StorageBackend`, narrowed to what this needs.
abstract interface class ExtensionBlobStore {
  Future<Uint8List?> read(String path);
  Future<void> write(String path, Uint8List bytes);
  Future<void> delete(String path);

  /// Lists every file path starting with [prefix].
  Future<List<String>> list(String prefix);
}

/// Where an [ExtensionManager] persists small JSON blobs: the repo URL list
/// and device-local source preferences (pinned sources, search scope). The
/// app backs this with its `KeyValues` database rows.
abstract interface class ExtensionMetaStore {
  Future<Map<String, dynamic>?> loadMeta(String key);
  Future<void> saveMeta(String key, Map<String, dynamic> value);
}

/// HTTP Basic Authorization for a repository host that requires it, applied
/// to [ExtensionManager.fetchIndex] requests. Mirrors [ClearanceStore]'s
/// shape exactly. The app supplies a keychain-backed implementation;
/// standalone/test use of the engine leaves [ExtensionManager.repoAuth] null,
/// so no auth header is ever added.
abstract interface class RepoAuthStore {
  /// Materializes persisted credentials (idempotent; safe to call again).
  Future<void> load();

  /// Headers to merge over a repo-index request for [repoUrl]'s host; empty
  /// when there's no stored credential, so callers fall back untouched.
  Map<String, String> headersFor(String repoUrl);
}

/// Manages extension repositories and installed extensions, mirroring
/// Mihon's extension installer.
///
/// A repository is any URL serving a JSON index in the same shape as
/// keiyoushi's `index.min.json`; see [ExtensionInfo] for the entry format.
/// Installed extensions are stored as JSON under `extensions/<pkg>.json`.
///
/// Reaches back into the app through injected seams: [storage] (blob
/// files), [meta] (small JSON rows), [clearance] ([ClearanceStore]) and
/// [repoAuth] ([RepoAuthStore], optional), plus
/// [client]/[jsRunner]/[webViewFetcher], the same pattern [Source] uses.
class ExtensionManager {
  ExtensionManager({
    required this.storage,
    required this.meta,
    required this.clearance,
    this.repoAuth,
    this.localStoragePreferences,
    http.Client? client,
    JsRunner? jsRunner,
    WebViewFetcher? webViewFetcher,
  }) : client = client ?? http.Client(),
       _js = jsRunner,
       _webView = webViewFetcher;

  final ExtensionBlobStore storage;
  final ExtensionMetaStore meta;
  final http.Client client;

  /// The app's JavaScript runtime, injected into every built source for
  /// `js`-step pipelines and any future imperative sources. Null in
  /// tests/web → js-gated sources error clearly instead of running.
  final JsRunner? _js;

  /// The app's WebView transport for `webview:true` (CF-hard) sources. Null in
  /// tests/web → those sources fall back to the HTTP client.
  final WebViewFetcher? _webView;

  /// Per-host Cloudflare clearances, wired into every source [buildSource]
  /// builds so a challenge solved once in the WebView replays across requests.
  /// Loaded on the first [buildSources].
  final ClearanceStore clearance;

  /// Basic Auth for repo hosts that require it (see [fetchIndex]); null when
  /// the host app doesn't wire one in (standalone/test use of the engine).
  final RepoAuthStore? repoAuth;

  /// Per-source consent-toggle overrides, wired into every source
  /// [buildSource] builds so a `localStoragePreferences` toggle the user
  /// flipped patches the config's `localStorageSeed` before each `webview`
  /// fetch. Null (the default) means every such toggle just falls back to
  /// its own declared default. Most sources have none at all. Loaded on
  /// the first [buildSources], same as [clearance].
  final LocalStoragePreferenceStore? localStoragePreferences;

  static const _prefix = 'extensions/';

  /// Archive/legacy path of the repo list. The live store is [meta] now; this
  /// names the legacy file imported once (see [loadRepos]) and the entry a
  /// backup still carries it under (see the app's `BackupService`).
  static const reposPath = '${_prefix}repos.json';

  /// [meta] key for the repo URL list (a `{repos: [...]}` blob); shared with
  /// the app's `BackupService`, which carries it in/out of backups.
  static const reposKey = 'extensionRepos';

  /// Pseudo-URL scheme for a repo backed by a locally-picked file instead of
  /// an HTTP index (see [addLocalRepo]).
  static const _localScheme = 'local:';

  /// Where a local-file repo's raw index bytes are stored, under [_prefix]
  /// so it rides along with every other extension blob in the app's
  /// `BackupService` (whose backup selection is a plain `extensions/` prefix
  /// match), with no special-casing needed there.
  static const _localReposPrefix = '${_prefix}local-repos/';

  String _extensionPath(String pkg) => '$_prefix$pkg.json';

  /// Whether [repo] is a local-file repo (added via [addLocalRepo]) rather
  /// than a network URL. Callers use this to skip URL-only affordances
  /// (editing/re-fetching a URL that doesn't exist).
  bool isLocalRepo(String repo) => repo.startsWith(_localScheme);

  /// The display label for a local-file repo: the sanitized name it was
  /// added under (see [addLocalRepo]), or null for a network repo.
  String? localRepoLabel(String repo) =>
      isLocalRepo(repo) ? repo.substring(_localScheme.length) : null;

  String _localRepoBlobPath(String repo) =>
      '$_localReposPrefix${repo.substring(_localScheme.length)}.json';

  Future<List<String>> loadRepos() async {
    final fromMeta = await meta.loadMeta(reposKey);
    if (fromMeta != null) {
      return List<String>.from(fromMeta['repos'] as List<dynamic>? ?? const []);
    }
    // One-time import from the legacy repos.json file, then drop it. A corrupt
    // file reads as empty (the next addRepo writes a fresh list to meta).
    final bytes = await storage.read(reposPath);
    if (bytes == null) return [];
    try {
      final list = List<String>.from(
        jsonDecode(utf8.decode(bytes)) as List<dynamic>,
      );
      await meta.saveMeta(reposKey, {'repos': list});
      await storage.delete(reposPath);
      return list;
    } on Exception {
      return [];
    } on TypeError {
      return [];
    }
  }

  Future<void> _saveRepos(List<String> repos) =>
      meta.saveMeta(reposKey, {'repos': repos});

  /// [meta] key for device-local source preferences: pinned source ids and the
  /// global-search scope + custom set. Stored as a blob and, like all
  /// device-local state, excluded from cloud backup/sync, so pins/search
  /// choices stay per device.
  static const sourcePrefsKey = 'sourcePrefs';

  Future<Map<String, dynamic>> loadSourcePrefs() async =>
      await meta.loadMeta(sourcePrefsKey) ?? const {};

  Future<void> saveSourcePrefs(Map<String, dynamic> prefs) =>
      meta.saveMeta(sourcePrefsKey, prefs);

  Future<List<String>> addRepo(String url) async {
    final repos = await loadRepos();
    if (!repos.contains(url)) {
      repos.add(url);
      await _saveRepos(repos);
    }
    return repos;
  }

  /// Registers [bytes] (a picked repository index or single-extension file)
  /// as a local-file repo; its extensions become browsable exactly like a
  /// network repo's, but installing any of them is still a separate,
  /// explicit step; nothing here gets installed. Returns the synthetic repo
  /// id to treat like any other entry in [loadRepos] (added via [addRepo]).
  ///
  /// Throws a [FormatException] when [bytes] carries nothing installable,
  /// same message [fetchIndex]/a direct single-extension install would.
  Future<String> addLocalRepo(String fileName, Uint8List bytes) async {
    if (parseExtensionsJson(utf8.decode(bytes)).isEmpty) {
      throw const FormatException(
        'No installable extensions in this file (APK-only entries from '
        'Mihon repositories cannot run in a declarative engine)',
      );
    }
    final repos = await loadRepos();
    final slug = _slugify(fileName);
    var id = '$_localScheme$slug';
    var suffix = 2;
    while (repos.contains(id)) {
      id = '$_localScheme$slug-$suffix';
      suffix++;
    }
    await storage.write(_localRepoBlobPath(id), bytes);
    await addRepo(id);
    return id;
  }

  /// A filesystem-safe, reasonably-readable slug for [fileName]: its `.json`
  /// extension dropped and anything but letters/digits/`._-` collapsed to a
  /// dash, used both as the local repo's storage path and (via
  /// [localRepoLabel]) its display fallback.
  String _slugify(String fileName) {
    final base = fileName.replaceAll(RegExp(r'\.json$', caseSensitive: false), '');
    final slug = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    return slug.isEmpty ? 'file' : slug;
  }

  Future<List<String>> removeRepo(String url) async {
    final repos = await loadRepos()
      ..remove(url);
    await _saveRepos(repos);
    if (isLocalRepo(url)) await storage.delete(_localRepoBlobPath(url));
    return repos;
  }

  /// Replaces [oldUrl] with [newUrl], keeping its position in the list.
  /// Unknown [oldUrl] falls back to adding; an already-present [newUrl]
  /// just drops the old entry so the list stays duplicate-free.
  Future<List<String>> updateRepo(String oldUrl, String newUrl) async {
    // Renaming a repo to itself is a no-op for the list; without this, the
    // `repos.contains(newUrl)` check below sees the entry already present
    // (it's the same one) and takes the "duplicate, drop the old one"
    // branch, deleting the only occurrence.
    if (oldUrl == newUrl) return loadRepos();
    final repos = await loadRepos();
    final index = repos.indexOf(oldUrl);
    if (index == -1) return addRepo(newUrl);
    if (repos.contains(newUrl)) {
      repos.removeAt(index);
    } else {
      repos[index] = newUrl;
    }
    await _saveRepos(repos);
    return repos;
  }

  /// Fetches and parses a repository index. Throws a [FormatException]
  /// with a readable message when the URL serves something else (an HTML
  /// error page, a different JSON shape, ...), or when [repoUrl] is a local
  /// repo whose blob has since disappeared.
  ///
  /// A local-file repo ([isLocalRepo]) never touches the network; it reads
  /// back the bytes [addLocalRepo] stored, so it runs through the exact same
  /// parse/cache path as a real HTTP repo instead of a parallel one.
  Future<List<ExtensionInfo>> fetchIndex(String repoUrl) async {
    if (isLocalRepo(repoUrl)) {
      final bytes = await storage.read(_localRepoBlobPath(repoUrl));
      if (bytes == null) {
        throw const FormatException('This local file is no longer available');
      }
      return parseExtensionsJson(utf8.decode(bytes));
    }
    final uri = Uri.parse(repoUrl);
    await repoAuth?.load();
    final response = await client
        .get(
          uri,
          headers: {
            'User-Agent': 'Konimanga/0.1',
            ...?repoAuth?.headersFor(repoUrl),
          },
        )
        .withRequestTimeout(uri);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    try {
      return parseExtensionsJson(response.body);
    } on FormatException {
      throw const FormatException(
        'The repository did not return a valid extension index',
      );
    }
  }

  /// Parses extension JSON: a repository index (list of entries) or a
  /// single extension entry (object). Entries without declarative sources
  /// (e.g. APK-only entries from a Mihon repo) cannot run in a declarative
  /// engine and are dropped. Repo fetching and install-from-file share this,
  /// so both accept identical formats.
  List<ExtensionInfo> parseExtensionsJson(String content) {
    try {
      final entries = switch (jsonDecode(content)) {
        final List<dynamic> list => list,
        final Map<String, dynamic> map => <dynamic>[map],
        _ => throw const FormatException(),
      };
      return entries
          .map((e) => ExtensionInfo.fromJson(e as Map<String, dynamic>))
          .where((e) => e.sources.isNotEmpty)
          .toList();
    } on Exception {
      throw const FormatException('Not a valid extension file or index');
    } on TypeError {
      throw const FormatException('Not a valid extension file or index');
    }
  }

  Future<List<ExtensionInfo>> loadInstalled() async {
    final extensions = <ExtensionInfo>[];
    for (final path in await storage.list(_prefix)) {
      if (path == reposPath || !path.endsWith('.json')) continue;
      final bytes = await storage.read(path);
      if (bytes == null) continue;
      // One unreadable extension file must not take down the whole source
      // registry (this runs at startup); the extension just isn't offered
      // until it's reinstalled.
      try {
        extensions.add(
          ExtensionInfo.fromJson(
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
          ),
        );
      } on Exception {
        continue;
      } on TypeError {
        continue;
      }
    }
    return extensions;
  }

  Future<void> install(ExtensionInfo extension) => storage.write(
    _extensionPath(extension.pkg),
    utf8.encode(jsonEncode(extension.toJson())),
  );

  Future<void> uninstall(String pkg) => storage.delete(_extensionPath(pkg));

  /// The engine matching [config]'s dialect, wired to the shared Cloudflare
  /// clearance store so a solved challenge replays on its requests.
  Source buildSource(AnySourceConfig config) => (switch (config) {
    ApiSourceConfig c => apiSource(c, client: client),
    SourceConfig c => htmlSource(
      c,
      client: client,
      webViewFetcher: _webView,
      jsRunner: _js,
    ),
  })
    ..clearanceStore = clearance
    ..localStoragePreferenceStore = localStoragePreferences;

  /// All usable sources: every source of every installed extension, de-duped
  /// by id, all driven by the same declarative engines. Nothing is bundled:
  /// a fresh install has zero sources until a repository is added (the app
  /// points "Add repository" at a served/published `repo/index.min.json`).
  Future<List<Source>> buildSources() async {
    // Materialize stored clearances once so every built source replays them.
    await clearance.load();
    await localStoragePreferences?.load();
    final seen = <String>{};
    final sources = <Source>[];
    void addSource(Source s) {
      if (seen.add(s.id)) sources.add(s);
    }

    for (final extension in await loadInstalled()) {
      for (final c in extension.sources) {
        addSource(buildSource(c));
      }
    }
    // Imperative (JS-gated) sources need a JS runtime; registered only where one
    // exists (the native app), so absent in tests and on web.
    if (_js != null) {
      for (final s in imperativeSources(client: client, js: _js)) {
        addSource(s);
      }
    }
    return sources;
  }
}
