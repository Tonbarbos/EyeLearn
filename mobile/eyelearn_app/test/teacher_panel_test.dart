import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_app/src/delivery/inbox.dart';
import 'package:eyelearn_app/src/homework_app.dart';
import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/session/class_storage.dart';
import 'package:eyelearn_app/src/teacher/comparison_chart.dart';
import 'package:eyelearn_app/src/teacher/teacher_controller.dart';
import 'package:eyelearn_app/src/teacher/teacher_platform.dart';
import 'package:eyelearn_app/src/teacher/teacher_screens.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  final savedBytes = <String, Uint8List>{};

  @override
  Future<void> saveBytes(String name, Uint8List bytes, String type) async =>
      savedBytes[name] = bytes;

  @override
  Future<bool> persistStorage() async => true;
}

const _iterations = 1000;
const _password = 'senha-boa-o-bastante';

TeacherEnvironment _teacher(_FakePlatform platform, VaultStorage storage,
        {Inbox? inbox}) =>
    TeacherEnvironment(
      platform: platform,
      storage: storage,
      clock: () => _today,
      kdfIterations: _iterations,
      inbox: inbox,
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
  testWidgets('turma, atividade, alunos e link, em poucos toques',
      (tester) async {
    final platform = _FakePlatform();
    final storage = MemoryVaultStorage();
    await _pump(tester, TeacherGate(environment: _teacher(platform, storage)));

    // Criar o painel: só nome e senha.
    await _tap(tester, find.text('Criar o painel'));
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), 'Ana Professora');
    await tester.enterText(fields.at(1), _password);
    await _tap(tester, find.text('Criar'));
    expect(find.text('Turmas de Ana Professora'), findsOneWidget);
    // Nada em claro no armazenamento.
    expect(storage.envelope, isNot(contains('Ana Professora')));
    expect(VaultEnvelope.parse(storage.envelope!).username, 'ana-professora');
    // Nunca baixou cópia: o painel lembra.
    expect(find.textContaining('Baixe uma cópia de segurança'), findsOneWidget);

    // 1. Turma: só o nome.
    await _tap(tester, find.text('Nova turma'));
    await tester.enterText(find.byType(TextField).first, '5º B');
    await _tap(tester, find.text('Criar'));
    expect(find.text('Turma'), findsOneWidget);
    expect(find.text('Crie a atividade e cadastre os alunos antes.'),
        findsOneWidget);

    // 2. Atividade: um toque.
    await _tap(tester, find.text('Texto (uma história)'));
    expect(find.textContaining('entregue por 0 de 0'), findsOneWidget);
    expect(find.textContaining('até 28/10'), findsOneWidget);

    // 3. Alunos: nome e Enter, PIN 1234 para todos.
    final name = find.widgetWithText(TextField, 'Nome do aluno');
    for (final student in ['Ana Luiza Souza', 'Bruno Lima']) {
      await tester.enterText(name, student);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);
    }
    expect(find.text('Ana Luiza Souza'), findsOneWidget);
    expect(find.text('Bruno Lima'), findsOneWidget);
    expect(
        find.textContaining('PIN de todos os alunos é 1234'), findsOneWidget);

    // 4. Link: já pronto, sem botão de gerar; abre sem código.
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    expect(find.text('Gerar o link'), findsNothing);
    await _tap(tester, find.text('Copiar o link'));
    final url = clipboard.single;
    expect(url, startsWith('$defaultAppUrl#p='));
    expect(url.length, lessThan(300));

    // O aplicativo do aluno abre o link sozinho, e o PIN 1234 entra.
    final roster = Roster.fromJsonString(Roster.compactOf(url)!);
    expect(roster.className, '5º B');
    expect(roster.students.map((s) => s.displayName), ['Ana S.', 'Bruno L.']);
    expect(roster.students.first.checkPin('1234'), isTrue);
    expect(roster.activities.single.task, 'text');

    // Mudou a turma depois de copiar: o painel avisa para copiar de novo.
    await tester.enterText(name, 'Carla Dias');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(find.textContaining('copie o link de novo'), findsOneWidget);
    await _tap(tester, find.text('Copiar o link'));
    expect(find.textContaining('copie o link de novo'), findsNothing);
    expect(Roster.fromJsonString(Roster.compactOf(clipboard.last)!).students,
        hasLength(3));

    // Fechar e abrir: o cofre volta com a senha.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, TeacherGate(environment: _teacher(platform, storage)));
    expect(find.text('Olá de novo'), findsOneWidget);
    await tester.enterText(find.byType(TextField), _password);
    await _tap(tester, find.text('Entrar'));
    expect(find.text('5º B'), findsOneWidget);
    expect(
        find.textContaining('3 alunos · 1 atividade aberta'), findsOneWidget);
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
    await _tap(tester, find.text('Leitura da turma'));

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

  testWidgets('o link compacto entra direto na turma', (tester) async {
    final vault = TeacherVault.create('prof', 'Prof. Ana');
    final turma = vault.createClass('5º C');
    vault.addStudent(turma, 'Ana Souza',
        pin: debugStudentPin, enforcePinRules: false);
    final link = vault.compactLink(turma);
    final storage = MemoryClassStorage();

    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(HomeworkApp(
      environment: HomeworkEnvironment(
        models: const {},
        gaze: SyntheticGazeSource.new,
        storage: storage,
        clock: () => _today,
        initialLink: link,
      ),
    ));
    await _settle(tester);
    expect(find.text('Código da turma'), findsNothing);
    expect(find.text('Quem vai ler hoje?'), findsOneWidget);
    expect(find.text('5º C'.toUpperCase()), findsOneWidget);
    // Guardada no aparelho: abre de novo sem o link.
    expect(Roster.fromJsonString((await storage.load())!.packageJson).className,
        '5º C');
  });

  testWidgets('link compacto cortado explica, sem pedir código',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(HomeworkApp(
      environment: HomeworkEnvironment(
        models: const {},
        gaze: SyntheticGazeSource.new,
        storage: MemoryClassStorage(),
        clock: () => _today,
        initialLink: '$defaultAppUrl#p=NHw1wrogQXw1YmY5',
      ),
    ));
    await _settle(tester);
    expect(find.textContaining('outra versão'), findsOneWidget);
  });

  testWidgets('ao abrir a turma, as entregas novas chegam sozinhas',
      (tester) async {
    final storage = await _storedVault();
    // Uma criança da turma terminou a atividade: a sessão está na caixa,
    // cifrada para este cofre.
    final envelope = VaultEnvelope.parse(storage.envelope!);
    final vault = unlockVault(
        envelope,
        deriveVaultKey(_password,
            iterations: envelope.iterations, salt: envelope.salt));
    final turma = vault.classes.single;
    final session = Map<String, dynamic>.from(
        (_comparison['sessions'] as List).first as Map);
    final inbox = MemoryInbox();
    await inbox.send(
        turma.uid,
        sealForTeacher(
            utf8.encode(jsonEncode(session)), vault.deliveryKeys.publicKey));
    // O cofre guardado precisa ter as mesmas chaves de entrega.
    storage.envelope = lockVault(
            vault,
            deriveVaultKey(_password,
                iterations: _iterations, salt: envelope.salt),
            iterations: _iterations)
        .toJsonString();

    final platform = _FakePlatform();
    await _pump(tester,
        TeacherGate(environment: _teacher(platform, storage, inbox: inbox)));
    await tester.enterText(find.byType(TextField), _password);
    await _tap(tester, find.text('Entrar'));
    await _tap(tester, find.text('5º A'));
    expect(find.text('1 sessão nova chegou.'), findsOneWidget);
    await _tap(tester, find.text('Sessões'));
    expect(find.text('1 sessão'), findsOneWidget);
    expect(find.text('Buscar entregas'), findsOneWidget);

    // Buscar de novo não repete.
    await _tap(tester, find.text('Buscar entregas'));
    expect(find.text('Nenhuma sessão nova.'), findsOneWidget);
    expect(find.text('1 sessão'), findsOneWidget);
  });

  testWidgets('com uma sessão só, compara com a base e mostra o mapa do olhar',
      (tester) async {
    final platform = _FakePlatform();
    final storage = await _storedVault();
    await _pump(tester, TeacherGate(environment: _teacher(platform, storage)));
    await tester.enterText(find.byType(TextField), _password);
    await _tap(tester, find.text('Entrar'));
    await _tap(tester, find.text('5º A'));

    final session = Map<String, dynamic>.from(
        (_comparison['sessions'] as List).first as Map);
    final trace = GazeTrace(
      t: [for (var i = 0; i < 100; i++) i / 20],
      x: [for (var i = 0; i < 100; i++) -8.0 + (i % 20)],
      y: [for (var i = 0; i < 100; i++) -6.0 + 2.0 * (i ~/ 20)],
    );
    session['heatmap'] =
        GazeHeatmap.fromTrace(trace, textArea: [-10.0, -8.0, 10.0, 4.0])
            .toJson();
    // O mesmo olhar, com o último quarto fora do celular, à direita.
    session['gaze_path'] = GazePath.sample(
      t: trace.t,
      x: [for (var i = 0; i < 100; i++) i >= 75 ? 35.0 : trace.x[i]],
      y: trace.y,
      state: [for (final _ in trace.t) GazeSampleState.gaze],
    ).toJson();
    platform.nextFiles = [(name: 'uma.json', text: jsonEncode(session))];
    await _tap(tester, find.text('Sessões'));
    await _tap(tester, find.text('Importar arquivos'));
    await _tap(tester, find.text('OK'));
    expect(find.text('Mapa do olhar'), findsOneWidget);

    // O time-lapse do olhar, e o GIF dele.
    await _tap(tester, find.text('Mapa do olhar'));
    expect(find.byKey(const Key('heatmap')), findsOneWidget);
    final share =
        tester.widget<Text>(find.byKey(const Key('off-screen-share'))).data!;
    expect(share, endsWith('% do tempo olhando fora da tela'));
    expect(int.parse(share.split('%').first), inInclusiveRange(22, 28));
    await _tap(tester, find.text('Time-lapse'));
    expect(find.byKey(const Key('gaze-replay')), findsOneWidget);
    await _tap(tester, find.byKey(const Key('gaze-replay-gif')));
    // Desenhar o fundo do GIF (toImage) precisa de tempo real.
    for (var i = 0; i < 20 && platform.savedBytes.isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final gif = platform.savedBytes.values.single;
    expect(String.fromCharCodes(gif.sublist(0, 6)), 'GIF89a');
    expect(platform.savedBytes.keys.single, endsWith('.gif'));
    await _tap(tester, find.text('Fechar'));

    // Relatórios em PDF: da sessão e da turma.
    Future<Uint8List> report(Finder button) async {
      platform.savedBytes.clear();
      await _tap(tester, button);
      for (var i = 0; i < 50 && platform.savedBytes.isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(platform.savedBytes.keys.single, endsWith('.pdf'));
      return platform.savedBytes.values.single;
    }

    final single = await report(find.text('Relatório (PDF)'));
    expect(String.fromCharCodes(single.sublist(0, 5)), '%PDF-');
    expect(platform.savedBytes.keys.single, startsWith('eyelearn-relatorio-'));
    final all = await report(find.byKey(const Key('class-report')));
    expect(String.fromCharCodes(all.sublist(0, 5)), '%PDF-');

    await _tap(tester, find.text('Leitura da turma'));
    // Uma sessão só: não há turma, e a base entra sozinha.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await _settle(tester);
    expect(find.text('Com a base ETDD70'), findsOneWidget);
    expect(find.byType(ComparisonChart), findsOneWidget);
    expect(find.byKey(const Key('heatmap')), findsOneWidget);
    expect(
        find.textContaining('do tempo de olhar sobre o texto'), findsOneWidget);
    expect(find.textContaining('Não é diagnóstico'), findsWidgets);
  });
}
