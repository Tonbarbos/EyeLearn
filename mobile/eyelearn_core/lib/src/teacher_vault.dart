/// O painel do professor no navegador: turmas, alunos, atividades e sessões.
///
/// Porta de `eyelearn/storage/store.py` para o painel web. A diferença está em
/// onde os dados ficam: não há banco num computador da escola, há um **cofre**
/// -- um JSON com tudo do professor, cifrado com a senha dele
/// ([lockVault]/[unlockVault]) e guardado no navegador e na cópia de
/// segurança que ele baixa. Nenhum servidor recebe nada: sem a senha, o cofre
/// é ilegível, e esquecer a senha é perder o cofre (o painel avisa).
///
/// O link da turma sai daqui no mesmo formato que o painel Python gerava, e
/// `test/teacher_vault_test.dart` confere byte a byte contra o arquivo de
/// exemplo do Python.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kdf.dart';
import 'roster.dart';
import 'sealing.dart';
import 'session.dart';

/// Alfabeto dos códigos de aluno, atividade e turma: sem 0/O, 1/I/L, que se
/// confundem ditados ou copiados de um papel. Igual a `CODE_ALPHABET`.
const codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const studentCodeLength = 6;
const activityCodeLength = 8;
const accessCodeLength = 8;

/// As tarefas de leitura, com os nomes do aplicativo.
const homeworkTasks = ['syllables', 'text', 'pseudotext'];

/// Atividades encerradas há até este número de dias continuam no link.
const recentlyClosedDays = 14;

/// Onde o link da turma abre.
const defaultAppUrl = 'https://tonbarbos.github.io/EyeLearn/';

/// PIN de todos os alunos no modo de teste do painel. Fura de propósito as
/// regras de [checkPin] (é uma sequência): é para testar sem anotar PINs.
const debugStudentPin = '1234';

/// Iterações do PBKDF2 do PIN, como `PIN_ITERATIONS` do Python.
const pinIterations = 20000;

/// Iterações do PBKDF2 da senha do professor.
///
/// A senha protege o cofre inteiro, inclusive na cópia de segurança, que pode
/// parar num pen drive ou num e-mail: quem a tiver pode testar senhas sem
/// limite de tentativas, e cada tentativa custa estas iterações. O valor fica
/// no envelope do cofre, então pode subir sem quebrar os já gravados.
const vaultKdfIterations = 200000;

const minPasswordLength = 8;

const vaultFormat = 'eyelearn-painel';
const vaultFormatVersion = 1;
const _vaultAad = 'eyelearn-painel';

final _random = math.Random.secure();

String _randomCode(int length) => String.fromCharCodes([
      for (var i = 0; i < length; i++)
        codeAlphabet.codeUnitAt(_random.nextInt(codeAlphabet.length)),
    ]);

String _collapse(String text) => text.trim().split(RegExp(r'\s+')).join(' ');

/// Senha, PIN ou nome fora das regras. A mensagem vai para a tela.
class VaultError implements Exception {
  final String message;
  const VaultError(this.message);

  @override
  String toString() => message;
}

// -- regras de senha e PIN, como em eyelearn/storage/auth.py -----------------

void checkPassword(String password) {
  if (password.length < minPasswordLength) {
    throw const VaultError(
        'a senha precisa de pelo menos $minPasswordLength caracteres');
  }
  if (password.trim() != password) {
    throw const VaultError('a senha não pode começar nem terminar com espaço');
  }
}

void checkPin(String pin) {
  if (!RegExp(r'^[0-9]{4}$').hasMatch(pin)) {
    throw const VaultError('o PIN precisa ter exatamente $pinLength dígitos');
  }
  if (pin.split('').toSet().length == 1) {
    throw const VaultError('o PIN não pode ser um dígito repetido');
  }
  if ('0123456789'.contains(pin) || '9876543210'.contains(pin)) {
    throw const VaultError('o PIN não pode ser uma sequência');
  }
}

/// PIN aleatório que passa em [checkPin].
String generatePin() {
  while (true) {
    final pin = _random.nextInt(10000).toString().padLeft(pinLength, '0');
    try {
      checkPin(pin);
      return pin;
    } on VaultError {
      continue;
    }
  }
}

