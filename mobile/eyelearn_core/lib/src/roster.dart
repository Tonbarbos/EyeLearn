/// A turma no aparelho: alunos, atividades de casa e login do aluno.
///
/// A atividade é dever de casa. O professor manda às famílias um link e um
/// código de turma; o pacote da turma vai cifrado no próprio link, depois do
/// `#` (ver [Roster.openLink] e `eyelearn/storage/package.py`). Em casa, o
/// responsável abre o link e digita o código uma vez; a criança toca no
/// próprio nome e digita o PIN, conferido aqui mesmo, offline.
///
/// O pacote leva só o nome de exibição ("Ana S."), o código pseudônimo e o
/// hash do PIN de cada aluno, e as atividades com tarefa e prazo. A sessão que
/// sai do aparelho leva o código do aluno e o da atividade, não o nome.
///
/// O hash do PIN é o mesmo que `eyelearn/storage/auth.py` grava
/// (PBKDF2-HMAC-SHA256), e `test/roster_test.dart` confere os dois lados
/// contra o mesmo arquivo.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

/// Identificador do formato. Tem de coincidir com `ROSTER_FORMAT` em
/// `eyelearn/storage/store.py`.
const rosterFormat = 'eyelearn-turma';

/// Versão 3: pacote compacto, com atividades, que chega pelo link.
const rosterFormatVersion = 3;

const pinLength = 4;

/// Parâmetros do pacote cifrado; iguais aos de `eyelearn/storage/package.py`.
const packageVersion = 1;
const _saltBytes = 16;
const _nonceBytes = 12;
const _tagBytes = 16;
const packageKdfIterations = 50000;
const _aad = 'eyelearn-turma';

/// Chave do fragmento do link: `https://.../#t=<pacote>`.
const packageFragmentKey = 't';

class RosterStudent {
  final String code;
  final String displayName;
  final String pinHash;

  const RosterStudent({
    required this.code,
    required this.displayName,
    required this.pinHash,
  });

  /// Se o PIN digitado confere. Ver [verifyPin].
  bool checkPin(String pin) => verifyPin(pin, pinHash);
}

/// Em que pé está uma atividade para um aluno.
enum HomeworkStatus {
  /// Ainda não começou: aparece com a data de início.
  upcoming,

  /// Dentro do prazo e não feita.
  pending,

  /// Já feita neste aparelho.
  done,

  /// Prazo encerrado sem ter sido feita.
  closed,
}

class HomeworkActivity {
  /// Vai na sessão: é o que o painel usa para ligar a gravação à atividade.
  final String code;
  final String task;

  /// Dia de início, sem hora (o primeiro instante do dia, no fuso local).
  final DateTime opensOn;

  /// Fim do prazo, com fuso.
  final DateTime dueAt;

  const HomeworkActivity({
    required this.code,
    required this.task,
    required this.opensOn,
    required this.dueAt,
  });

  HomeworkStatus statusAt(DateTime now, {required bool done}) {
    if (done) return HomeworkStatus.done;
    if (now.isAfter(dueAt)) return HomeworkStatus.closed;
    if (now.isBefore(opensOn)) return HomeworkStatus.upcoming;
    return HomeworkStatus.pending;
  }
}

class Roster {
  final String className;

  /// Identificador público da turma.
  final String classUid;

  final String exportedAt;
  final List<RosterStudent> students;
  final List<HomeworkActivity> activities;

  const Roster({
    required this.className,
    required this.classUid,
    required this.exportedAt,
    required this.students,
    this.activities = const [],
  });

