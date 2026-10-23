import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eyelearn_app/src/homework_app.dart';
import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/session/class_storage.dart';
import 'package:eyelearn_app/src/teacher/comparison_chart.dart';
import 'package:eyelearn_app/src/teacher/teacher_controller.dart';
import 'package:eyelearn_app/src/teacher/teacher_platform.dart';
import 'package:eyelearn_app/src/teacher/teacher_screens.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sessões de exemplo, com a comparação que o Python calculou para elas
/// (`scripts/make_comparison_fixture.py`).
final _comparison = jsonDecode(
  File('../eyelearn_core/assets/comparison_example.json').readAsStringSync(),
) as Map<String, dynamic>;

final _today = DateTime(2026, 10, 21, 15);

/// Chave em Dart, sem isolate; arquivos escolhidos pelo teste.
class _FakePlatform implements TeacherPlatform {
  List<PickedFile> nextFiles = [];
  final saved = <String, String>{};

  @override
  Future<SealKey> deriveKey(
          String password, int iterations, Uint8List salt) async =>
      deriveVaultKey(password, iterations: iterations, salt: salt);

  @override
  Future<List<PickedFile>> Function()? get pickFiles => () async => nextFiles;

  @override
  Future<void> saveFile(String name, String text) async => saved[name] = text;

  @override
  Future<bool> persistStorage() async => true;
}

const _iterations = 1000;
const _password = 'senha-boa-o-bastante';

TeacherEnvironment _teacher(_FakePlatform platform, VaultStorage storage) =>
    TeacherEnvironment(
      platform: platform,
      storage: storage,
      clock: () => _today,
      kdfIterations: _iterations,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: home));
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _settle(tester);
}

/// Um cofre com os alunos das sessões de exemplo, já gravado.
Future<MemoryVaultStorage> _storedVault() async {
  final vault = TeacherVault.create('prof', 'Prof. Ana');
  final turma = vault.createClass('5º A');
  final names = {
    'AAA222': 'Alice Prado',
    'BBB333': 'Bruno Lima',
    'CCC444': 'Carla Dias',
    'DDD555': 'Davi Rocha',
    'EEE666': 'Elisa Moura',
    'FFF777': 'Fábio Reis',
  };
  for (final MapEntry(key: code, value: name) in names.entries) {
    turma.students.add(VaultStudent(
        code: code, fullName: name, pinHash: hashPin('2580', iterations: 10)));
  }
  final key = deriveVaultKey(_password, iterations: _iterations);
  return MemoryVaultStorage(
      envelope: lockVault(vault, key, iterations: _iterations).toJsonString());
}

