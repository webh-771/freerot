// OWNER: data agent. AES envelope used by the official ShortMax web API
// (shortweb.shorttv.live/app-api). AES-128-CBC, PKCS7, key == iv ==
// UTF-8 "shortwebapiaesen", payload base64-encoded.
import 'dart:convert';

import 'package:encrypt/encrypt.dart' as enc;

final enc.Key _key = enc.Key.fromUtf8('shortwebapiaesen');
final enc.IV _iv = enc.IV.fromUtf8('shortwebapiaesen');
final enc.Encrypter _aes = enc.Encrypter(
  enc.AES(_key, mode: enc.AESMode.cbc, padding: 'PKCS7'),
);

/// JSON-encodes [payload] and returns the base64 AES ciphertext body.
String officialEncrypt(Object? payload) =>
    _aes.encrypt(jsonEncode(payload), iv: _iv).base64;

/// Decrypts a base64 AES response body and JSON-decodes it.
Object? officialDecrypt(String body) {
  final cleaned = body.trim().replaceAll('"', '');
  return jsonDecode(_aes.decrypt64(cleaned, iv: _iv));
}
