import 'dart:typed_data';

/// What a downloaded page's first bytes look like.
///
/// A page fetch can come back with HTTP 200 and still not be a page: a
/// Cloudflare interstitial, a "please log in" wall, or a JSON error body for an
/// expired signed URL are all served as ordinary successful responses. Nothing
/// downstream notices — the bytes land at `0001.jpg`, the chapter is marked
/// downloaded, and because a file at its final path is presumed whole the
/// skip-existing resume never revisits it. The user gets a chapter of broken
/// images with no error anywhere.
///
/// [classifyPageBody] is the cheap guard against that. It is deliberately
/// **asymmetric**: it rejects only bodies that positively look like markup, and
/// accepts anything it doesn't recognize. Requiring a known image signature
/// instead would turn "a source serves a format this list forgot" into a hard
/// download failure — a much worse trade than letting an unrecognized blob
/// through, since the walls this exists to catch are always HTML or JSON.
enum PageBodyKind {
  /// Starts with a known image signature — accept.
  image,

  /// Starts with HTML/XML/JSON — a challenge, login, or error page. Reject.
  wall,

  /// Neither. Accepted (see the asymmetry note above), but worth logging: it
  /// is either an image format missing from [_signatures] or a genuinely odd
  /// response.
  unknown,
}

/// How many leading bytes [classifyPageBody] needs. The longest signature is
/// 12 bytes; the rest is slack for leading whitespace before markup.
const int pageBodyProbeLength = 32;

/// Classifies [head] — the first [pageBodyProbeLength] bytes of a fetched page.
PageBodyKind classifyPageBody(Uint8List head) {
  if (head.isEmpty) return PageBodyKind.wall;
  for (final signature in _signatures) {
    if (signature.matches(head)) return PageBodyKind.image;
  }
  return _looksLikeMarkup(head) ? PageBodyKind.wall : PageBodyKind.unknown;
}

/// True when [head]'s first non-whitespace byte opens HTML/XML (`<`) or
/// JSON (`{`, `[`) — how every challenge, login wall and API error body this
/// guard exists to catch begins. A UTF-8 BOM is skipped along with the
/// whitespace. No image signature in [_signatures] starts with any of those
/// bytes, so this can't shadow a real image.
bool _looksLikeMarkup(Uint8List head) {
  var i = 0;
  if (head.length >= 3 &&
      head[0] == 0xEF &&
      head[1] == 0xBB &&
      head[2] == 0xBF) {
    i = 3;
  }
  while (i < head.length && _isWhitespace(head[i])) {
    i++;
  }
  if (i == head.length) return false;
  final byte = head[i];
  return byte == 0x3C || byte == 0x7B || byte == 0x5B; // '<', '{', '['
}

bool _isWhitespace(int byte) =>
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D;

/// A magic-byte signature: [bytes] expected at [offset].
class _Signature {
  const _Signature(this.offset, this.bytes);

  final int offset;
  final List<int> bytes;

  bool matches(Uint8List head) {
    if (head.length < offset + bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (head[offset + i] != bytes[i]) return false;
    }
    return true;
  }
}

/// Covers `LibraryStore.imageExtensions` — the formats the reader can actually
/// decode. Anything outside it still passes as [PageBodyKind.unknown].
const List<_Signature> _signatures = [
  _Signature(0, [0xFF, 0xD8, 0xFF]), // JPEG
  _Signature(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), // PNG
  _Signature(0, [0x47, 0x49, 0x46, 0x38]), // GIF ("GIF8")
  _Signature(8, [0x57, 0x45, 0x42, 0x50]), // WebP ("WEBP" inside a RIFF)
  _Signature(0, [0x42, 0x4D]), // BMP
  // AVIF and its HEIF siblings: an ISOBMFF box whose type is "ftyp". The brand
  // that follows varies (avif/avis/heic/mif1/…), so match the box type only.
  _Signature(4, [0x66, 0x74, 0x79, 0x70]), // "ftyp"
  _Signature(0, [0xFF, 0x0A]), // JXL, bare codestream
  // JXL in an ISOBMFF container: a 12-byte JXL signature box.
  _Signature(0, [
    0x00,
    0x00,
    0x00,
    0x0C,
    0x4A,
    0x58,
    0x4C,
    0x20,
    0x0D,
    0x0A,
    0x87,
    0x0A,
  ]),
];
