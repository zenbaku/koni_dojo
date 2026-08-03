// Captures a site icon for each extension into `extensions/icons/<slug>.png`
// (the slug = the config's filename stem). These committed PNGs are the source
// of truth for source icons; `tool/build_repo.dart` inlines them into
// `repo/index.min.json` as `data:` URIs so the app shows them offline.
//
//   dart run tool/capture_icons.dart                    # fetch missing icons
//   dart run tool/capture_icons.dart --force             # re-fetch all (overwrite)
//   dart run tool/capture_icons.dart id1 id2             # only these ids
//   dart run tool/capture_icons.dart --force id1 id2     # re-fetch just these
//
// For each source's baseUrl: fetches the homepage and parses its actual
// `<link rel="icon"|"apple-touch-icon"|"apple-touch-icon-precomposed">` tags
// and `<meta name="msapplication-TileImage">` (largest declared `sizes`
// first, apple-touch-icon preferred, usually the crispest). Most sites
// don't serve an icon at the bare `/apple-touch-icon.png` guess, they
// reference one from wherever their theme/CMS put it (e.g. a WordPress
// `/wp-content/uploads/...` path). Falls back to that root-path guess, then
// Google's favicon service (always PNG, and it has cached icons for some
// sites a direct request can't reach) if the page has no usable tags or
// can't be fetched at all (Cloudflare-walled homepages return a challenge
// page with no real `<link>` tags, not an error; parsing still runs, it
// just won't find anything, which correctly falls through). Saved as
// `<slug>.png` regardless of the real format: Flutter's image codec sniffs
// actual bytes, not the file extension or a data: URI's declared mime type,
// so a JPEG/WebP file just named `.png` still decodes fine; the uniform
// extension is only a naming convention, not a real conversion. Only
// genuinely undecodable formats (.ico, .svg) are rejected: a candidate in
// one of those is silently skipped and the next one tried. Icons are
// committed files; replace any with a nicer image by hand and the build
// will pick it up.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'workspace.dart';

/// Whether [bytes] look like a raster format Flutter's image codec can
/// decode (PNG, JPEG, WebP, GIF, BMP), i.e. not an .ico (a format/container
/// `dart:ui` doesn't support) or an HTML error page served with a 200.
bool _isDecodableImage(List<int> bytes) {
  bool starts(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return true; // PNG
  }
  if (starts([0xFF, 0xD8, 0xFF])) return true; // JPEG
  if (starts([0x47, 0x49, 0x46, 0x38])) return true; // GIF
  if (starts([0x42, 0x4D])) return true; // BMP
  if (bytes.length >= 12 &&
      starts([0x52, 0x49, 0x46, 0x46]) && // "RIFF"
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true; // WebP ("RIFF"....."WEBP")
  }
  return false;
}

Future<List<int>?> _fetchPng(HttpClient client, String url) async {
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) return null;
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
    }
    if (!_isDecodableImage(bytes)) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

Future<String?> _fetchText(HttpClient client, String url) async {
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) return null;
    return await resp.transform(const Utf8Decoder(allowMalformed: true)).join();
  } catch (_) {
    return null;
  }
}

final _tagPattern = RegExp(r'<(link|meta)\b[^>]*>', caseSensitive: false);
final _attrPattern = RegExp('''([a-zA-Z-]+)\\s*=\\s*(?:"([^"]*)"|'([^']*)')''');

