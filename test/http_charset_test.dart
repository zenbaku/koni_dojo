import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:koni_dojo/src/http_charset.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a UTF-8 body without a charset header decodes as UTF-8, not latin1',
    () {
      final bytes = utf8.encode('Café — 日本語');
      final res = http.Response.bytes(
        bytes,
        200,
        headers: {'content-type': 'text/html'},
      );
      expect(decodeHttpBody(res), 'Café — 日本語');
      // The old `response.body` path (latin1 fallback) would have mangled it.
      expect(res.body, isNot('Café — 日本語'));
    },
  );

  test('honours an explicit charset in the Content-Type header', () {
    final res = http.Response.bytes(
      latin1.encode('Café'),
      200,
      headers: {'content-type': 'text/html; charset=iso-8859-1'},
    );
    expect(decodeHttpBody(res), 'Café');
  });

  test('sniffs a <meta charset> when the header omits one', () {
    // latin1 bytes, no header charset: only the <meta> reveals the encoding.
    final html =
        '<html><head><meta charset="iso-8859-1"></head><body>café</body></html>';
    final res = http.Response.bytes(
      latin1.encode(html),
      200,
      headers: {'content-type': 'text/html'},
    );
    expect(decodeHttpBody(res), contains('café'));
  });
}
