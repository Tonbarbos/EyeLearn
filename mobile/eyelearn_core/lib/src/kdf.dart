/// Derivação de chave usada pelo PIN, pelo link da turma e pelo cofre.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 (RFC 8018, seção 5.2).
Uint8List pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int keyLength,
) {
  final hmac = Hmac(sha256, password);
  final output = Uint8List(keyLength);
  const blockSize = 32;
  final blocks = (keyLength + blockSize - 1) ~/ blockSize;

  for (var block = 1; block <= blocks; block++) {
    final first = [
      ...salt,
      (block >> 24) & 0xff,
      (block >> 16) & 0xff,
      (block >> 8) & 0xff,
      block & 0xff,
    ];
    var u = hmac.convert(first).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < blockSize; j++) {
        t[j] ^= u[j];
      }
    }
    final offset = (block - 1) * blockSize;
    final length = math.min(blockSize, keyLength - offset);
    output.setRange(offset, offset + length, t);
  }
  return output;
}
