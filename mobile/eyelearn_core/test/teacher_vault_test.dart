import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// O pacote de exemplo que `scripts/make_roster_fixture.py` gera pelo painel
/// Python.
final _fixture = jsonDecode(
  File('assets/class_package_example.json').readAsStringSync(),
) as Map<String, dynamic>;

final _comparison = jsonDecode(
  File('assets/comparison_example.json').readAsStringSync(),
) as Map<String, dynamic>;

/// Nomes completos dos alunos do exemplo, como o script os cadastrou.
const _fullNames = {
  'JMSR6C': 'Ana Luiza Souza',
  'R82Y3A': 'Bruno Lima',
  'CUQGRF': 'João da Silva',
  'H8YCK5': 'Ana Souza Prado',
};

String _hexOf(String b64) => base64Url
    .decode(base64Url.normalize(b64))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// A turma do exemplo, montada no cofre com os mesmos dados que o Python
/// tinha no banco.
(TeacherVault, VaultClass) _exampleVault() {
  final expected = _fixture['expected'] as Map<String, dynamic>;
  final iterations = expected['pin_iterations'] as int;
  final vault = TeacherVault.create('exemplo', 'Professora Exemplo');
  final target = VaultClass(
    uid: expected['class_uid'] as String,
    name: expected['class_name'] as String,
    accessCode: normalizeClassCode(_fixture['code'] as String),
  );
  for (final entry in (expected['students'] as List).cast<List<dynamic>>()) {
    target.students.add(VaultStudent(
      code: entry[0] as String,
      fullName: _fullNames[entry[0]]!,
      pinHash: 'pbkdf2-sha256\$$iterations'
          '\$${_hexOf(entry[2] as String)}\$${_hexOf(entry[3] as String)}',
    ));
  }
  for (final entry in (expected['activities'] as List).cast<List<dynamic>>()) {
    target.activities.add(VaultActivity(
      code: entry[0] as String,
      task: entry[1] as String,
      opensOn: entry[2] as String,
      dueAt: entry[3] as String,
    ));
  }
  vault.classes.add(target);
  return (vault, target);
}

Uint8List _range(int n) => Uint8List.fromList(List.generate(n, (i) => i));

