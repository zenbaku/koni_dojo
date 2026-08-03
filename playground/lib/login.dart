// The playground's login stack: app-specific session *persistence* (a JSON
// dotfile, same shape as `cloudflare.dart`'s `PlaygroundClearanceStore`) over
// the shared `openLoginSession` in `package:koni_dojo_webview`, so a config
// author can actually exercise a source's `loginUrl` and see whether a
// login-gated corner (details/pages/whatever) comes alive, the same way
// `solveCloudflare` lets them exercise a Cloudflare-walled one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:koni_dojo_webview/koni_dojo_webview.dart' as cfw;

/// One host's captured login session: same shape as `cloudflare.dart`'s
/// private `_Clearance`, kept as its own type (not reused) for the same
/// reason `konimanga`'s `SourceLoginStore` doesn't share a table with
/// `CloudflareClearanceStore`: "logged in" and "Cloudflare-cleared" are
/// different questions even though both replay as a `Cookie`+`User-Agent`
/// pair.
class _Login {
  const _Login({required this.cookie, required this.userAgent});

  final String cookie;
  final String userAgent;

  Map<String, dynamic> toJson() => {'cookie': cookie, 'userAgent': userAgent};

  static _Login? fromJson(Object? json) {
    if (json is! Map) return null;
    final cookie = json['cookie'];
    final userAgent = json['userAgent'];
    if (cookie is! String || cookie.isEmpty || userAgent is! String) {
      return null;
    }
    return _Login(cookie: cookie, userAgent: userAgent);
  }
}

/// Per-host captured-login store, persisted to its own dotfile (separate
/// from `PlaygroundClearanceStore`'s) so a completed login survives
/// playground restarts.
class PlaygroundLoginStore {
  PlaygroundLoginStore({String? path})
    : _path =
          path ??
          '${Platform.environment['HOME'] ?? '.'}/.konimanga_playground_login.json';

  final String _path;
  final Map<String, _Login> _byHost = {};

  Future<void> load() async {
    try {
      final json = jsonDecode(File(_path).readAsStringSync());
      (json as Map).forEach((host, value) {
        final login = _Login.fromJson(value);
        if (login != null) _byHost['$host'] = login;
      });
    } catch (_) {
      // No saved logins yet.
    }
  }

  String _hostOf(String url) => (Uri.tryParse(url)?.host ?? '').toLowerCase();

  /// Whether a login is on file for [url]'s host: a raw presence check, not
  /// a validity one (the site's own session could have expired server-side
  /// since); same caveat as `PlaygroundClearanceStore.hasFor`.
  bool hasFor(String url) => _byHost.containsKey(_hostOf(url));

  void save(String host, {required String cookie, required String userAgent}) {
    _byHost[host.toLowerCase()] = _Login(cookie: cookie, userAgent: userAgent);
    try {
      File(_path).writeAsStringSync(
        jsonEncode({for (final e in _byHost.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {
      // Non-fatal: the login just won't survive a restart.
    }
  }

  /// (host, cookie header) for every saved login, for re-seeding the
  /// WebView cookie jar on startup, same as
  /// `PlaygroundClearanceStore.entries`.
  Iterable<({String host, String cookie})> get entries =>
      _byHost.entries.map((e) => (host: e.key, cookie: e.value.cookie));
}

/// Process-wide seam, mirroring `playgroundClearance`, created lazily so
/// tests (no plugin host) never touch the WebView plugin.
final playgroundLogin = PlaygroundLoginStore();
bool _loginLoaded = false;

Future<void> ensureLoginLoaded() async {
  if (_loginLoaded) return;
  _loginLoaded = true;
  await playgroundLogin.load();
  // A second warmCookieJar call, not merged with cloudflare.dart's: the two
  // stores are loaded independently (this one lazily, on first use of the
  // login UI; clearance eagerly, at startup) and warming is idempotent per
  // host, so there's no ordering requirement between the two calls.
  await cfw.warmCookieJar(playgroundLogin.entries);
}

/// Opens the login WebView for [url] and captures the resulting session into
/// [playgroundLogin]: a thin persistence wrapper over
/// `package:koni_dojo_webview`'s `openLoginSession`, which does the actual
/// visible-WebView flow and cookie capture but never persists anything
/// itself. Mirrors `cloudflare.dart`'s `solveCloudflare` wrapper.
Future<bool> login(Uri url, {BuildContext? context}) async {
  final capture = await cfw.openLoginSession(url, context: context);
  if (capture == null) return false;
  playgroundLogin.save(
    url.host,
    cookie: capture.cookie,
    userAgent: capture.userAgent,
  );
  return true;
}
