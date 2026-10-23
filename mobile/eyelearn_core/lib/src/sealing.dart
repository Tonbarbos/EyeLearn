/// Cifra autenticada com chave derivada de um segredo digitado.
///
/// Usada em dois lugares, com o mesmo formato:
///
/// * o **link da turma**, cifrado com o código da turma (o mesmo formato de
///   `eyelearn/storage/package.py`, e a suíte confere byte a byte);
/// * o **cofre do painel do professor**, cifrado com a senha dele, guardado no
///   navegador e na cópia de segurança.
///
/// Formato, em base64url sem preenchimento:
///
///     versão (1 byte) | sal (16) | nonce (12) | texto cifrado + etiqueta GCM
///
/// AES-256-GCM, chave PBKDF2-HMAC-SHA256 do segredo. Os dados associados
/// (`aad`) amarram o texto cifrado ao uso: um cofre não abre como link.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'kdf.dart';

const sealVersion = 1;
const sealSaltBytes = 16;
const sealNonceBytes = 12;
const sealTagBytes = 16;
const sealKeyBytes = 32;

final _random = math.Random.secure();

Uint8List randomBytes(int count) =>
    Uint8List.fromList(List<int>.generate(count, (_) => _random.nextInt(256)));

/// Chave já derivada, com o sal de onde saiu.
///
/// Derivar custa dezenas de milhares de rodadas de HMAC; o painel deriva uma
/// vez ao entrar e reaproveita a chave a cada gravação, com nonce novo.
class SealKey {
  final Uint8List key;
  final Uint8List salt;

  const SealKey(this.key, this.salt);

  factory SealKey.derive(
    String secret,
    int iterations, {
    Uint8List? salt,
  }) {
    final s = salt ?? randomBytes(sealSaltBytes);
    return SealKey(
      pbkdf2Sha256(utf8.encode(secret), s, iterations, sealKeyBytes),
      s,
    );
  }
}

/// Cifra [plain] e devolve o texto em base64url.
String seal(
  List<int> plain,
  SealKey key, {
  required String aad,
  Uint8List? nonce,
}) {
  final n = nonce ?? randomBytes(sealNonceBytes);
  final body =
      _cipher(true, key.key, n, aad).process(Uint8List.fromList(plain));
  final blob = BytesBuilder()
    ..addByte(sealVersion)
    ..add(key.salt)
    ..add(n)
    ..add(body);
  return base64Url.encode(blob.toBytes()).replaceAll('=', '');
}

/// O sal de um texto cifrado, para derivar a chave antes de abrir.
///
/// Lança [FormatException] se o texto não tiver a forma esperada.
Uint8List sealedSalt(String sealed) => _split(sealed).salt;

/// Abre um texto cifrado com a chave já derivada.
///
/// Lança [FormatException] -- com "não confere" se a chave estiver errada ou o
/// texto tiver sido alterado (a cifra autenticada não distingue, e não
/// precisa).
Uint8List openSealedWith(String sealed, SealKey key, {required String aad}) {
  final parts = _split(sealed);
  try {
    return _cipher(false, key.key, parts.nonce, aad).process(parts.body);
  } on pc.InvalidCipherTextException {
    throw const FormatException('não confere');
  } on ArgumentError {
    throw const FormatException('não confere');
  }
}

/// Deriva a chave do segredo e abre.
Uint8List openSealedWithSecret(
  String sealed,
  String secret,
  int iterations, {
  required String aad,
}) =>
    openSealedWith(
      sealed,
      SealKey.derive(secret, iterations, salt: sealedSalt(sealed)),
      aad: aad,
    );

({Uint8List salt, Uint8List nonce, Uint8List body}) _split(String sealed) {
  final Uint8List blob;
  try {
    blob = base64Url.decode(base64Url.normalize(sealed.trim()));
  } on FormatException {
    throw const FormatException('incompleto');
  }
  if (blob.length < 1 + sealSaltBytes + sealNonceBytes + sealTagBytes ||
      blob[0] != sealVersion) {
    throw const FormatException('incompleto ou de outra versão');
  }
  return (
    salt: blob.sublist(1, 1 + sealSaltBytes),
    nonce: blob.sublist(1 + sealSaltBytes, 1 + sealSaltBytes + sealNonceBytes),
    body: blob.sublist(1 + sealSaltBytes + sealNonceBytes),
  );
}

pc.GCMBlockCipher _cipher(
  bool encrypt,
  Uint8List key,
  Uint8List nonce,
  String aad,
) =>
    pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        encrypt,
        pc.AEADParameters(
          pc.KeyParameter(key),
          sealTagBytes * 8,
          nonce,
          Uint8List.fromList(utf8.encode(aad)),
        ),
      );
