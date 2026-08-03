import 'dart:convert';

import 'package:http/http.dart' as http;

/// Decodes an HTTP response body honouring its charset, defaulting to UTF-8.
///
/// `http.Response.body` decodes using the Content-Type header's charset but
/// falls back to **latin1** when the header omits one, which garbles UTF-8
/// pages that don't declare a charset (the common case for scraped manga
/// sources: accented titles and non-Latin scripts turn to mojibake). This
/// instead honours a valid header charset, else sniffs an HTML `<meta charset>`,
/// else defaults to UTF-8 (lenient), matching how a browser and Jsoup treat an
/// undeclared HTML or JSON body.
String decodeHttpBody(http.Response response) {
  final bytes = response.bodyBytes;
  final encoding =
      _encodingForName(_charsetOf(response.headers['content-type'])) ??
      _sniffMetaCharset(bytes) ??
      utf8;
  try {
    return encoding.decode(bytes);
  } catch (_) {
    // A declared charset that the bytes don't actually satisfy: don't fail the
    // fetch, fall back to lenient UTF-8 (replacement chars over an exception).
    return utf8.decode(bytes, allowMalformed: true);
  }
}

String? _charsetOf(String? contentType) {
  if (contentType == null) return null;
  return RegExp(
    r'charset\s*=\s*"?([\w-]+)',
    caseSensitive: false,
  ).firstMatch(contentType)?.group(1);
}

Encoding? _encodingForName(String? name) =>
    name == null ? null : Encoding.getByName(name);

/// Sniffs a `<meta charset=…>` (or `<meta http-equiv="content-type" …>`) from
/// the first 1 KiB of an HTML document, decoded as latin1, a byte-preserving
/// pass, so the ASCII meta tag reads correctly whatever the real body encoding.
/// Returns null when no recognised charset is declared.
Encoding? _sniffMetaCharset(List<int> bytes) {
  final head = latin1.decode(
    bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes,
    allowInvalid: true,
  );
  final meta = RegExp(
    r'<meta[^>]+charset\s*=\s*"?([\w-]+)',
    caseSensitive: false,
  ).firstMatch(head);
  return _encodingForName(meta?.group(1));
}