void main() {
  group('link da turma, contra o painel Python', () {
    final today = DateTime.parse('${_fixture['today']}T00:00:00Z');

    test('o pacote sai igual ao do Python', () {
      final (vault, target) = _exampleVault();
      expect(vault.classPackage(target, now: today), _fixture['expected']);
    });

    test('a cifra sai igual byte a byte, com o mesmo sal e nonce', () {
      final (vault, target) = _exampleVault();
      final link = vault.shareLink(target,
          now: today, salt: _range(16), nonce: _range(12));
      expect(link.url, '${defaultAppUrl}#t=${_fixture['fragment']}');
      expect(link.accessCode, _fixture['code']);
    });

    test('o aplicativo do aluno abre o link e os PINs conferem', () {
      final (vault, target) = _exampleVault();
      final link = vault.shareLink(target, now: today);
      final roster = Roster.openLink(link.url, link.accessCode);
      expect(roster.className, target.name);
      final pins = (_fixture['pins_for_tests'] as Map).cast<String, String>();
      final ana = roster.students.firstWhere((s) => s.code == 'JMSR6C');
      expect(ana.checkPin(pins['JMSR6C']!), isTrue);
      expect(ana.checkPin('1357'), isFalse);
    });

    test('o link muda a cada pedido; o código, não', () {
      final (vault, target) = _exampleVault();
      final a = vault.shareLink(target);
      final b = vault.shareLink(target);
      expect(a.url, isNot(b.url));
      expect(a.accessCode, b.accessCode);
    });

    test('trocar o código faz o link antigo parar de abrir', () {
      final (vault, target) = _exampleVault();
      final old = vault.shareLink(target);
      vault.newAccessCode(target);
      final fresh = vault.shareLink(target);
      expect(fresh.accessCode, isNot(old.accessCode));
      expect(() => Roster.openLink(old.url, fresh.accessCode),
          throwsFormatException);
    });

    test('atividade encerrada há mais de 14 dias sai do link', () {
      final (vault, target) = _exampleVault();
      final later = today.add(const Duration(days: 20));
      final codes = [
        for (final a
            in vault.classPackage(target, now: later)['activities'] as List)
          (a as List)[0],
      ];
      expect(codes, isNot(contains('K8CKU7A3')));
      expect(codes, contains('N65VX5TR'));
    });
  });

  group('regras como as do Python', () {
    test('nome de exibição: primeiro nome e inicial; colisão vira completo',
        () {
      expect(displayNames(['Ana Luiza Souza', 'Bruno Lima', 'Cris']),
          ['Ana S.', 'Bruno L.', 'Cris']);
      expect(displayNames(['Ana Souza', 'Ana  Silva', 'Bia Lima']),
          ['Ana Souza', 'Ana Silva', 'Bia L.']);
    });

    test('PIN: quatro dígitos, sem repetição nem sequência', () {
      for (final bad in [
        '123',
        '12345',
        '1111',
        '1234',
        '6543',
        '12a4',
        '１２３５'
      ]) {
        expect(() => checkPin(bad), throwsA(isA<VaultError>()), reason: bad);
      }
      checkPin('2580');
      for (var i = 0; i < 200; i++) {
        checkPin(generatePin());
      }
    });

    test('o hash do PIN tem o formato que o aplicativo confere', () {
      final hash = hashPin('2580', iterations: 1000);
      expect(hash, startsWith(r'pbkdf2-sha256$1000$'));
      expect(verifyPin('2580', hash), isTrue);
      expect(verifyPin('2581', hash), isFalse);
    });

    test('senha: oito caracteres, sem espaço nas pontas', () {
      expect(() => checkPassword('curta'), throwsA(isA<VaultError>()));
      expect(() => checkPassword(' com espaço'), throwsA(isA<VaultError>()));
      checkPassword('senha-boa-o-bastante');
    });

    test('prazo vai até 23:59:59 do dia, com o fuso', () {
      expect(isoWithOffset(DateTime.utc(2026, 10, 24, 23, 59, 59)),
          '2026-10-24T23:59:59+00:00');
      final local = DateTime(2026, 10, 24, 23, 59, 59);
      expect(
          DateTime.parse(isoWithOffset(local)).isAtSameMomentAs(local), isTrue);
    });
  });

  group('turmas, alunos e atividades', () {
    test('cadastro: código único, PIN em claro só na volta', () {
      final vault = TeacherVault.create('prof', 'Prof. Ana');
      final turma = vault.createClass('5º A');
      final a = vault.addStudent(turma, '  Ana   Souza ');
      final b = vault.addStudent(turma, 'Bruno Lima', pin: '2580');
      expect(a.student.fullName, 'Ana Souza');
      expect(a.student.code, hasLength(studentCodeLength));
      expect(a.student.code, isNot(b.student.code));
      expect(b.pin, '2580');
      expect(b.student.pinHash, isNot(contains('2580')));
      expect(verifyPin('2580', b.student.pinHash), isTrue);
      expect(() => vault.addStudent(turma, 'ana souza'),
          throwsA(isA<VaultError>()));
      expect(() => vault.createClass('5º a'), throwsA(isA<VaultError>()));
    });

    test('trocar o PIN invalida o antigo', () {
      final vault = TeacherVault.create('prof', 'Prof. Ana');
      final turma = vault.createClass('5º A');
      final aluno = vault.addStudent(turma, 'Ana Souza', pin: '2580').student;
      final novo = vault.resetPin(aluno);
      expect(verifyPin(novo, aluno.pinHash), isTrue);
      if (novo != '2580') expect(verifyPin('2580', aluno.pinHash), isFalse);
    });

    test('atividade: prazo no passado ou antes do início é recusado', () {
      final vault = TeacherVault.create('prof', 'Prof. Ana');
      final turma = vault.createClass('5º A');
      final hoje = DateTime(2026, 10, 21);
      expect(
          () => vault.createActivity(turma, 'text',
              due: DateTime(2026, 10, 20), today: hoje),
          throwsA(isA<VaultError>()));
      expect(
          () => vault.createActivity(turma, 'text',
              due: DateTime(2026, 10, 22),
              opens: DateTime(2026, 10, 25),
              today: hoje),
          throwsA(isA<VaultError>()));
      expect(
          () => vault.createActivity(turma, 'lerolero',
              due: DateTime(2026, 10, 22), today: hoje),
          throwsA(isA<VaultError>()));
      final ok = vault.createActivity(turma, 'text',
          due: DateTime(2026, 10, 24), today: hoje);
      expect(ok.opensOn, '2026-10-21');
      expect(
          ok.due.isAtSameMomentAs(DateTime(2026, 10, 24, 23, 59, 59)), isTrue);
    });
  });

  group('importação de sessões', () {
    late TeacherVault vault;
    late VaultClass turma;
    late VaultActivity texto;
    late List<Map<String, dynamic>> payloads;

    setUp(() {
      vault = TeacherVault.create('prof', 'Prof. Ana');
      turma = vault.createClass('5º A');
      texto = vault.createActivity(turma, 'text',
          due: DateTime(2026, 10, 24), today: DateTime(2026, 10, 21));
      payloads = [
        for (final p in _comparison['sessions'] as List)
          Map<String, dynamic>.from(p as Map),
      ];
      // Os alunos do exemplo de comparação, com os códigos dele.
      final codes = {for (final p in payloads) p['participant_code'] as String};
      for (final code in codes) {
        turma.students.add(VaultStudent(
            code: code,
            fullName: 'Aluno $code',
            pinHash: hashPin('2580', iterations: 10)));
      }
    });

    String file(Map<String, dynamic> p) => jsonEncode(p);

    test('importa, ignora repetida e explica as recusadas', () {
      final files = <String, String>{
        for (var i = 0; i < payloads.length; i++)
          'sessao$i.json': file(payloads[i]),
        'repetida.json': file(payloads.first),
        'estranho.json':
            file({...payloads.first, 'participant_code': 'ZZZ999'}),
        'quebrado.json': '{"format_version": ',
        'outra-turma.json':
            file({...payloads[1], 'activity_code': 'NAOEXISTE'}),
        'tarefa-errada.json': file({
          ...payloads[2],
          'started_at': '2026-10-22T10:00:00Z',
          'task': 'syllables',
          'activity_code': texto.code,
        }),
      };
      final report = vault.importFiles(files);
      expect(report.imported, hasLength(payloads.length));
      expect(report.duplicates, ['repetida.json']);
      expect(report.unknownCodes, ['ZZZ999']);
      expect(report.unreadable, ['quebrado.json']);
      expect(report.wrongActivity, ['outra-turma.json', 'tarefa-errada.json']);
      expect(report.total, files.length);
    });

    test('a comparação com a turma sai igual à do Python', () {
      vault.importFiles(
          {for (var i = 0; i < payloads.length; i++) '$i': file(payloads[i])});
      final comparison = compareWithinClass(turma.sessions, 'text');
      final expected = _comparison['expected'] as Map<String, dynamic>;
      expect(comparison.participantCodes, expected['participant_codes']);
      expect(comparison.outliers(), expected['outliers']);
    });

    test('entrega conta só a atividade da sessão', () {
      final entregue = {
        ...payloads.first,
        'started_at': '2026-10-22T10:00:00Z',
        'activity_code': texto.code,
      };
      vault.importSession(entregue);
      expect(turma.completedActivityCodes(), {
        texto.code: {payloads.first['participant_code']},
      });
    });

    test('apagar o aluno apaga as sessões dele', () {
      vault.importFiles(
          {for (var i = 0; i < payloads.length; i++) '$i': file(payloads[i])});
      final aluno = turma.studentByCode('BBB333')!;
      vault.deleteStudent(turma, aluno);
      expect(turma.sessions.map((s) => s.participantCode),
          isNot(contains('BBB333')));
      expect(turma.studentByCode('BBB333'), isNull);
    });
  });

  group('cofre cifrado', () {
    TeacherVault filled() {
      final vault = TeacherVault.create('prof', 'Prof. Ana');
      final turma = vault.createClass('5º A', school: 'EM Exemplo');
      vault.addStudent(turma, 'Ana Souza', pin: '2580');
      vault.createActivity(turma, 'text',
          due: DateTime(2026, 10, 24), today: DateTime(2026, 10, 21));
      return vault;
    }

    test('abre com a senha e volta igual', () {
      final vault = filled();
      final key = deriveVaultKey('senha-boa-o-bastante', iterations: 1000);
      final envelope = lockVault(vault, key, iterations: 1000);
      final text = envelope.toJsonString();
      expect(text, isNot(contains('Ana Souza')));
      expect(text, isNot(contains('5º A')));

      final parsed = VaultEnvelope.parse(text);
      expect(parsed.username, 'prof');
      final again = deriveVaultKey('senha-boa-o-bastante',
          iterations: parsed.iterations, salt: parsed.salt);
      expect(unlockVault(parsed, again).toJson(), vault.toJson());
    });

    test('senha errada não abre', () {
      final envelope = lockVault(
          filled(), deriveVaultKey('senha-boa-o-bastante', iterations: 1000),
          iterations: 1000);
      final wrong = deriveVaultKey('senha-errada-mesmo',
          iterations: 1000, salt: envelope.salt);
      expect(() => unlockVault(envelope, wrong), throwsA(isA<WrongPassword>()));
    });

    test('cada gravação usa nonce novo com a mesma chave', () {
      final vault = filled();
      final key = deriveVaultKey('senha-boa-o-bastante', iterations: 1000);
      final a = lockVault(vault, key, iterations: 1000).sealed;
      final b = lockVault(vault, key, iterations: 1000).sealed;
      expect(a, isNot(b));
      expect(sealedSalt(a), sealedSalt(b));
    });

    test('um link da turma não abre como cofre, nem o contrário', () {
      final key = deriveVaultKey('K7Q2XP4M',
          iterations: packageKdfIterations, salt: _range(16));
      final envelope = VaultEnvelope(
          username: 'x',
          iterations: packageKdfIterations,
          sealed: _fixture['fragment'] as String);
      expect(() => unlockVault(envelope, key), throwsA(isA<WrongPassword>()));
    });

    test('arquivo que não é cofre dá erro legível', () {
      expect(() => VaultEnvelope.parse('{"format":"outro"}'),
          throwsFormatException);
      expect(() => VaultEnvelope.parse('não é json'), throwsFormatException);
    });
  });
}