/// `pbkdf2-sha256$iterações$sal$chave`, o formato que [verifyPin] confere.
String hashPin(String pin, {int iterations = pinIterations, Uint8List? salt}) {
  final s = salt ?? randomBytes(16);
  final key = pbkdf2Sha256(utf8.encode(pin), s, iterations, 32);
  return 'pbkdf2-sha256\$$iterations\$${_hex(s)}\$${_hex(key)}';
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _b64(String hex) => base64Url.encode(_fromHex(hex)).replaceAll('=', '');

/// `K7Q2XP4M` -> `K7Q2-XP4M`, para ler e ditar.
String formatClassCode(String code) {
  final c = normalizeClassCode(code);
  return c.length == accessCodeLength
      ? '${c.substring(0, 4)}-${c.substring(4)}'
      : c;
}

/// Nome que aparece na tela de escolha do aluno: "Ana Luiza Souza" ->
/// "Ana S."; onde dois colegas colidiriam, os dois ficam com o nome completo.
/// Igual a `display_names` do Python.
List<String> displayNames(List<String> fullNames) {
  String short(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first;
    return '${parts.first} ${parts.last[0].toUpperCase()}.';
  }

  final shorts = [for (final name in fullNames) short(name)];
  return [
    for (var i = 0; i < fullNames.length; i++)
      shorts.where((s) => s == shorts[i]).length > 1
          ? _collapse(fullNames[i])
          : shorts[i],
  ];
}

/// Instante em ISO 8601 com o deslocamento do fuso, como o `isoformat` do
/// Python: `2026-10-24T23:59:59-03:00`.
String isoWithOffset(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  final offset = time.isUtc ? Duration.zero : time.timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  final sign = offset.isNegative ? '-' : '+';
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
      '${two(time.day)}T${two(time.hour)}:${two(time.minute)}:'
      '${two(time.second)}$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

String _isoDate(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

// -- modelo -----------------------------------------------------------------

class VaultStudent {
  /// Código pseudônimo: é o que vai na sessão, no lugar do nome.
  final String code;
  final String fullName;
  final String? birthDate;
  String pinHash;

  /// Etiqueta curta do PIN, para o link compacto ([compactPinTag]). Só
  /// existe para PIN definido depois que ela foi criada; sem ela, o link
  /// leva o hash inteiro.
  String? pinTag;

  VaultStudent({
    required this.code,
    required this.fullName,
    required this.pinHash,
    this.birthDate,
    this.pinTag,
  });

  factory VaultStudent.fromJson(Map<String, dynamic> json) => VaultStudent(
        code: json['code'] as String,
        fullName: json['full_name'] as String,
        birthDate: json['birth_date'] as String?,
        pinHash: json['pin_hash'] as String,
        pinTag: json['pin_tag'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'full_name': fullName,
        if (birthDate != null) 'birth_date': birthDate,
        'pin_hash': pinHash,
        if (pinTag != null) 'pin_tag': pinTag,
      };
}

/// Aluno recém-cadastrado com o PIN em claro: a única vez que ele aparece.
class NewStudent {
  final VaultStudent student;
  final String pin;
  const NewStudent(this.student, this.pin);
}

class VaultActivity {
  /// Vai no link e volta na sessão: liga a gravação à atividade.
  final String code;
  final String task;

  /// Dia de início, `AAAA-MM-DD`.
  final String opensOn;

  /// Fim do prazo, com fuso: 23:59:59 do último dia, no fuso do professor.
  final String dueAt;

  const VaultActivity({
    required this.code,
    required this.task,
    required this.opensOn,
    required this.dueAt,
  });

  DateTime get due => DateTime.parse(dueAt);

  factory VaultActivity.fromJson(Map<String, dynamic> json) => VaultActivity(
        code: json['code'] as String,
        task: json['task'] as String,
        opensOn: json['opens_on'] as String,
        dueAt: json['due_at'] as String,
      );

  Map<String, dynamic> toJson() =>
      {'code': code, 'task': task, 'opens_on': opensOn, 'due_at': dueAt};
}

class VaultClass {
  /// Identificador público da turma, que vai no link.
  final String uid;
  String name;
  String? school;
  String? grade;

  /// Código que as famílias digitam; criado na primeira vez que é pedido.
  String? accessCode;

  final List<VaultStudent> students;
  final List<VaultActivity> activities;

  /// As sessões como chegaram, para a cópia de segurança não perder nada.
  final List<Map<String, dynamic>> sessionPayloads;

  VaultClass({
    required this.uid,
    required this.name,
    this.school,
    this.grade,
    this.accessCode,
    List<VaultStudent>? students,
    List<VaultActivity>? activities,
    List<Map<String, dynamic>>? sessionPayloads,
  })  : students = students ?? [],
        activities = activities ?? [],
        sessionPayloads = sessionPayloads ?? [];

  factory VaultClass.fromJson(Map<String, dynamic> json) => VaultClass(
        uid: json['uid'] as String,
        name: json['name'] as String,
        school: json['school'] as String?,
        grade: json['grade'] as String?,
        accessCode: json['access_code'] as String?,
        students: [
          for (final s in json['students'] as List)
            VaultStudent.fromJson(s as Map<String, dynamic>),
        ],
        activities: [
          for (final a in json['activities'] as List)
            VaultActivity.fromJson(a as Map<String, dynamic>),
        ],
        sessionPayloads: [
          for (final s in json['sessions'] as List) s as Map<String, dynamic>,
        ],
      );

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'name': name,
        if (school != null) 'school': school,
        if (grade != null) 'grade': grade,
        if (accessCode != null) 'access_code': accessCode,
        'students': [for (final s in students) s.toJson()],
        'activities': [for (final a in activities) a.toJson()],
        'sessions': sessionPayloads,
      };

  /// Alunos pelo nome completo, como o painel lista.
  List<VaultStudent> get sortedStudents => [...students]..sort(
      (a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));

  /// Atividades pelo prazo; empate, pela ordem de criação.
  List<VaultActivity> get sortedActivities {
    final indexed = [
      for (var i = 0; i < activities.length; i++) (i, activities[i])
    ];
    indexed.sort((a, b) {
      final byDue = a.$2.due.compareTo(b.$2.due);
      return byDue != 0 ? byDue : a.$1.compareTo(b.$1);
    });
    return [for (final (_, activity) in indexed) activity];
  }

  List<Session> get sessions {
    final result = [
      for (final payload in sessionPayloads) Session.fromJson(payload),
    ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return result;
  }

  VaultStudent? studentByCode(String code) {
    for (final student in students) {
      if (student.code == code) return student;
    }
    return null;
  }

  /// Quem já entregou o quê: código da atividade -> códigos dos alunos.
  Map<String, Set<String>> completedActivityCodes() {
    final known = {for (final a in activities) a.code};
    final done = <String, Set<String>>{};
    for (final payload in sessionPayloads) {
      final activity = payload['activity_code'];
      if (activity is String && known.contains(activity)) {
        done.putIfAbsent(activity, () => {}).add(
              payload['participant_code'] as String,
            );
      }
    }
    return done;
  }
}

class ShareLink {
  final String url;

  /// Código da turma formatado para ditar (`K7Q2-XP4M`).
  final String accessCode;
  const ShareLink(this.url, this.accessCode);
}

/// O que aconteceu com cada arquivo importado.
class ImportReport {
  final imported = <String>[];
  final duplicates = <String>[];

  /// Códigos de aluno que não são de turma nenhuma deste professor.
  final unknownCodes = <String>[];
  final unreadable = <String>[];

  /// Sessões que citam atividade que não é da turma do aluno.
  final wrongActivity = <String>[];

  int get total =>
      imported.length +
      duplicates.length +
      unknownCodes.length +
      unreadable.length +
      wrongActivity.length;
}

enum ImportOutcome { imported, duplicate }

class UnknownStudentCode implements Exception {
  final String code;
  const UnknownStudentCode(this.code);
}

class ActivityMismatch implements Exception {
  final String code;
  const ActivityMismatch(this.code);
}

/// Tudo de um professor.
class TeacherVault {
  final String username;
  String teacherName;
  final List<VaultClass> classes;

  TeacherVault({
    required this.username,
    required this.teacherName,
    List<VaultClass>? classes,
  }) : classes = classes ?? [];

  factory TeacherVault.create(String username, String teacherName) {
    final user = username.trim();
    final name = _collapse(teacherName);
    if (user.isEmpty || name.isEmpty) {
      throw const VaultError('usuário e nome são obrigatórios');
    }
    return TeacherVault(username: user, teacherName: name);
  }

  factory TeacherVault.fromJson(Map<String, dynamic> json) {
    if (json['format'] != vaultFormat) {
      throw const FormatException('não é um cofre do painel do EyeLearn');
    }
    if (json['format_version'] != vaultFormatVersion) {
      throw FormatException(
          'versão de cofre não suportada: ${json['format_version']}');
    }
    return TeacherVault(
      username: json['username'] as String,
      teacherName: json['teacher_name'] as String,
      classes: [
        for (final c in json['classes'] as List)
          VaultClass.fromJson(c as Map<String, dynamic>),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'format': vaultFormat,
        'format_version': vaultFormatVersion,
        'username': username,
        'teacher_name': teacherName,
        'classes': [for (final c in classes) c.toJson()],
      };

  // -- turmas ----------------------------------------------------------------

  List<VaultClass> get sortedClasses => [...classes]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  VaultClass classByUid(String uid) => classes.firstWhere(
        (c) => c.uid == uid,
        orElse: () => throw StateError('turma $uid'),
      );

  VaultClass createClass(String name, {String? school, String? grade}) {
    final clean = _collapse(name);
    if (clean.isEmpty) throw const VaultError('a turma precisa de um nome');
    if (classes.any((c) => c.name.toLowerCase() == clean.toLowerCase())) {
      throw VaultError('a turma "$clean" já existe');
    }
    String uid;
    do {
      uid = _hex(randomBytes(8));
    } while (classes.any((c) => c.uid == uid));
    final created = VaultClass(
      uid: uid,
      name: clean,
      school: _blankToNull(school),
      grade: _blankToNull(grade),
    );
    classes.add(created);
    return created;
  }

  /// Apaga a turma, os alunos e as sessões deles.
  void deleteClass(VaultClass target) => classes.remove(target);

  // -- alunos ----------------------------------------------------------------

  /// Cadastra o aluno. Sem [pin], sorteia um. Com [enforcePinRules] falso,
  /// aceita qualquer PIN de quatro dígitos (o [debugStudentPin]).
  NewStudent addStudent(
    VaultClass target,
    String fullName, {
    String? birthDate,
    String? pin,
    bool enforcePinRules = true,
  }) {
    final name = _collapse(fullName);
    if (name.isEmpty) throw const VaultError('o nome do aluno é obrigatório');
    if (target.students
        .any((s) => s.fullName.toLowerCase() == name.toLowerCase())) {
      throw VaultError('já há "$name" nesta turma');
    }
    final chosen = pin ?? generatePin();
    _checkPin(chosen, enforcePinRules);
    final taken = {
      for (final c in classes)
        for (final s in c.students) s.code,
    };
    String code;
    do {
      code = _randomCode(studentCodeLength);
    } while (taken.contains(code));
    final student = VaultStudent(
      code: code,
      fullName: name,
      birthDate: _blankToNull(birthDate),
      pinHash: hashPin(chosen),
      pinTag: compactPinTag(code, chosen),
    );
    target.students.add(student);
    return NewStudent(student, chosen);
  }

  /// Troca o PIN e devolve o novo, em claro, uma vez.
  String resetPin(
    VaultStudent student, {
    String? pin,
    bool enforcePinRules = true,
  }) {
    final chosen = pin ?? generatePin();
    _checkPin(chosen, enforcePinRules);
    student.pinHash = hashPin(chosen);
    student.pinTag = compactPinTag(student.code, chosen);
    return chosen;
  }

  /// Apaga o aluno e todas as sessões dele (LGPD, art. 18, VI).
  void deleteStudent(VaultClass target, VaultStudent student) {
    target.students.remove(student);
    target.sessionPayloads
        .removeWhere((p) => p['participant_code'] == student.code);
  }

  // -- atividades --------------------------------------------------------------

  /// Dever de casa: disponível de [opens] até o fim do dia [due], no fuso
  /// deste navegador.
  VaultActivity createActivity(
    VaultClass target,
    String task, {
    required DateTime due,
    DateTime? opens,
    DateTime? today,
  }) {
    if (!homeworkTasks.contains(task)) {
      throw VaultError('tarefa desconhecida: $task');
    }
    final day = _dateOnly(today ?? DateTime.now());
    final start = _dateOnly(opens ?? day);
    final end = _dateOnly(due);
    if (end.isBefore(day)) throw const VaultError('o prazo já passou');
    if (end.isBefore(start)) {
      throw const VaultError('o prazo termina antes de a atividade começar');
    }
    final taken = {
      for (final c in classes)
        for (final a in c.activities) a.code,
    };
    String code;
    do {
      code = _randomCode(activityCodeLength);
    } while (taken.contains(code));
    final activity = VaultActivity(
      code: code,
      task: task,
      opensOn: _isoDate(start),
      dueAt: isoWithOffset(DateTime(end.year, end.month, end.day, 23, 59, 59)),
    );
    target.activities.add(activity);
    return activity;
  }

  /// Apaga a atividade. Sessões já importadas ficam, sem o vínculo.
  void deleteActivity(VaultClass target, VaultActivity activity) =>
      target.activities.remove(activity);

  // -- link da turma ---------------------------------------------------------

  String accessCode(VaultClass target) =>
      target.accessCode ?? newAccessCode(target);

  /// Troca o código. Links já enviados param de abrir com o novo.
  String newAccessCode(VaultClass target) =>
      target.accessCode = _randomCode(accessCodeLength);

  /// O que o aplicativo precisa, no formato compacto e na mesma ordem de
  /// chaves de `Store.class_package` -- a suíte compara o texto cifrado.
  Map<String, dynamic> classPackage(VaultClass target, {DateTime? now}) {
    final students = target.sortedStudents;
    final names = displayNames([for (final s in students) s.fullName]);
    final iterations = <int>{};
    final entries = <List<String>>[];
    for (var i = 0; i < students.length; i++) {
      final parts = students[i].pinHash.split(r'$');
      if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') {
        throw StateError('PIN de ${students[i].code} em esquema desconhecido');
      }
      iterations.add(int.parse(parts[1]));
      entries.add([students[i].code, names[i], _b64(parts[2]), _b64(parts[3])]);
    }
    if (iterations.length > 1) {
      throw StateError('PINs com contagens de iteração diferentes');
    }
    entries.sort((a, b) => _casefold(a[1]).compareTo(_casefold(b[1])));

    final instant = (now ?? DateTime.now()).toUtc();
    final recent = instant.subtract(const Duration(days: recentlyClosedDays));
    return {
      'format': rosterFormat,
      'format_version': rosterFormatVersion,
      'class_name': target.name,
      'class_uid': target.uid,
      'exported_at': isoWithOffset(DateTime.utc(instant.year, instant.month,
          instant.day, instant.hour, instant.minute, instant.second)),
      'pin_iterations': iterations.isEmpty ? pinIterations : iterations.first,
      'students': entries,
      'activities': [
        for (final a in target.sortedActivities)
          if (!a.due.isBefore(recent)) [a.code, a.task, a.opensOn, a.dueAt],
      ],
    };
  }

  /// Link e código para mandar às famílias. O link muda a cada pedido (sal e
  /// nonce novos) e precisa ser mandado de novo quando a turma ou as
  /// atividades mudam; o código fica o mesmo.
  ShareLink shareLink(
    VaultClass target, {
    String baseUrl = defaultAppUrl,
    DateTime? now,
    Uint8List? salt,
    Uint8List? nonce,
  }) {
    final code = accessCode(target);
    final sealed = sealClassPackage(classPackage(target, now: now), code,
        salt: salt, nonce: nonce);
    return ShareLink(
      '${baseUrl.split('#').first}#$packageFragmentKey=$sealed',
      formatClassCode(code),
    );
  }

  /// O pacote compacto (versão 4) da turma; ver [Roster.fromCompact].
  String compactPackage(VaultClass target, {DateTime? now}) {
    final students = target.sortedStudents;
    final names = displayNames([for (final s in students) s.fullName]);
    final iterations = <int>{};
    final entries = <List<String>>[];
    for (var i = 0; i < students.length; i++) {
      final student = students[i];
      final parts = student.pinHash.split(r'$');
      if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') {
        throw StateError('PIN de ${student.code} em esquema desconhecido');
      }
      iterations.add(int.parse(parts[1]));
      entries.add([
        student.code,
        compactSafe(names[i]),
        student.pinTag ?? '${_b64(parts[2])}.${_b64(parts[3])}',
      ]);
    }
    if (iterations.length > 1) {
      throw StateError('PINs com contagens de iteração diferentes');
    }
    entries.sort((a, b) => _casefold(a[1]).compareTo(_casefold(b[1])));

    final instant = (now ?? DateTime.now()).toUtc();
    final recent = instant.subtract(const Duration(days: recentlyClosedDays));
    final activities = [
      for (final a in target.sortedActivities)
        if (!a.due.isBefore(recent))
          [
            a.code,
            compactTasks.indexOf(a.task),
            dayNumber(DateTime.parse(a.opensOn)),
            dayNumber(DateTime.parse(a.dueAt.substring(0, 10))),
            _offsetMinutes(a.dueAt),
          ].join(','),
    ];
    return [
      compactFormatVersion,
      compactSafe(target.name),
      target.uid,
      dayNumber(instant),
      iterations.isEmpty ? pinIterations : iterations.first,
      [for (final e in entries) e.join(',')].join(';'),
      activities.join(';'),
    ].join('|');
  }

  /// O link que vai às famílias: o pacote compacto, aberto, depois do `#`.
  ///
  /// Sem cifra e sem código: quem abre o link entra direto. O que protege
  /// os nomes é o mesmo que protegia antes, quando o código ia junto: o link
  /// só circula no grupo da turma, e o que vem depois do `#` não chega ao
  /// servidor. O link muda quando a turma muda e precisa ser mandado de novo.
  String compactLink(
    VaultClass target, {
    String baseUrl = defaultAppUrl,
    DateTime? now,
  }) {
    final body = base64Url
        .encode(utf8.encode(compactPackage(target, now: now)))
        .replaceAll('=', '');
    return '${baseUrl.split('#').first}#$compactFragmentKey=$body';
  }

  // -- sessões ---------------------------------------------------------------

  /// Grava a sessão na turma do aluno do código dela.
  ///
  /// Lança [FormatException] (ou erro de tipo) para arquivo inválido,
  /// [UnknownStudentCode] e [ActivityMismatch].
  ImportOutcome importSession(Map<String, dynamic> payload) {
    final session = Session.fromJson(payload);
    VaultClass? owner;
    for (final c in classes) {
      if (c.studentByCode(session.participantCode) != null) owner = c;
    }
    if (owner == null) throw UnknownStudentCode(session.participantCode);

    final activityCode = payload['activity_code'];
    if (activityCode != null) {
      final matches = owner.activities.where(
          (a) => a.code == activityCode.toString() && a.task == session.task);
      if (matches.isEmpty) throw ActivityMismatch(session.participantCode);
    }

    final startedAt = payload['started_at'];
    final duplicate = owner.sessionPayloads.any((p) =>
        p['participant_code'] == session.participantCode &&
        p['task'] == session.task &&
        p['started_at'] == startedAt);
    if (duplicate) return ImportOutcome.duplicate;
    owner.sessionPayloads.add(payload);
    return ImportOutcome.imported;
  }

  /// Importa vários arquivos sem parar no primeiro problema: perder onze
  /// sessões boas por causa de uma ruim seria o pior resultado.
  ImportReport importFiles(Map<String, String> files) {
    final report = ImportReport();
    for (final MapEntry(key: name, value: text) in files.entries) {
      try {
        final payload = jsonDecode(text) as Map<String, dynamic>;
        switch (importSession(payload)) {
          case ImportOutcome.imported:
            report.imported.add(name);
          case ImportOutcome.duplicate:
            report.duplicates.add(name);
        }
      } on UnknownStudentCode catch (error) {
        report.unknownCodes.add(error.code);
      } on ActivityMismatch {
        report.wrongActivity.add(name);
      } on FormatException {
        report.unreadable.add(name);
      } on TypeError {
        report.unreadable.add(name);
      }
    }
    return report;
  }
}

void _checkPin(String pin, bool enforceRules) {
  if (enforceRules) {
    checkPin(pin);
  } else if (!RegExp(r'^[0-9]{4}$').hasMatch(pin)) {
    throw const VaultError('o PIN precisa ter exatamente $pinLength dígitos');
  }
}

String? _blankToNull(String? text) {
  if (text == null) return null;
  final clean = _collapse(text);
  return clean.isEmpty ? null : clean;
}

/// Etiqueta curta do PIN: quatro bytes de PBKDF2, com o sal tirado do código
/// do aluno. É o que vai no link compacto.
String compactPinTag(String studentCode, String pin) => base64Url
    .encode(pbkdf2Sha256(utf8.encode(pin), compactPinSalt(studentCode),
        pinIterations, compactPinBytes))
    .replaceAll('=', '');

/// Deslocamento do fuso de um instante ISO com fuso (`...-03:00`), em
/// minutos a leste de UTC.
int _offsetMinutes(String iso) {
  final match = RegExp(r'([+-])(\d\d):(\d\d)$').firstMatch(iso);
  if (match == null) return 0; // termina em Z
  final minutes = int.parse(match[2]!) * 60 + int.parse(match[3]!);
  return match[1] == '-' ? -minutes : minutes;
}

/// Aproximação do `str.casefold` do Python, suficiente para nomes.
String _casefold(String text) => text.toLowerCase().replaceAll('ß', 'ss');

/// Cifra o pacote da turma com o código, como `package.seal` do Python.
String sealClassPackage(
  Map<String, dynamic> package,
  String code, {
  Uint8List? salt,
  Uint8List? nonce,
}) =>
    seal(
      utf8.encode(jsonEncode(package)),
      SealKey.derive(normalizeClassCode(code), packageKdfIterations,
          salt: salt),
      aad: rosterFormat,
      nonce: nonce,
    );

// -- o cofre cifrado -----------------------------------------------------------

/// O cofre como fica guardado: o nome de usuário e o custo da chave em claro,
/// para a tela de entrada; o resto, cifrado.
class VaultEnvelope {
  static const format = 'eyelearn-painel-cofre';
  static const formatVersion = 1;

  final String username;
  final int iterations;
  final String sealed;

  const VaultEnvelope({
    required this.username,
    required this.iterations,
    required this.sealed,
  });

  Uint8List get salt => sealedSalt(sealed);

  /// Lança [FormatException] se o texto não for um cofre.
  factory VaultEnvelope.parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('o arquivo não é um cofre do EyeLearn');
    }
    if (json is! Map<String, dynamic> || json['format'] != format) {
      throw const FormatException('o arquivo não é um cofre do EyeLearn');
    }
    if (json['format_version'] != formatVersion) {
      throw const FormatException('cofre de uma versão mais nova do painel');
    }
    final iterations = json['kdf_iterations'];
    if (iterations is! int || iterations < 1 || iterations > 10000000) {
      throw const FormatException('cofre corrompido');
    }
    return VaultEnvelope(
      username: json['username'] as String,
      iterations: iterations,
      sealed: json['sealed'] as String,
    );
  }

  String toJsonString() => const JsonEncoder.withIndent('  ').convert({
        'format': format,
        'format_version': formatVersion,
        'username': username,
        'kdf_iterations': iterations,
        'sealed': sealed,
      });
}

/// A senha não abre o cofre (ou o cofre foi alterado).
class WrongPassword implements Exception {
  const WrongPassword();

  @override
  String toString() => 'a senha não confere';
}

/// Deriva a chave do cofre. É a parte cara: dezenas de milhares de rodadas de
/// HMAC, feita uma vez ao entrar; cada gravação reaproveita a chave com nonce
/// novo.
SealKey deriveVaultKey(String password,
        {int iterations = vaultKdfIterations, Uint8List? salt}) =>
    SealKey.derive(password, iterations, salt: salt);

/// Cifra o cofre. [iterations] vai no envelope e tem de ser o usado em [key].
VaultEnvelope lockVault(TeacherVault vault, SealKey key,
        {int iterations = vaultKdfIterations}) =>
    VaultEnvelope(
      username: vault.username,
      iterations: iterations,
      sealed:
          seal(utf8.encode(jsonEncode(vault.toJson())), key, aad: _vaultAad),
    );

/// Abre o cofre. Lança [WrongPassword] se a chave não conferir.
TeacherVault unlockVault(VaultEnvelope envelope, SealKey key) {
  final Uint8List plain;
  try {
    plain = openSealedWith(envelope.sealed, key, aad: _vaultAad);
  } on FormatException catch (error) {
    if (error.message == 'não confere') throw const WrongPassword();
    throw const FormatException('cofre corrompido');
  }
  return TeacherVault.fromJson(
      jsonDecode(utf8.decode(plain)) as Map<String, dynamic>);
}