void main() {
  testWidgets('criar o painel, a turma, os alunos, a atividade e o link',
      (tester) async {
    final platform = _FakePlatform();
    final storage = MemoryVaultStorage();
    await _pump(tester, TeacherGate(environment: _teacher(platform, storage)));

    await _tap(tester, find.text('Criar o painel'));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Ana Professora');
    await tester.enterText(fields.at(1), 'ana');
    await tester.enterText(fields.at(2), _password);
    await tester.enterText(fields.at(3), _password);
    await _tap(tester, find.byType(CheckboxListTile));
    await _tap(tester, find.text('Criar'));
    expect(find.text('Turmas de Ana Professora'), findsOneWidget);
    // Nada em claro no armazenamento.
    expect(storage.envelope, isNot(contains('Ana Professora')));
    // Nunca baixou cópia: o painel lembra.
    expect(find.textContaining('Baixe uma cópia de segurança'), findsOneWidget);

    await _tap(tester, find.text('Nova turma'));
    await tester.enterText(find.byType(TextField).first, '5º B');
    await _tap(tester, find.text('Criar'));
    expect(find.text('Leitura da turma'), findsOneWidget);

    await _tap(tester, find.text('Alunos'));
    await _tap(tester, find.text('Adicionar alunos').last);
    await tester.enterText(find.byType(TextField).last,
        'Ana Luiza Souza\nBruno Lima\n\nana luiza souza');
    await _tap(tester, find.text('Adicionar'));
    expect(find.text('Anote os PINs'), findsOneWidget);
    expect(find.textContaining('Já há'), findsOneWidget);
    await _tap(tester, find.text('Anotei'));
    expect(find.text('2 alunos'), findsOneWidget);

    await _tap(tester, find.text('Atividades e link'));
    await _tap(tester, find.text('Nova atividade'));
    await _tap(tester, find.text('Criar'));
    expect(find.text('Texto (uma história)'), findsOneWidget);
    expect(find.textContaining('entregue por 0 de 2'), findsOneWidget);

    await _tap(tester, find.text('Gerar o link'));
    final message =
        tester.widget<SelectableText>(find.byType(SelectableText).first).data!;
    final url = message.split('\n').last;
    final code =
        tester.widget<SelectableText>(find.byType(SelectableText).last).data!;
    expect(url, startsWith('$defaultAppUrl#t='));
    expect(code, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')));

    // O aplicativo do aluno abre o link com o código.
    final roster = Roster.openLink(url, code);
    expect(roster.className, '5º B');
    expect(roster.students.map((s) => s.displayName), ['Ana S.', 'Bruno L.']);
    expect(roster.activities.single.task, 'text');

    // Fechar e abrir: o cofre volta com a senha.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, TeacherGate(environment: _teacher(platform, storage)));
    expect(find.text('Olá de novo'), findsOneWidget);
    await tester.enterText(find.byType(TextField), _password);
    await _tap(tester, find.text('Entrar'));
    expect(find.text('5º B'), findsOneWidget);
    expect(
        find.textContaining('2 alunos · 1 atividade aberta'), findsOneWidget);
  });

  testWidgets('senha errada não abre', (tester) async {
    final storage = await _storedVault();
    await _pump(
        tester, TeacherGate(environment: _teacher(_FakePlatform(), storage)));
    await tester.enterText(find.byType(TextField), 'senha-errada-mesmo');
    await _tap(tester, find.text('Entrar'));
    expect(find.text('A senha não confere.'), findsOneWidget);
    expect(find.text('Olá de novo'), findsOneWidget);
  });

  testWidgets('importar as sessões e ver a leitura da turma', (tester) async {
    final platform = _FakePlatform();
    final storage = await _storedVault();
    await _pump(tester, TeacherGate(environment: _teacher(platform, storage)));
    await tester.enterText(find.byType(TextField), _password);
    await _tap(tester, find.text('Entrar'));
    await _tap(tester, find.text('5º A'));

    expect(find.textContaining('Ainda não há gravação'), findsOneWidget);

    final sessions = _comparison['sessions'] as List;
    platform.nextFiles = [
      for (var i = 0; i < sessions.length; i++)
        (name: 'sessao$i.json', text: jsonEncode(sessions[i])),
      (name: 'repetida.json', text: jsonEncode(sessions.first)),
      (name: 'foto.json', text: 'não é sessão'),
    ];
    await _tap(tester, find.text('Sessões'));
    await _tap(tester, find.text('Importar arquivos'));
    expect(find.text('${sessions.length} sessões importadas.'), findsOneWidget);
    expect(find.textContaining('1 arquivo já estava'), findsOneWidget);
    expect(find.textContaining('foto.json'), findsOneWidget);
    await _tap(tester, find.text('OK'));

    await _tap(tester, find.text('Leitura da turma'));
    // A criança que se destaca na fixture aparece, com o nome que só o
    // professor vê, e é a primeira mostrada no gráfico.
    expect(find.textContaining('Elisa Moura ·'), findsOneWidget);
    expect(find.byType(ComparisonChart), findsOneWidget);
    expect(find.text('Sugestões'), findsOneWidget);
    final expected =
        (_comparison['expected']['suggestions'] as Map)['EEE666'] as List;
    for (final text in expected) {
      expect(find.text(text as String), findsOneWidget);
    }
    // A gravação a 10 Hz ficou fora.
    expect(find.textContaining('1 gravação desta tarefa'), findsOneWidget);
    expect(find.textContaining('não é diagnóstico'), findsOneWidget);

    // Descreve sem julgar, e não mostra a pontuação do modelo: é o que
    // separa o painel de um instrumento diagnóstico (como em
    // tests/test_panel.py, do lado Python).
    final shown = [
      for (final widget in tester.widgetList<Text>(find.byType(Text)))
        (widget.data ?? widget.textSpan?.toPlainText() ?? '').toLowerCase(),
    ].join('\n');
    for (final word in [
      'ruim',
      'pior',
      'risco',
      'alerta',
      'grave',
      'déficit',
      'pontuação',
      'probabilidade',
      'possível dislexia',
      'tem dislexia',
    ]) {
      expect(shown, isNot(contains(word)), reason: word);
    }
  });

  testWidgets('a cópia de segurança é o cofre cifrado', (tester) async {
    final platform = _FakePlatform();
    final storage = await _storedVault();
    await _pump(tester, TeacherGate(environment: _teacher(platform, storage)));
    await tester.enterText(find.byType(TextField), _password);
    await _tap(tester, find.text('Entrar'));
    await _tap(tester, find.text('Baixar'));
    final backup = platform.saved.values.single;
    expect(platform.saved.keys.single, 'eyelearn-painel-prof-2026-10-21.json');
    expect(backup, isNot(contains('Elisa')));
    expect(find.textContaining('Baixe uma cópia'), findsNothing);

    // Restaurar noutro navegador, vazio.
    final elsewhere = MemoryVaultStorage();
    platform.nextFiles = [(name: 'copia.json', text: backup)];
    await tester.pumpWidget(const SizedBox());
    await _pump(
        tester, TeacherGate(environment: _teacher(platform, elsewhere)));
    await _tap(tester, find.text('Restaurar uma cópia de segurança'));
    expect(find.textContaining('Cópia de prof'), findsOneWidget);
    await tester.enterText(find.byType(TextField), _password);
    await _tap(tester, find.text('Entrar'));
    expect(find.text('5º A'), findsOneWidget);
    expect(elsewhere.envelope, backup);
  });

  testWidgets('o aplicativo do aluno leva ao painel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(HomeworkApp(
      environment: HomeworkEnvironment(
        models: const {},
        gaze: SyntheticGazeSource.new,
        storage: MemoryClassStorage(),
        clock: () => _today,
        teacher: _teacher(_FakePlatform(), MemoryVaultStorage()),
      ),
    ));
    await _settle(tester);
    await _tap(tester, find.text('Sou professor'));
    expect(find.text('Painel do professor'), findsWidgets);
    expect(find.text('Criar o painel'), findsOneWidget);
  });

  testWidgets('#professor abre direto o painel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(HomeworkApp(
      environment: HomeworkEnvironment(
        models: const {},
        gaze: SyntheticGazeSource.new,
        storage: MemoryClassStorage(),
        clock: () => _today,
        initialLink: 'https://tonbarbos.github.io/EyeLearn/#professor',
        teacher: _teacher(_FakePlatform(), MemoryVaultStorage()),
      ),
    ));
    await _settle(tester);
    expect(find.text('Criar o painel'), findsOneWidget);
  });
}
