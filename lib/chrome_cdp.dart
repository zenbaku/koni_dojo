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
/// ## Why this exists
///
/// The shipped app scrapes through the platform WebView, and has to: iOS and
/// Android offer no way to drive Chrome. But that transport starts every run
/// from a cold cookie jar, so a Cloudflare-walled source serves an
/// *interactive* challenge — which a headless browser cannot clear, because
/// telling a person from a script is the whole point of one. That made live
/// verification of the scraping path impossible to automate.
///
/// A real Chrome with a **persistent profile** solves it: the profile keeps
/// its clearance between runs, and Chrome presents the mainstream fingerprint
/// Cloudflare is tuned for. Measured against natomanga, a profile that had
/// simply been used for ordinary browsing loaded a search page with no
/// challenge at all, while the headless WebView was still being asked to
/// prove itself.
///
/// This changes nothing about the app. [WebViewFetcher] is an injected seam,
/// so this is a second implementation of an interface that already existed —
/// the same configs, engine and tests, pointed at a different browser.
///
/// It also drops the Flutter requirement: this is pure Dart, so a live source
/// test runs under `dart test` with no device.
///
/// ## What it can't do
///
/// Make a *first* challenge disappear. If the profile has no clearance, run
/// with `headless: false` and solve it once by hand; the profile keeps it and
/// every later run is unattended. On a user's phone that remains the app's
/// visible solver, and always will.
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
    Duration timeout = const Duration(seconds: 30),
    Duration solveTimeout = const Duration(minutes: 3),
  }) async {
    final exe =
        executable ??
        _chromeCandidates.firstWhere(
          (p) => File(p).existsSync(),
          orElse: () => throw StateError(
            'No Chrome found. Pass `executable:` explicitly.',
          ),
        );
    Directory(userDataDir).createSync(recursive: true);
    final process = await Process.start(exe, [
      '--remote-debugging-port=$port',
      '--user-data-dir=$userDataDir',
      if (headless) '--headless=new',
      '--no-first-run',
      '--no-default-browser-check',
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
              (jsonDecode(res.body) as Map<String, dynamic>)['webSocketDebuggerUrl']
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

    await fetcher._send('Page.enable', const {});
    await fetcher._send('Runtime.enable', const {});
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
