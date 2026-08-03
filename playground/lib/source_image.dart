// Renders a source's remote image (cover or page preview). For `webview: true`
// sources the images sit behind the same Cloudflare wall as the pages, so a
// plain `Image.network` gets a challenge instead of bytes; those go through
// the WebView's `fetchBytes` (a real browser fetch on the cleared origin).
// Non-webview sources keep the cheap `Image.network` path. Resolved bytes are
// cached process-wide so re-renders and repeat URLs don't refetch.
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'cloudflare.dart';

final _cache = <String, Uint8List>{};
final _inflight = <String, Future<Uint8List>>{};

Future<Uint8List> _loadViaWebView(
  String url,
  Map<String, String> headers, {
  bool warmByUrl = false,
  bool viaImgTag = false,
  String? baseUrl,
  Future<void> Function()? throttle,
}) {
  final cached = _cache[url];
  if (cached != null) return Future.value(cached);
  return _inflight[url] ??= () async {
    try {
      final fetcher = playgroundWebViewFetcher();
      if (fetcher == null) {
        throw StateError('WebView unavailable on this platform');
      }
      // Without this, every visible cover in a grid fires its WebView fetch
      // the instant it's built: an unthrottled burst that can trip a site's
      // rate limiting/soft-blocking in ways `_challengeMarker` doesn't
      // recognize as a Cloudflare challenge, so the "cleared" page it hands
      // back is silently wrong (broken covers; a later stage queued behind
      // the burst, like a tag probe, parsing 0 items from a blocked page).
      // The scraping stages already pace themselves via the source's own
      // `throttle`; this puts cover fetches on the same pace.
      await throttle?.call();
      final bytes = await fetcher.fetchBytes(
        url,
        headers: headers,
        warmByUrl: warmByUrl,
        viaImgTag: viaImgTag,
        baseUrl: baseUrl,
      );
      _cache[url] = bytes;
      return bytes;
    } finally {
      _inflight.remove(url);
    }
  }();
}

class SourceImage extends StatefulWidget {
  const SourceImage({
    super.key,
    required this.url,
    required this.viaWebView,
    this.headers = const {},
    this.warmImageByUrl = false,
    this.warmImageViaImgTag = false,
    this.baseUrl,
    this.throttle,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.blur = false,
  });

  final String url;
  final bool viaWebView;
  final Map<String, String> headers;

  /// See `SourceConfig.warmImageByUrl` / `WebViewFetcher.fetchBytes`'s
  /// `warmByUrl` param. No effect unless [viaWebView] is also true.
  final bool warmImageByUrl;

  /// See `SourceConfig.warmImageViaImgTag` / `WebViewFetcher.fetchBytes`'s
  /// `viaImgTag` param. No effect unless [viaWebView] is also true; takes
  /// precedence over [warmImageByUrl] when both are set. Requires [baseUrl].
  final bool warmImageViaImgTag;

  /// The source's own `baseUrl`, required when [warmImageViaImgTag] is true.
  final String? baseUrl;

  /// See `ProbeState.throttle`: paces this fetch against the source's own
  /// `rateLimit` the same as the scraping stages. No effect unless
  /// [viaWebView] is also true.
  final Future<void> Function()? throttle;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// The workspace's NSFW screen-safety toggle. Heavily blurs the rendered
  /// image; press and hold to peek at the real thing (verifying a cover
  /// selector actually works still needs to see it occasionally).
  final bool blur;

  @override
  State<SourceImage> createState() => _SourceImageState();
}

class _SourceImageState extends State<SourceImage> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.viaWebView && widget.url.isNotEmpty) {
      _future = _loadViaWebView(
        widget.url,
        widget.headers,
        warmByUrl: widget.warmImageByUrl,
        viaImgTag: widget.warmImageViaImgTag,
        baseUrl: widget.baseUrl,
        throttle: widget.throttle,
      );
    }
  }

  @override
  void didUpdateWidget(SourceImage old) {
    super.didUpdateWidget(old);
    if (widget.url != old.url || widget.viaWebView != old.viaWebView) {
      _future = (widget.viaWebView && widget.url.isNotEmpty)
          ? _loadViaWebView(
              widget.url,
              widget.headers,
              warmByUrl: widget.warmImageByUrl,
              viaImgTag: widget.warmImageViaImgTag,
              baseUrl: widget.baseUrl,
              throttle: widget.throttle,
            )
          : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) return _broken(context);

    final Widget content;
    // Non-webview sources: plain network image (cheap, cached by Flutter).
    if (!widget.viaWebView) {
      content = Image.network(
        widget.url,
        headers: widget.headers,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: (_, _, _) => _broken(context),
      );
    } else {
      content = FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return _placeholder(context, const _Spinner());
          }
          if (snap.hasError || snap.data == null) return _broken(context);
          return Image.memory(
            snap.data!,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: (_, _, _) => _broken(context),
          );
        },
      );
    }
    return widget.blur ? _Blurred(child: content) : content;
  }

  Widget _placeholder(BuildContext context, Widget child) => Container(
    width: widget.width,
    height: widget.height,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: child,
  );

  Widget _broken(BuildContext context) => _placeholder(
    context,
    Icon(
      Icons.broken_image_outlined,
      color: Theme.of(context).colorScheme.outline,
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// Heavily blurs [child]; press and hold reveals it while held. A permanent,
/// un-peekable blur would defeat the point of a *dev tool*: you still need
/// to see the real image occasionally to confirm a cover selector works.
class _Blurred extends StatefulWidget {
  const _Blurred({required this.child});

  final Widget child;

  @override
  State<_Blurred> createState() => _BlurredState();
}

class _BlurredState extends State<_Blurred> {
  bool _peeking = false;

  @override
  Widget build(BuildContext context) {
    // A long-press recognizer, not a plain tap (Listener or GestureDetector
    // onTapDown/Up): a quick tap must still reach the ancestor InkWell's
    // onTap (e.g. "tap a cover to open its details"). Listener achieved
    // that but also let a *held* peek's release fall through as a tap,
    // triggering that same action unintentionally. Long-press is mutually
    // exclusive with tap in the gesture arena: below the long-press
    // threshold it never fires, so a quick tap passes through untouched;
    // once recognized, it wins the arena outright, so releasing after a
    // genuine peek no longer also fires the ancestor's tap.
    return GestureDetector(
      onLongPressStart: (_) => setState(() => _peeking = true),
      onLongPressEnd: (_) => setState(() => _peeking = false),
      onLongPressCancel: () => setState(() => _peeking = false),
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.passthrough,
        children: [
          _peeking
              ? widget.child
              : ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: 30,
                    sigmaY: 30,
                    tileMode: TileMode.decal,
                  ),
                  child: widget.child,
                ),
          if (!_peeking)
            IgnorePointer(
              child: Icon(
                Icons.visibility_off,
                size: 20,
                color: Colors.white.withValues(alpha: 0.85),
                shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
              ),
            ),
        ],
      ),
    );
  }
}

/// Non-webview fetch used by callers that need raw bytes (kept alongside the
/// widget so the caching policy lives in one place).
Future<Uint8List> fetchImageBytes(
  String url, {
  required bool viaWebView,
  Map<String, String> headers = const {},
}) async {
  if (viaWebView) return _loadViaWebView(url, headers);
  final cached = _cache[url];
  if (cached != null) return cached;
  final res = await http.get(Uri.parse(url), headers: headers);
  if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
  return _cache[url] = res.bodyBytes;
}
