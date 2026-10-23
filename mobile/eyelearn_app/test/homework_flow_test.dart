import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/homework_app.dart';
import 'package:eyelearn_app/src/session/class_storage.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pacote fechado pelo Python (`scripts/make_roster_fixture.py`).
final _demo = jsonDecode(File('assets/demo_class.json').readAsStringSync())
    as Map<String, dynamic>;
final fragment = _demo['fragment'] as String;
final code = _demo['code'] as String;
final pins = (_demo['pins_for_tests'] as Map).cast<String, String>();
final today = DateTime.parse(_demo['today'] as String);
final roster = Roster.fromJson(_demo['expected'] as Map<String, dynamic>);

HomeworkEnvironment _environment(
  ClassStorage storage, {
  String? link,
}) =>
    HomeworkEnvironment(
      models: const {},
      gaze: SyntheticGazeSource.new,
      storage: storage,
      clock: () => today.add(const Duration(hours: 15)),
      initialLink: link,
    );

/// O mascote do cabeçalho pisca para sempre, e `pumpAndSettle` nunca
/// terminaria: avança um tempo fixo, que cobre transições e esperas curtas.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpApp(WidgetTester tester, HomeworkEnvironment env) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(HomeworkApp(environment: env));
  await _settle(tester);
}

void main() {
  group('entrar na turma', () {
    testWidgets('com o link na barra de endereço, pede só o código',
        (tester) async {
      final storage = MemoryClassStorage();
      await _pumpApp(
        tester,
        _environment(storage, link: 'https://x.org/#t=$fragment'),
      );
      expect(find.text('Link da turma'), findsNothing);
      await tester.enterText(find.byType(TextField), code.toLowerCase());
      await tester.tap(find.text('Entrar'));
      await _settle(tester);
      expect(find.text('Quem vai ler hoje?'), findsOneWidget);
      expect((await storage.load())!.code, code.toLowerCase());
    });

    testWidgets('sem link, pede link e código', (tester) async {
      await _pumpApp(tester, _environment(MemoryClassStorage()));
      expect(find.text('Link da turma'), findsOneWidget);
    });

    testWidgets('código errado avisa e não entra', (tester) async {
      final storage = MemoryClassStorage();
      await _pumpApp(tester, _environment(storage, link: '#t=$fragment'));
      await tester.enterText(find.byType(TextField), 'AAAA-AAAA');
      await tester.tap(find.text('Entrar'));
      await _settle(tester);
      expect(find.textContaining('não confere'), findsOneWidget);
      expect(await storage.load(), isNull);
    });

    testWidgets('turma guardada abre direto nos nomes', (tester) async {
      final storage = MemoryClassStorage();
      await storage.save(
        packageJson: Roster.openSealed(fragment, code),
        code: code,
      );
      await _pumpApp(tester, _environment(storage));
      expect(find.text('Quem vai ler hoje?'), findsOneWidget);
    });

    testWidgets('link novo da mesma turma abre com o código guardado',
        (tester) async {
      final storage = MemoryClassStorage();
      await storage.save(packageJson: '{"stale": true}', code: code);
      // O pacote guardado é ilegível de propósito: só o link novo serve.
      await storage.save(
        packageJson: Roster.openSealed(fragment, code),
        code: code,
      );
      await _pumpApp(tester, _environment(storage, link: '#t=$fragment'));
      expect(find.text('Quem vai ler hoje?'), findsOneWidget);
    });

    testWidgets('sair da turma volta à entrada', (tester) async {
      final storage = MemoryClassStorage();
      await storage.save(
        packageJson: Roster.openSealed(fragment, code),
        code: code,
      );
      await _pumpApp(tester, _environment(storage));
      await tester.tap(find.text('Sair desta turma'));
      await _settle(tester);
      expect(find.text('Entrar na turma'), findsOneWidget);
      expect(await storage.load(), isNull);
    });
  });

  group('atividades do aluno', () {
    Future<void> login(WidgetTester tester, MemoryClassStorage storage) async {
      await storage.save(
        packageJson: Roster.openSealed(fragment, code),
        code: code,
      );
      await _pumpApp(tester, _environment(storage));
      final ana = roster.students.firstWhere((s) => s.displayName == 'Ana S.');
      await tester.tap(find.text('Ana S.'));
      await _settle(tester);
      for (final digit in pins[ana.code]!.split('')) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      // O PIN é conferido noutro isolate (compute), que anda em tempo real,
      // não no relógio falso do teste.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      await _settle(tester);
    }

    testWidgets('depois do PIN, mostra as atividades com os estados',
        (tester) async {
      await login(tester, MemoryClassStorage());
      expect(find.text('Oi, Ana!'), findsOneWidget);
      expect(find.text('Você tem 2 atividades para fazer.'), findsOneWidget);
      expect(find.text('Fazer agora'), findsNWidgets(2));
      expect(find.text('Prazo encerrado'), findsOneWidget);
      expect(find.textContaining('Começa em'), findsOneWidget);
    });

    testWidgets('atividade feita aparece como feita', (tester) async {
      final storage = MemoryClassStorage();
      final ana = roster.students.firstWhere((s) => s.displayName == 'Ana S.');
      final open = roster.activities[1];
      await storage.markDone(ana.code, open.code);
      await login(tester, storage);
      expect(find.text('Feita'), findsOneWidget);
      expect(find.text('Você tem 1 atividade para fazer.'), findsOneWidget);
    });

    testWidgets('o que um aluno fez não aparece para o colega', (tester) async {
      final storage = MemoryClassStorage();
      final bruno =
          roster.students.firstWhere((s) => s.displayName == 'Bruno L.');
      await storage.markDone(bruno.code, roster.activities[1].code);
      await login(tester, storage);
      expect(find.text('Feita'), findsNothing);
    });
  });
}