Map<String, String> _attrsOf(String tag) {
  final out = <String, String>{};
  for (final m in _attrPattern.allMatches(tag)) {
    out[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
  }
  return out;
}

/// Icon URLs declared in a homepage's `<head>`, best candidate first:
/// apple-touch-icon(s) in document order, then `<link rel="icon">` sorted by
/// declared `sizes` (largest first: a 16x16 favicon is rarely worth using
/// over a 192x192 one), then `msapplication-TileImage`. Relative hrefs
/// resolve against [pageUrl]. Sites with no such tags (including a
/// Cloudflare interstitial, which has none of these) yield an empty list.
List<String> _iconCandidatesFromHtml(String html, Uri pageUrl) {
  final touchIcons = <String>[];
  final sizedIcons = <(int, String)>[];
  String? tileImage;

  for (final tagMatch in _tagPattern.allMatches(html)) {
    final tag = tagMatch.group(0)!;
    final a = _attrsOf(tag);
    if (tagMatch.group(1)!.toLowerCase() == 'meta') {
      if (a['name']?.toLowerCase() == 'msapplication-tileimage' &&
          (a['content'] ?? '').isNotEmpty) {
        tileImage = pageUrl.resolve(a['content']!).toString();
      }
      continue;
    }
    final href = a['href'];
    if (href == null || href.isEmpty) continue;
    final rels = (a['rel'] ?? '').toLowerCase().split(RegExp(r'\s+'));
    final resolved = pageUrl.resolve(href).toString();
    if (rels.contains('apple-touch-icon') ||
        rels.contains('apple-touch-icon-precomposed')) {
      touchIcons.add(resolved);
    } else if (rels.contains('icon') || rels.contains('shortcut icon')) {
      final sizeMatch = RegExp(r'(\d+)x\d+').firstMatch(a['sizes'] ?? '');
      sizedIcons.add((int.tryParse(sizeMatch?.group(1) ?? '') ?? 0, resolved));
    }
  }
  sizedIcons.sort((x, y) => y.$1.compareTo(x.$1));
  return [
    ...touchIcons,
    ...sizedIcons.map((e) => e.$2),
    if (tileImage != null) tileImage,
  ];
}

Future<void> main(List<String> args) async {
  final ws = Workspace.resolve(args);
  final rest = Workspace.stripArgs(args);
  final force = rest.contains('--force');
  final ids = rest.where((a) => !a.startsWith('--')).toSet();
  final dir = Directory(ws.extensionsDir);
  if (!dir.existsSync()) {
    stderr.writeln(
      'No ${ws.extensionsDir}/ directory for workspace "${ws.name}" '
      '(run from the project root, or check --workspace).',
    );
    exit(1);
  }
  Directory(ws.iconsDir).createSync(recursive: true);

  var files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  var unknownIds = 0;
  if (ids.isNotEmpty) {
    String slugOf(File f) =>
        f.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');
    files = files.where((f) => ids.contains(slugOf(f))).toList();
    final found = files.map(slugOf).toSet();
    for (final id in ids.difference(found)) {
      stderr.writeln('✗ $id: no such extension in ${ws.extensionsDir}');
      unknownIds++;
    }
  }

  final client = HttpClient()
    ..userAgent =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    ..connectionTimeout = const Duration(seconds: 15);

  var ok = 0, miss = unknownIds;
  for (final f in files) {
    final slug = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');
    final out = File('${ws.iconsDir}/$slug.png');
    if (out.existsSync() && !force) {
      print('• $slug: keep existing (--force to refetch)');
      ok++;
      continue;
    }
    final entry = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final sources = (entry['sources'] as List?) ?? const [];
    final baseUrl = sources.isEmpty
        ? ''
        : ((sources.first as Map)['baseUrl'] as String? ?? '');
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) {
      print('✗ $slug: no source baseUrl');
      miss++;
      continue;
    }
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final homepage = await _fetchText(client, base);
    final fromHtml = homepage == null
        ? const <String>[]
        : _iconCandidatesFromHtml(homepage, Uri.parse(base));
    final candidates = [
      ...fromHtml,
      '$base/apple-touch-icon.png',
      '$base/apple-touch-icon-precomposed.png',
      'https://www.google.com/s2/favicons?domain=$host&sz=128',
    ];
    List<int>? bytes;
    String? from;
    for (final c in candidates) {
      bytes = await _fetchPng(client, c);
      if (bytes != null) {
        from = c;
        break;
      }
    }
    if (bytes == null) {
      print('✗ $slug: no PNG icon found for $host');
      miss++;
      continue;
    }
    out.writeAsBytesSync(bytes);
    ok++;
    print('✓ $slug: ${(bytes.length / 1024).toStringAsFixed(1)} KB  ←  $from');
  }
  client.close();

  print('\n$ok captured/kept, $miss missing.');
  print('Now run: dart run tool/build_repo.dart');
  if (miss > 0) exit(1);
}
