/// Entrega da sessão ao professor, cifrada para ele.
///
/// A sessão sai do aparelho da criança pela internet, para uma caixa de
/// entrega (o Supabase do projeto), e o painel do professor a busca de lá.
/// Para que a caixa guarde só blocos ilegíveis, a sessão vai cifrada para o
/// professor:
///
/// * o painel tem um par de chaves (P-256), criado no cofre; a pública vai no
///   link da turma ([DeliveryKeyPair.publicKeyText]);
/// * o aparelho cria um par descartável por entrega, combina a privada dele
///   com a pública do professor (ECDH) e cifra a sessão com AES-256-GCM
///   ([sealForTeacher]);
/// * só a privada do professor, que fica no cofre dele, abre
///   ([openDelivery]).
///
/// Quem lê a caixa (inclusive o próprio Supabase) vê de que turma é cada
/// bloco e quando chegou, não o conteúdo. A sessão já não leva nome de
/// criança; com isso, tampouco as medidas ficam expostas.
///
/// Formato, em base64url sem preenchimento:
///
///     versão (1) | pública descartável (33, comprimida) | nonce (12) | cifra + etiqueta
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

const deliveryVersion = 1;
const _aad = 'eyelearn-entrega';
const _publicBytes = 33;
const _nonceBytes = 12;

final _domain = pc.ECCurve_secp256r1();

pc.SecureRandom _secureRandom() {
  final random = math.Random.secure();
  return pc.FortunaRandom()
    ..seed(pc.KeyParameter(Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)))));
}

/// O par de chaves do professor.
class DeliveryKeyPair {
  final BigInt privateKey;
  final Uint8List publicKey;

  const DeliveryKeyPair(this.privateKey, this.publicKey);

  factory DeliveryKeyPair.generate() {
    final generator = pc.ECKeyGenerator()
      ..init(pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(_domain), _secureRandom()));
    final pair = generator.generateKeyPair();
    return DeliveryKeyPair(
        pair.privateKey.d!, pair.publicKey.Q!.getEncoded(true));
  }

  /// A privada em hexadecimal, para o cofre.
  String get privateKeyHex => privateKey.toRadixString(16);

  factory DeliveryKeyPair.fromPrivateHex(String hex) {
    final d = BigInt.parse(hex, radix: 16);
    final q = (_domain.G * d)!;
    return DeliveryKeyPair(d, q.getEncoded(true));
  }

  /// A pública em base64url, para o link (44 caracteres).
  String get publicKeyText => _b64(publicKey);
}

/// Decodifica a pública que veio no link. Lança [FormatException] se não for
/// um ponto da curva.
Uint8List parseDeliveryPublicKey(String text) {
  final bytes = _unb64(text);
  if (bytes.length != _publicBytes) {
    throw const FormatException('chave de entrega inválida');
  }
  try {
    _domain.curve.decodePoint(bytes);
  } on ArgumentError {
    throw const FormatException('chave de entrega inválida');
  }
  return bytes;
}

/// Cifra [plain] para o professor dono de [teacherPublic].
String sealForTeacher(List<int> plain, Uint8List teacherPublic) {
  final ephemeral = DeliveryKeyPair.generate();
  final key =
      _sharedKey(ephemeral.privateKey, teacherPublic, ephemeral.publicKey);
  final random = math.Random.secure();
  final nonce = Uint8List.fromList(
      List<int>.generate(_nonceBytes, (_) => random.nextInt(256)));
  final body = _gcm(true, key, nonce).process(Uint8List.fromList(plain));
  return _b64((BytesBuilder()
        ..addByte(deliveryVersion)
        ..add(ephemeral.publicKey)
        ..add(nonce)
        ..add(body))
      .toBytes());
}

/// Abre uma entrega com a privada do professor.
///
/// Lança [FormatException] se o bloco estiver cortado, for de outra versão
/// ou não for para esta chave.
Uint8List openDelivery(String sealed, DeliveryKeyPair teacher) {
  final Uint8List blob;
  try {
    blob = _unb64(sealed.trim());
  } on FormatException {
    throw const FormatException('entrega corrompida');
  }
  if (blob.length < 1 + _publicBytes + _nonceBytes + 16 ||
      blob[0] != deliveryVersion) {
    throw const FormatException('entrega corrompida ou de outra versão');
  }
  final ephemeral = blob.sublist(1, 1 + _publicBytes);
  final nonce = blob.sublist(1 + _publicBytes, 1 + _publicBytes + _nonceBytes);
  final Uint8List key;
  try {
    key = _sharedKey(teacher.privateKey, ephemeral, ephemeral);
  } on ArgumentError {
    throw const FormatException('entrega corrompida');
  }
  try {
    return _gcm(false, key, nonce)
        .process(blob.sublist(1 + _publicBytes + _nonceBytes));
  } on pc.InvalidCipherTextException {
    throw const FormatException('entrega de outra turma ou outro professor');
  } on ArgumentError {
    throw const FormatException('entrega de outra turma ou outro professor');
  }
}

/// Chave AES do segredo ECDH: SHA-256 do rótulo, do segredo e da pública
/// descartável (amarra a chave a esta entrega).
Uint8List _sharedKey(
    BigInt privateKey, Uint8List otherPublic, Uint8List ephemeralPublic) {
  final point = _domain.curve.decodePoint(otherPublic)!;
  final agreement = pc.ECDHBasicAgreement()
    ..init(pc.ECPrivateKey(privateKey, _domain));
  final secret = agreement.calculateAgreement(pc.ECPublicKey(point, _domain));
  final secretBytes = _bigIntBytes(secret, 32);
  return Uint8List.fromList(sha256.convert(
      [...utf8.encode(_aad), ...secretBytes, ...ephemeralPublic]).bytes);
}

pc.GCMBlockCipher _gcm(bool encrypt, Uint8List key, Uint8List nonce) =>
    pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        encrypt,
        pc.AEADParameters(pc.KeyParameter(key), 128, nonce,
            Uint8List.fromList(utf8.encode(_aad))),
      );

Uint8List _bigIntBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unb64(String text) => base64Url.decode(base64Url.normalize(text));
