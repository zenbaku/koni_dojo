// The playground's Cloudflare stack: app-specific clearance *persistence*
// (a JSON dotfile) over the shared solver/fetcher in `package:koni_dojo_webview`;
// konimanga's own persistence (a database row) is the only other piece a
// consuming app still needs to write; everything else (the WebView fetcher,
// the two-stage solver, the challenge-detection heuristic, the diagnostic
// log) lives in that package now, shared instead of duplicated.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:koni_dojo/koni_dojo.dart';
import 'package:koni_dojo_webview/koni_dojo_webview.dart' as cfw;

export 'package:koni_dojo_webview/koni_dojo_webview.dart'
    show
        cloudflareSolveSupported,
        cfLog,
        runWithCfLog,
        pickFields,
        pickDetailsFields,
        PickedFields,
        PickResult,
        DetailsPickResult,
        FieldStep,
        StepMode,
        popularSteps,
        chaptersSteps,
        pagesSteps,
        detailsFields;

/// One host's clearance: the cookie header a browser earned by passing a
/// challenge plus the exact User-Agent that earned it: Cloudflare binds
/// `cf_clearance` to both, so they replay together.
class _Clearance {
  const _Clearance({required this.cookie, required this.userAgent});

  final String cookie;
  final String userAgent;

  Map<String, dynamic> toJson() => {'cookie': cookie, 'userAgent': userAgent};

  static _Clearance? fromJson(Object? json) {
    if (json is! Map) return null;
    final cookie = json['cookie'];
    final userAgent = json['userAgent'];
    if (cookie is! String || cookie.isEmpty || userAgent is! String) {
      return null;
    }
    return _Clearance(cookie: cookie, userAgent: userAgent);
  }
}

/// Per-host [ClearanceStore], persisted to a dotfile so a solved challenge
/// survives playground restarts. Keyed by host (not source id):
/// `cf_clearance` is domain-scoped, so two sources on one domain share it.
class PlaygroundClearanceStore implements ClearanceStore {
  PlaygroundClearanceStore({String? path})
    : _path =
          path ??
          '${Platform.environment['HOME'] ?? '.'}/.konimanga_playground_clearance.json';

  final String _path;
  final Map<String, _Clearance> _byHost = {};

  @override
  Future<void> load() async {
    try {
      final json = jsonDecode(File(_path).readAsStringSync());
      (json as Map).forEach((host, value) {
        final clearance = _Clearance.fromJson(value);
        if (clearance != null) _byHost['$host'] = clearance;
      });
    } catch (_) {
      // No saved clearances yet.
    }
  }

  String _hostOf(String url) => (Uri.tryParse(url)?.host ?? '').toLowerCase();

  /// Whether some clearance is on file for [url]'s host: a raw presence
  /// check, not a validity one (a persisted entry can outlive Cloudflare's
  /// own server-side session). `koni_dojo_webview`'s solver never trusts
  /// this to decide whether to *skip* a solve. See its own docs for why
  /// that shortcut caused a stale-clearance hang.
  bool hasFor(String url) => _byHost.containsKey(_hostOf(url));

  @override
  Map<String, String> headersFor(String url) {
    final clearance = _byHost[_hostOf(url)];
    if (clearance == null) return const {};
    // Merged last over the request's own headers: the UA must override the
    // source's default or Cloudflare re-challenges the mismatched pair.
    return {'Cookie': clearance.cookie, 'User-Agent': clearance.userAgent};
  }

  void save(String host, {required String cookie, required String userAgent}) {
    _byHost[host.toLowerCase()] = _Clearance(
      cookie: cookie,
      userAgent: userAgent,
    );
    try {
      File(_path).writeAsStringSync(
        jsonEncode({for (final e in _byHost.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {
      // Non-fatal: the clearance just won't survive a restart.
    }
  }

  /// (host, cookie header) for every saved clearance, for re-seeding the
  /// WebView cookie jar on startup.
  Iterable<({String host, String cookie})> get entries =>
      _byHost.entries.map((e) => (host: e.key, cookie: e.value.cookie));
}

/// Process-wide seam, created lazily so tests (no plugin host) never touch
/// the WebView plugin. Loaded once from disk on first use.
final playgroundClearance = PlaygroundClearanceStore();
bool _clearanceLoaded = false;

/// How many persisted clearance cookies were confirmed re-seeded into the
/// WebView jar on this launch (read-back verified). > 0 means a previous run's
/// cleared hosts are primed and should skip the cold challenge. Reactive so the
/// UI can show a "reused" indicator once warming finishes.
final warmedClearanceCookies = ValueNotifier<int>(0);

Future<void> ensureClearanceLoaded() async {
  if (_clearanceLoaded) return;
  _clearanceLoaded = true;
  await playgroundClearance.load();
  warmedClearanceCookies.value = await cfw.warmCookieJar(
    playgroundClearance.entries,
  );
}

WebViewFetcher? playgroundWebViewFetcher() => cfw.createWebViewFetcher();

/// Clears a Cloudflare challenge for [url]'s host and captures the clearance
/// into [playgroundClearance]: a thin persistence wrapper over
/// `package:koni_dojo_webview`'s solver, which does the actual two-stage
/// (headless → visible) solve and cookie-jar handling but never persists
/// anything itself.
Future<bool> solveCloudflare(Uri url, {BuildContext? context}) async {
  final capture = await cfw.solveCloudflare(url, context: context);
  if (capture == null) return false;
  playgroundClearance.save(
    url.host,
    cookie: capture.cookie,
    userAgent: capture.userAgent,
  );
  return true;
}
