/// Lista da turma e login do aluno no aparelho.
///
/// O professor cadastra a turma no painel e exporta este arquivo para o
/// celular. A criança toca no próprio nome e digita o PIN de quatro dígitos; o
/// aparelho confere o PIN contra o hash da lista, offline. Não há servidor.
///
/// A lista leva só o nome de exibição ("Ana S."), o código pseudônimo e o hash
/// do PIN. A sessão que sai do aparelho leva o código, não o nome: a
/// correspondência fica no banco do professor.
///
/// O hash é o mesmo que `eyelearn/storage/auth.py` grava (PBKDF2-HMAC-SHA256),
/// e `test/roster_test.dart` confere os dois lados contra o mesmo arquivo.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Identificador do formato. Tem de coincidir com `ROSTER_FORMAT` em
/// `eyelearn/storage/store.py`.
const rosterFormat = 'eyelearn-turma';
const rosterFormatVersion = 1;

const pinLength = 4;

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

class Roster {
  final String className;
  final String exportedAt;
  final List<RosterStudent> students;

  const Roster({
    required this.className,
    required this.exportedAt,
    required this.students,
  });

  /// Lê a lista exportada pelo painel.
  ///
  /// Lança [FormatException] se o formato ou a versão não forem os esperados:
  /// aceitar um arquivo qualquer deixaria a criança escolher um nome que não
  /// corresponde a aluno nenhum, e a sessão chegaria ao painel sem dono.
  factory Roster.fromJson(Map<String, dynamic> json) {
    if (json['format'] != rosterFormat) {
      throw const FormatException('o arquivo não é uma lista de turma');
    }
    if (json['format_version'] != rosterFormatVersion) {
      throw FormatException(
        'versão de lista não suportada: ${json['format_version']}',
      );
    }
    final entries = json['students'];
    if (entries is! List) {
      throw const FormatException('lista de turma sem alunos');
    }
    final students = [
      for (final entry in entries.cast<Map<String, dynamic>>())
        RosterStudent(
          code: entry['code'] as String,
          displayName: entry['display_name'] as String,
          pinHash: entry['pin_hash'] as String,
        ),
    ];
    final codes = {for (final s in students) s.code};
    if (codes.length != students.length) {
      throw const FormatException('código de aluno repetido na lista');
    }
    return Roster(
      className: json['class_name'] as String,
      exportedAt: json['exported_at'] as String,
      students: List.unmodifiable(students),
    );
  }

  factory Roster.fromJsonString(String source) =>
      Roster.fromJson(jsonDecode(source) as Map<String, dynamic>);
}

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
