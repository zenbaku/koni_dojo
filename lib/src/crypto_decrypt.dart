import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;

/// Decrypts the `{"ct": "…", "iv": "…", "s": "…"}` envelope a handful of sites
/// use for "chapter protector" style page-list obfuscation (CryptoJS's
/// passphrase-mode `AES.encrypt(json, password)` with a custom formatter that
/// serializes ciphertext/iv/salt as separate JSON fields instead of the
/// library's default single `Salted__…` blob; not tied to any one plugin,
/// this exact shape recurs across sites). [dataJson] is that JSON text;
/// [password] is the passphrase (found elsewhere on the page, not derivable
/// from the blob itself). Returns the decrypted UTF-8 plaintext, or '' if
/// [dataJson] is malformed or decryption/padding fails; callers degrade to
/// an empty result rather than throwing, matching the rest of the pipeline's
/// parse failures.
///
/// Key derivation is OpenSSL's classic `EVP_BytesToKey` (iterated MD5 over
/// password+salt) for a 256-bit key, CryptoJS's default KDF for passphrase
/// mode. The IV is *not* re-derived from it: it's read straight from the
/// envelope's own `iv` field, which is how the sites using this shape ship it
/// (redundant with what EVP_BytesToKey would derive, but explicit).
String decryptAesJson(String dataJson, String password) {
  final Object? decoded;
  try {
    decoded = jsonDecode(dataJson);
  } on FormatException {
    return '';
  }
  if (decoded is! Map || password.isEmpty) return '';
  final ctB64 = decoded['ct'];
  final ivHex = decoded['iv'];
  final saltHex = decoded['s'];
  if (ctB64 is! String || ivHex is! String || saltHex is! String) return '';

  final Uint8List ciphertext;
  final Uint8List iv;
  final Uint8List salt;
  try {
    ciphertext = base64.decode(ctB64);
    iv = _hexDecode(ivHex);
    salt = _hexDecode(saltHex);
  } catch (_) {
    return '';
  }
  if (iv.length != 16 || ciphertext.isEmpty || ciphertext.length % 16 != 0) {
    return '';
  }

  final key = _evpBytesToKey(utf8.encode(password), salt, 32);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));
  final output = Uint8List(ciphertext.length);
  var offset = 0;
  while (offset < ciphertext.length) {
    offset += cipher.processBlock(ciphertext, offset, output, offset);
  }
  final unpadded = _stripPkcs7(output);
  if (unpadded == null) return '';
  try {
    return utf8.decode(unpadded);
  } on FormatException {
    return '';
  }
}

/// OpenSSL's `EVP_BytesToKey` with MD5 (CryptoJS's default `OpenSSLKdf`):
/// `D_i = MD5(D_{i-1} || password || salt)`, concatenated until there are
/// [keyLen] bytes.
Uint8List _evpBytesToKey(List<int> password, Uint8List salt, int keyLen) {
  final out = BytesBuilder();
  var prev = <int>[];
  while (out.length < keyLen) {
    final block = md5.convert([...prev, ...password, ...salt]).bytes;
    out.add(block);
    prev = block;
  }
  return out.toBytes().sublist(0, keyLen);
}

Uint8List? _stripPkcs7(Uint8List data) {
  if (data.isEmpty) return null;
  final pad = data.last;
  if (pad < 1 || pad > 16 || pad > data.length) return null;
  return data.sublist(0, data.length - pad);
}

Uint8List _hexDecode(String hex) {
  final clean = hex.length.isOdd ? '0$hex' : hex;
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