  /// Lê o pacote já decifrado (o JSON compacto do painel).
  ///
  /// Lança [FormatException] se o formato ou a versão não forem os esperados:
  /// aceitar um pacote qualquer deixaria a criança escolher um nome que não
  /// corresponde a aluno nenhum, e a sessão chegaria ao painel sem dono.
  factory Roster.fromJson(Map<String, dynamic> json) {
    if (json['format'] != rosterFormat) {
      throw const FormatException('o link não é de uma turma do EyeLearn');
    }
    if (json['format_version'] != rosterFormatVersion) {
      throw FormatException(
        'versão de turma não suportada: ${json['format_version']}; '
        'peça ao professor um link novo',
      );
    }
    final iterations = json['pin_iterations'] as int;
    final entries = json['students'];
    if (entries is! List) {
      throw const FormatException('turma sem alunos');
    }
    final students = [
      for (final entry in entries.cast<List<dynamic>>())
        RosterStudent(
          code: entry[0] as String,
          displayName: entry[1] as String,
          pinHash: 'pbkdf2-sha256\$$iterations'
              '\$${_hex(_unb64(entry[2] as String))}'
              '\$${_hex(_unb64(entry[3] as String))}',
        ),
    ];
    final codes = {for (final s in students) s.code};
    if (codes.length != students.length) {
      throw const FormatException('código de aluno repetido na turma');
    }
    final activities = [
      for (final entry
          in ((json['activities'] as List?) ?? const []).cast<List<dynamic>>())
        HomeworkActivity(
          code: entry[0] as String,
          task: entry[1] as String,
          opensOn: DateTime.parse(entry[2] as String),
          dueAt: DateTime.parse(entry[3] as String),
        ),
    ];
    return Roster(
      className: json['class_name'] as String,
      classUid: json['class_uid'] as String,
      exportedAt: json['exported_at'] as String,
      students: List.unmodifiable(students),
      activities: List.unmodifiable(activities),
    );
  }

  factory Roster.fromJsonString(String source) =>
      Roster.fromJson(jsonDecode(source) as Map<String, dynamic>);

  /// Decifra o pacote do link com o código da turma.
  ///
  /// Lança [FormatException] com uma frase para a tela: código errado, link
  /// cortado ou de outra versão. Código errado e link alterado dão o mesmo
  /// erro -- a cifra autenticada não distingue, e não precisa.
  static String openSealed(String sealed, String code) {
    final Uint8List blob;
    try {
      blob = _unb64(sealed);
    } on FormatException {
      throw const FormatException('o link está incompleto');
    }
    if (blob.length < 1 + _saltBytes + _nonceBytes + _tagBytes ||
        blob[0] != packageVersion) {
      throw const FormatException(
        'o link está incompleto ou é de outra versão',
      );
    }
    final salt = blob.sublist(1, 1 + _saltBytes);
    final nonce = blob.sublist(1 + _saltBytes, 1 + _saltBytes + _nonceBytes);
    final sealedBody = blob.sublist(1 + _saltBytes + _nonceBytes);
    final key = pbkdf2Sha256(
      ascii.encode(normalizeClassCode(code)),
      salt,
      packageKdfIterations,
      32,
    );
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        false,
        pc.AEADParameters(
          pc.KeyParameter(key),
          _tagBytes * 8,
          nonce,
          Uint8List.fromList(ascii.encode(_aad)),
        ),
      );
    try {
      return utf8.decode(cipher.process(sealedBody));
    } on pc.InvalidCipherTextException {
      throw const FormatException('o código da turma não confere');
    } on ArgumentError {
      throw const FormatException('o código da turma não confere');
    }
  }

  /// O link inteiro, ou só o fragmento, mais o código -> a turma.
  factory Roster.openLink(String linkOrFragment, String code) =>
      Roster.fromJsonString(openSealed(fragmentOf(linkOrFragment), code));

  /// O pacote dentro de um link `...#t=<pacote>`, ou o próprio texto.
  static String fragmentOf(String linkOrFragment) {
    final text = linkOrFragment.trim();
    final hash = text.indexOf('#');
    final fragment = hash >= 0 ? text.substring(hash + 1) : text;
    const prefix = '$packageFragmentKey=';
    return fragment.startsWith(prefix)
        ? fragment.substring(prefix.length)
        : fragment;
  }
}

/// Código da turma como digitado: sem hífen nem espaço, em maiúsculas.
String normalizeClassCode(String code) =>
    code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

