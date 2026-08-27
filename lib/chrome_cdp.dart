/// A [WebViewFetcher] backed by a real Chrome, over the DevTools Protocol.
///
/// **Its own entrypoint, not part of `koni_dojo.dart`.** This imports
/// `dart:io`, which would break the barrel for web consumers. Import it
/// explicitly:
///
/// ```dart
/// import 'package:koni_dojo/chrome_cdp.dart';
/// ```
///
/// ## What it is for
///
/// Live verification of the scraping path without Flutter or a device: the
/// same configs and the same engine ops the app runs, driven by a real
/// browser, under plain `dart test`. For the great majority of sources —
/// anything not behind an interactive bot wall — that is the whole story.
///
/// ## What it does NOT do: defeat Cloudflare
///
/// It was built hoping it would, and it does not. Measured against a
/// Cloudflare-walled source, one variable at a time, same machine and IP:
///
/// | setup                                            | challenge clears? |
/// |--------------------------------------------------|-------------------|
/// | plain Chrome, fresh profile, no CDP              | yes, under 75s, unattended |
/// | CDP attached, fresh profile                      | no, 3 minutes     |
/// | CDP attached, profile already holding clearance  | no, 3 minutes     |
///
/// Cloudflare refuses the **DevTools connection**, not the browser, the
/// profile, or the fingerprint. Dropping `Runtime.enable` (a documented
/// detection vector) and `--disable-blink-features=AutomationControlled` both
/// failed to change it, and so did handing the session a clearance earned
/// beforehand: it is re-challenged anyway.
///
/// Getting past that means stealth-patching CDP's observable artifacts, which
/// is an arms race with recurring breakage and ongoing maintenance. That is a
/// deliberate non-goal here. An extension running inside an ordinary Chrome is
/// the approach that does work, because it is not an automation connection at
/// all — see `docs/web-extension-transport.md` in the app for the companion
/// extension this project already designed for web.
///
/// So: use this for sources without a bot wall, where it removes the device
/// requirement entirely. For Cloudflare-hard sources the app's visible solver
/// remains the answer, and a live check of those stays manual.
///
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'src/cloudflare_challenge.dart';
import 'src/web_view_fetcher.dart';

/// Where Chrome usually lives, per platform. Overridable via
/// [ChromeCdpFetcher.launch]'s `executable`.
const _chromeCandidates = <String>[
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  r'C:\Program Files\Google\Chrome\Application\chrome.exe',
  r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
];

/// Drives a real Chrome over the DevTools Protocol. See the library doc.
class ChromeCdpFetcher implements WebViewFetcher {
  ChromeCdpFetcher._(this._socket, this._process, this._solveTimeout);

  final WebSocket _socket;
  final Process? _process;

  /// How long to keep waiting once a challenge is on screen.
  ///
  /// Separate from [_settleTimeout] because the two wait for different things.
  /// Settling is a page finishing; a challenge is a **person**, and 25s of
  /// machine patience is not enough for someone to notice a window, read it
  /// and click. Zero in headless mode, where nobody can answer anyway.
  final Duration _solveTimeout;

  /// Empty until [_attach] binds a tab; commands before that go to the
  /// browser target, which is where Target.* has to be sent anyway.
  String _sessionId = '';

  var _nextId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  StreamSubscription<dynamic>? _sub;

  /// Where the tab currently is, so a run of same-origin byte fetches doesn't
  /// re-navigate for each — the same optimisation the WebView transport makes.
  String? _currentUrl;

  /// How long a page gets to settle before the DOM is read anyway.
  static const _settleTimeout = Duration(seconds: 25);
  static const _pollInterval = Duration(milliseconds: 250);

  /// Attaches to a Chrome already listening on [port].
  ///
  /// That Chrome must have been started with `--remote-debugging-port=$port`;
  /// an ordinary desktop Chrome has not been, which is why [launch] is
  /// usually what you want.
  static Future<ChromeCdpFetcher> connect({
    int port = 9222,
    Duration timeout = const Duration(seconds: 10),
    Duration solveTimeout = const Duration(minutes: 3),
  }) => _attach(
    port: port,
    process: null,
    timeout: timeout,
    solveTimeout: solveTimeout,
  );

