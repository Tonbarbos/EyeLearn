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
import 'dart:typed_data';

import 'kdf.dart';
import 'sealing.dart';

/// Identificador do formato. Tem de coincidir com `ROSTER_FORMAT` em
/// `eyelearn/storage/store.py`.
const rosterFormat = 'eyelearn-turma';

/// Versão 3: pacote compacto, com atividades, que chega pelo link.
const rosterFormatVersion = 3;

const pinLength = 4;

/// Parâmetros do pacote cifrado; iguais aos de `eyelearn/storage/package.py`.
const packageVersion = sealVersion;
const packageKdfIterations = 50000;
const _aad = 'eyelearn-turma';

/// Chave do fragmento do link: `https://.../#t=<pacote>`.
const packageFragmentKey = 't';

/// Chave do pacote compacto, aberto, no fragmento: `...#p=<pacote>`.
const compactFragmentKey = 'p';

/// Versão do pacote compacto.
const compactFormatVersion = 4;

/// As tarefas, na ordem dos índices do pacote compacto.
const compactTasks = ['syllables', 'text', 'pseudotext'];

/// Sal da etiqueta curta do PIN: tirado do código do aluno, que é único e
/// sorteado, para não precisar ir no link.
List<int> compactPinSalt(String studentCode) =>
    utf8.encode('eyelearn:$studentCode');

/// Bytes da etiqueta curta do PIN.
const compactPinBytes = 4;

const _sep = '|';

/// Tira de um nome os separadores do pacote compacto.
String compactSafe(String text) => text.replaceAll(RegExp('[|;,]'), ' ').trim();

String _compactPinHash(String code, String pin, int iterations) {
  final dot = pin.indexOf('.');
  final (salt, key) = dot >= 0
      ? (_unb64(pin.substring(0, dot)), _unb64(pin.substring(dot + 1)))
      : (compactPinSalt(code), _unb64(pin));
  return 'pbkdf2-sha256\$$iterations\$${_hex(salt)}\$${_hex(key)}';
}

/// Dias desde 1970-01-01, a partir de uma data (só ano, mês e dia contam).
int dayNumber(DateTime day) =>
    DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

DateTime _utcDay(int day) =>
    DateTime.fromMillisecondsSinceEpoch(day * Duration.millisecondsPerDay,
        isUtc: true);

DateTime _localDay(int day) {
  final d = _utcDay(day);
  return DateTime(d.year, d.month, d.day);
}

/// 23:59:59 do dia, num fuso [offsetMinutes] a leste de UTC.
DateTime _dayEnd(int day, int offsetMinutes) {
  final d = _utcDay(day);
  return DateTime.utc(d.year, d.month, d.day, 23, 59, 59)
      .subtract(Duration(minutes: offsetMinutes));
}

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

  /// Chave pública do professor para as entregas (`delivery.dart`); `null`
  /// em link sem ela, e aí a sessão só sai por arquivo.
  final String? deliveryKey;

  const Roster({
    required this.className,
    required this.classUid,
    required this.exportedAt,
    required this.students,
    this.activities = const [],
    this.deliveryKey,
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

  /// Lê o pacote como texto: o JSON da versão 3 ou o texto compacto da 4.
  factory Roster.fromJsonString(String source) {
    if (source.startsWith('$compactFormatVersion$_sep')) {
      return Roster.fromCompact(source);
    }
    return Roster.fromJson(jsonDecode(source) as Map<String, dynamic>);
  }

  /// O pacote compacto (versão 4), que vai aberto no link: `#p=<pacote>`.
  ///
  /// Texto com separadores, não JSON, para o link ficar curto:
  ///
  ///     4|turma|uid|dia|iterações|alunos|atividades|chave
  ///
  /// * alunos, separados por `;`: `código,nome de exibição,PIN`, em que o PIN
  ///   é a etiqueta curta de `compactPinTag` (quatro bytes de PBKDF2, sal
  ///   tirado do código) ou, para aluno cadastrado antes dela, `sal.chave`
  ///   completos;
  /// * atividades, separadas por `;`: `código,tarefa,início,prazo,fuso`, com
  ///   a tarefa pelo índice em [compactTasks], os dias contados desde
  ///   1970-01-01 e o fuso em minutos -- o prazo é sempre o fim do dia,
  ///   23:59:59, no fuso do professor.
  ///
  /// * chave: a pública de entrega do professor (opcional).
  ///
  /// Quatro bytes de PIN bastam: quem tem o link pode testar as dez mil
  /// combinações de quatro dígitos com qualquer tamanho de hash. O que
  /// protege o PIN é o bloqueio depois de erros seguidos, na tela.
  factory Roster.fromCompact(String source) {
    final fields = source.split(_sep);
    // Sétimo campo opcional: a chave de entrega, que veio depois.
    if (fields.length < 7 ||
        fields.length > 8 ||
        fields[0] != '$compactFormatVersion') {
      throw const FormatException(
          'link de turma de outra versão; peça ao professor um link novo');
    }
    final iterations = int.parse(fields[4]);
    List<List<String>> rows(String text) => text.isEmpty
        ? const []
        : [for (final row in text.split(';')) row.split(',')];
    final students = [
      for (final row in rows(fields[5]))
        RosterStudent(
          code: row[0],
          displayName: row[1],
          pinHash: _compactPinHash(row[0], row[2], iterations),
        ),
    ];
    if ({for (final s in students) s.code}.length != students.length) {
      throw const FormatException('código de aluno repetido na turma');
    }
    final activities = [
      for (final row in rows(fields[6]))
        HomeworkActivity(
          code: row[0],
          task: compactTasks[int.parse(row[1])],
          opensOn: _localDay(int.parse(row[2])),
          dueAt: _dayEnd(int.parse(row[3]), int.parse(row[4])),
        ),
    ];
    return Roster(
      className: fields[1],
      classUid: fields[2],
      exportedAt: _utcDay(int.parse(fields[3])).toIso8601String(),
      students: List.unmodifiable(students),
      activities: List.unmodifiable(activities),
      deliveryKey: fields.length > 7 && fields[7].isNotEmpty ? fields[7] : null,
    );
  }

  /// O pacote compacto de um link `...#p=<pacote>`, ou `null` se o link não
  /// for desse tipo.
  static String? compactOf(String link) {
    final hash = link.indexOf('#');
    if (hash < 0) return null;
    for (final part in link.substring(hash + 1).split('&')) {
      if (part.startsWith('$compactFragmentKey=')) {
        final body = part.substring(compactFragmentKey.length + 1).trim();
        if (body.isEmpty) return null;
        try {
          return utf8.decode(base64Url.decode(base64Url.normalize(body)));
        } on FormatException {
          throw const FormatException('o link está incompleto');
        }
      }
    }
    return null;
  }

  /// Decifra o pacote do link com o código da turma.
  ///
  /// Lança [FormatException] com uma frase para a tela: código errado, link
  /// cortado ou de outra versão. Código errado e link alterado dão o mesmo
  /// erro -- a cifra autenticada não distingue, e não precisa.
  static String openSealed(String sealed, String code) {
    try {
      return utf8.decode(openSealedWithSecret(
        sealed,
        normalizeClassCode(code),
        packageKdfIterations,
        aad: _aad,
      ));
    } on FormatException catch (error) {
      throw FormatException(error.message == 'não confere'
          ? 'o código da turma não confere'
          : 'o link está incompleto ou é de outra versão');
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
    final body = fragment.startsWith(prefix)
        ? fragment.substring(prefix.length)
        : fragment;
    final amp = body.indexOf('&');
    return amp >= 0 ? body.substring(0, amp) : body;
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