Uint8List _unb64(String text) => base64Url.decode(base64Url.normalize(text));

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Confere o PIN contra `pbkdf2-sha256$iterações$sal$chave` (hex).
///
/// Devolve `false` para hash malformado, em vez de lançar: um registro
/// corrompido não pode travar a tela de login nem abri-la. A comparação final
/// não para no primeiro byte diferente.
bool verifyPin(String pin, String stored) {
  final parts = stored.split(r'$');
  if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
  final iterations = int.tryParse(parts[1]);
  if (iterations == null || iterations <= 0 || iterations > 10000000) {
    return false;
  }
  final salt = _fromHex(parts[2]);
  final expected = _fromHex(parts[3]);
  if (salt == null || expected == null || expected.isEmpty) return false;

  final derived = pbkdf2Sha256(
    utf8.encode(pin),
    salt,
    iterations,
    expected.length,
  );
  var difference = 0;
  for (var i = 0; i < expected.length; i++) {
    difference |= derived[i] ^ expected[i];
  }
  return difference == 0;
}

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

Uint8List? _fromHex(String hex) {
  if (hex.length.isOdd) return null;
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final value = int.tryParse(hex.substring(2 * i, 2 * i + 2), radix: 16);
    if (value == null) return null;
    bytes[i] = value;
  }
  return bytes;
}

/// Bloqueio temporário depois de PINs errados seguidos.
///
/// É o que de fato protege o PIN: quatro dígitos são dez mil combinações, e
/// nenhum hash impede quem pode testar todas. Cinco erros bloqueiam aquele
/// aluno por um minuto, e cada novo bloqueio dobra o tempo. Mesma regra de
/// `AttemptLimiter` no Python.
///
/// O estado fica na memória: fechar e abrir o aplicativo zera o contador. Num
/// aparelho que fica com o professor durante a atividade, isso basta; contra
/// quem leva o celular para casa, quem protege é o bloqueio de tela dele.
class PinAttemptLimiter {
  final int maxFailures;
  final Duration baseLockout;
  final DateTime Function() _clock;

  final _failures = <String, int>{};
  final _lockouts = <String, int>{};
  final _lockedUntil = <String, DateTime>{};

  PinAttemptLimiter({
    this.maxFailures = 5,
    this.baseLockout = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  Duration remainingLockout(String code) {
    final until = _lockedUntil[code];
    if (until == null) return Duration.zero;
    final remaining = until.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool isLocked(String code) => remainingLockout(code) > Duration.zero;

  void recordFailure(String code) {
    final count = (_failures[code] ?? 0) + 1;
    _failures[code] = count;
    if (count >= maxFailures) {
      final lockouts = _lockouts[code] ?? 0;
      _lockedUntil[code] = _clock().add(baseLockout * (1 << lockouts));
      _lockouts[code] = lockouts + 1;
      _failures[code] = 0;
    }
  }

  void recordSuccess(String code) {
    _failures.remove(code);
    _lockouts.remove(code);
    _lockedUntil.remove(code);
  }

  /// Tenta o login: confere o bloqueio, o PIN e registra o resultado.
  PinResult attempt(RosterStudent student, String pin) =>
      lockedResult(student.code) ??
      register(student.code, accepted: student.checkPin(pin));

  /// O resultado de bloqueio, se o aluno estiver bloqueado; `null` se não.
  ///
  /// Junto com [register], separa a conferência do PIN -- que custa vinte mil
  /// rodadas de HMAC e, no aparelho, roda fora da linha da interface -- da
  /// contagem de tentativas, que é estado e fica nesta.
  PinResult? lockedResult(String code) {
    final remaining = remainingLockout(code);
    return remaining > Duration.zero ? PinResult.locked(remaining) : null;
  }

  /// Registra uma conferência já feita e diz o que mostrar.
  PinResult register(String code, {required bool accepted}) {
    if (accepted) {
      recordSuccess(code);
      return const PinResult.accepted();
    }
    recordFailure(code);
    return lockedResult(code) ?? const PinResult.rejected();
  }
}

enum PinOutcome { accepted, rejected, locked }

class PinResult {
  final PinOutcome outcome;
  final Duration lockout;

  const PinResult.accepted()
      : outcome = PinOutcome.accepted,
        lockout = Duration.zero;
  const PinResult.rejected()
      : outcome = PinOutcome.rejected,
        lockout = Duration.zero;
  const PinResult.locked(this.lockout) : outcome = PinOutcome.locked;
}