  /// Browses [url] in a plain Chrome — **no debugging port** — until the
  /// profile holds a Cloudflare clearance, then quits it.
  ///
  /// This exists because of a controlled result: same machine, same IP, same
  /// fresh profile, same flags, one variable changed. Plain Chrome earned
  /// `cf_clearance` in under 75 seconds with nobody touching it; the moment a
  /// DevTools client was attached, the identical page sat on a
  /// non-interactive challenge for three minutes and never cleared. Cloudflare
  /// refuses the debugging connection, not the browser.
  ///
  /// So the sequence matters: earn the clearance without CDP, then attach.
  /// The cookie lives in the profile, and the profile is what [launch] reuses.
  /// Returns immediately when the profile already has one.
  ///
  /// Detection reads the cookie store as bytes rather than as SQLite, so this
  /// needs no database dependency: the cookie's *name* is stored as plain
  /// text, which is all this has to find.
  static Future<bool> warmProfile({
    required String userDataDir,
    required String url,
    String? executable,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (_hasClearance(userDataDir)) return true;
    final exe = executable ?? _findChrome();
    Directory(userDataDir).createSync(recursive: true);
    final process = await Process.start(exe, [
      '--user-data-dir=$userDataDir',
      '--no-first-run',
      '--no-default-browser-check',
      url,
    ]);
    try {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_hasClearance(userDataDir)) return true;
      }
      return false;
    } finally {
      process.kill();
      // Chrome flushes its cookie store on exit; give it that moment before
      // the caller relaunches against the same directory.
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  static bool _hasClearance(String userDataDir) {
    for (final name in ['Cookies', 'Cookies-wal', 'Cookies-journal']) {
      final file = File('$userDataDir/Default/$name');
      if (!file.existsSync()) continue;
      try {
        if (file.readAsBytesSync().let(_containsClearance)) return true;
      } on Object {
        // Locked mid-write by a live Chrome; the next poll sees it.
      }
    }
    return false;
  }

  static String _findChrome() => _chromeCandidates.firstWhere(
    (p) => File(p).existsSync(),
    orElse: () =>
        throw StateError('No Chrome found. Pass `executable:` explicitly.'),
  );

  /// Starts Chrome against a **persistent** [userDataDir] and attaches.
  ///
  /// The persistence is the point: the clearance earned once — by this run
  /// with `headless: false`, or just by browsing in that profile — is still
  /// there next time, which is what makes later runs unattended.
  ///
  /// Defaults to headed. A headless Chrome is far likelier to be challenged,
  /// and the first run may need a human anyway.
  static Future<ChromeCdpFetcher> launch({
    required String userDataDir,
    String? executable,
    int port = 9222,
    bool headless = false,
    String? warmUpUrl,
    Duration timeout = const Duration(seconds: 30),
    Duration solveTimeout = const Duration(minutes: 3),
  }) async {
    final exe = executable ?? _findChrome();
    Directory(userDataDir).createSync(recursive: true);
    if (warmUpUrl != null) {
      await warmProfile(
        userDataDir: userDataDir,
        url: warmUpUrl,
        executable: exe,
      );
    }
    final process = await Process.start(exe, [
      '--remote-debugging-port=$port',
      '--user-data-dir=$userDataDir',
      if (headless) '--headless=new',
      '--no-first-run',
      '--no-default-browser-check',
      // Keeps navigator.webdriver false. Automation is not the thing being
      // hidden — the point is that a real person is driving this window, and
      // the flag is what stops Chrome from claiming otherwise.
      '--disable-blink-features=AutomationControlled',
      // Keeps the run deterministic without touching the fingerprint
      // Cloudflare inspects.
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      'about:blank',
    ]);
    try {
      return await _attach(
        port: port,
        process: process,
        timeout: timeout,
        // Nobody can solve a challenge in a window they cannot see.
        solveTimeout: headless ? Duration.zero : solveTimeout,
      );
    } catch (_) {
      process.kill();
      rethrow;
    }
  }

  static Future<ChromeCdpFetcher> _attach({
    required int port,
    required Process? process,
    required Duration timeout,
    required Duration solveTimeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final client = http.Client();
    String? browserWs;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res = await client.get(
          Uri.parse('http://127.0.0.1:$port/json/version'),
        );
        if (res.statusCode == 200) {
          browserWs =
              (jsonDecode(res.body)
                      as Map<String, dynamic>)['webSocketDebuggerUrl']
                  as String?;
          if (browserWs != null) break;
        }
      } on Object {
        // Chrome is still coming up; keep waiting until the deadline.
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    client.close();
    if (browserWs == null) {
      throw StateError(
        'No Chrome DevTools endpoint on port $port after ${timeout.inSeconds}s. '
        'Start Chrome with --remote-debugging-port=$port, or use launch().',
      );
    }

    final socket = await WebSocket.connect(browserWs);
    final fetcher = ChromeCdpFetcher._(socket, process, solveTimeout)
      .._listen();

    final target = await fetcher._send('Target.createTarget', {
      'url': 'about:blank',
    });
    final attached = await fetcher._send('Target.attachToTarget', {
      'targetId': target['targetId'],
      'flatten': true,
    });
    fetcher._sessionId = attached['sessionId'] as String;
    // Deliberately no Page.enable / Runtime.enable. Enabling the Runtime
    // domain is a documented bot-detection signal — Cloudflare probes for its
    // side effects — and with it on, a walled source's *non-interactive*
    // managed challenge never cleared: a page with nothing to click,
    // spinning until the deadline. Neither domain is needed here, because
    // this polls with Runtime.evaluate and Page.navigate rather than
    // subscribing to events, and both work without their domain enabled.
    return fetcher;
  }

  void _listen() {
    _sub = _socket.listen(_onMessage, onDone: _failAllPending);
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = msg['id'];
    if (id is! int) return; // an event, not a reply
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = msg['error'];
    if (error != null) {
      completer.completeError(StateError('CDP error: ${jsonEncode(error)}'));
      return;
    }
    completer.complete((msg['result'] as Map?)?.cast<String, dynamic>() ?? {});
  }

  void _failAllPending() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('CDP socket closed'));
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, dynamic> params,
  ) {
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': params,
        if (_sessionId.isNotEmpty) 'sessionId': _sessionId,
      }),
    );
    return completer.future;
  }

  /// Evaluates [expression] in the page and returns its value.
  Future<Object?> _eval(String expression) async {
    final result = await _send('Runtime.evaluate', {
      'expression': expression,
      'awaitPromise': true,
      'returnByValue': true,
    });
    final details = result['exceptionDetails'];
    if (details != null) {
      throw StateError('page threw: ${jsonEncode(details)}');
    }
    return (result['result'] as Map?)?['value'];
  }

  Future<void> _setHeaders(Map<String, String>? headers) async {
    if (headers == null || headers.isEmpty) return;
    await _send('Network.enable', const {});
    await _send('Network.setExtraHTTPHeaders', {'headers': headers});
  }

  /// Navigates and waits for the DOM to hold still.
  ///
  /// Same contract as the WebView transport's poll loop, and for the same
  /// reason: `readyState` alone goes true while a challenge is mid-flight, and
  /// a page that never finishes a third-party script never reaches `complete`
  /// at all — so the length holding steady across two reads is the real
  /// signal, with `interactive` accepted alongside `complete`.
  Future<String> _navigateAndRead(String url) async {
    await _send('Page.navigate', {'url': url});
    _currentUrl = url;
    final start = DateTime.now();
    var deadline = start.add(_settleTimeout);
    int? previousLength;
    var stable = 0;
    String? lastGood;
    var announced = false;

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollInterval);
      final state = await _eval('document.readyState');
      if (state != 'complete' && state != 'interactive') continue;
      final html = await _eval('document.documentElement.outerHTML') as String?;
      if (html == null || html.length < 500) continue;

      if (_looksChallenged(html)) {
        // Hand the clock to the human. Solving is a one-time cost per profile:
        // the clearance persists, so later runs never reach this branch.
        if (_solveTimeout > Duration.zero) {
          deadline = start.add(_solveTimeout);
          if (!announced) {
            announced = true;
            // ignore: avoid_print
            print(
              'ChromeCdpFetcher: Cloudflare challenge at $url — solve it in '
              'the Chrome window (waiting up to '
              '${_solveTimeout.inMinutes}m). This profile keeps the clearance, '
              'so this is once, not every run.',
            );
          }
        }
        previousLength = null;
        stable = 0;
        continue;
      }
      lastGood = html;
      if (previousLength == html.length) {
        if (++stable >= 2) return html;
      } else {
        stable = 0;
      }
      previousLength = html.length;
    }
    if (lastGood != null) return lastGood;
    throw CloudflareChallengeException(Uri.parse(url));
  }

  static bool _looksChallenged(String html) =>
      html.contains('Just a moment') ||
      html.contains('cf-challenge-running') ||
      html.contains('/cdn-cgi/challenge-platform');

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? localStorageSeed,
  }) async {
    await _setHeaders(headers);
    if (localStorageSeed != null && localStorageSeed.isNotEmpty) {
      // localStorage is origin-scoped, so land on the origin before seeding.
      await _navigateAndRead(Uri.parse(url).origin);
      for (final entry in localStorageSeed.entries) {
        await _eval(
          'localStorage.setItem(${jsonEncode(entry.key)}, '
          '${jsonEncode(jsonEncode(entry.value))})',
        );
      }
    }
    return _navigateAndRead(url);
  }

  @override
  Future<Uint8List> fetchBytes(
    String url, {
    Map<String, String>? headers,
    bool warmByUrl = false,
    bool viaImgTag = false,
    String? baseUrl,
  }) async {
    await _setHeaders(headers);
    // Read from a page on the site rather than a blank tab: that is what
    // carries the site's cookies and a Referer the CDN will accept, which is
    // the same reason the WebView transport parks on baseUrl first.
    final host = baseUrl?.isNotEmpty == true
        ? baseUrl!
        : (warmByUrl ? url : Uri.parse(url).origin);
    if (_currentUrl != host) await _navigateAndRead(host);

    final base64 = await _eval('''
      (async () => {
        const response = await fetch(${jsonEncode(url)}, {credentials: 'include'});
        if (!response.ok) throw new Error('HTTP ' + response.status);
        const bytes = new Uint8Array(await response.arrayBuffer());
        let binary = '';
        const chunk = 0x8000;
        for (let i = 0; i < bytes.length; i += chunk) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
        }
        return btoa(binary);
      })()
    ''');
    if (base64 is! String || base64.isEmpty) {
      throw StateError('no bytes for $url');
    }
    return base64Decode(base64);
  }

  /// Closes the connection, and the browser if this instance started it.
  Future<void> close() async {
    await _sub?.cancel();
    await _socket.close();
    _process?.kill();
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

bool _containsClearance(List<int> bytes) {
  const needle = [
    0x63, 0x66, 0x5F, 0x63, 0x6C, 0x65, 0x61, 0x72, //
    0x61, 0x6E, 0x63, 0x65, // "cf_clearance"
  ];
  outer:
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
