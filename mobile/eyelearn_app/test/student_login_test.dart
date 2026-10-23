import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_app/src/ui/student_login.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A turma fictícia da pré-visualização, gerada pelo Python.
final _demo = jsonDecode(File('assets/demo_class.json').readAsStringSync())
    as Map<String, dynamic>;
final roster = Roster.fromJson(_demo['expected'] as Map<String, dynamic>);
final pins = (_demo['pins_for_tests'] as Map).cast<String, String>();

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Conferência síncrona e real: sem `compute`, que no teste não acrescenta
/// nada, mas com o PBKDF2 de verdade.
Future<bool> _check(RosterStudent student, String pin) async =>
    student.checkPin(pin);

Future<void> _type(WidgetTester tester, String pin) async {
  for (final digit in pin.split('')) {
    await tester.tap(find.text(digit));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  group('StudentPicker', () {
    testWidgets('mostra um cartão por aluno, pelo nome de exibição',
        (tester) async {
      await tester.pumpWidget(
        _host(StudentPicker(roster: roster, onSelected: (_) {})),
      );
      for (final student in roster.students) {
        expect(find.text(student.displayName), findsOneWidget);
      }
    });

    testWidgets('tocar no nome escolhe o aluno', (tester) async {
      RosterStudent? chosen;
      await tester.pumpWidget(
        _host(StudentPicker(roster: roster, onSelected: (s) => chosen = s)),
      );
      final bruno = roster.students.firstWhere(
        (s) => s.displayName.startsWith('Bruno'),
      );
      await tester.tap(find.text(bruno.displayName));
      expect(chosen?.code, bruno.code);
    });
  });

  group('PinScreen', () {
    late RosterStudent student;
    late PinAttemptLimiter limiter;
    late int accepted;

    setUp(() {
      student = roster.students.first;
      limiter = PinAttemptLimiter(maxFailures: 3);
      accepted = 0;
    });

    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: PinScreen(
            student: student,
            limiter: limiter,
            onAccepted: () => accepted++,
            check: _check,
          ),
        ),
      );
    }

    testWidgets('cumprimenta pelo primeiro nome', (tester) async {
      await open(tester);
      expect(
        find.text('Oi, ${student.displayName.split(' ').first}!'),
        findsOneWidget,
      );
    });

    testWidgets('o PIN certo entra', (tester) async {
      await open(tester);
      await _type(tester, pins[student.code]!);
      expect(accepted, 1);
    });

    testWidgets('o PIN errado avisa e deixa tentar de novo', (tester) async {
      await open(tester);
      await _type(tester, '9999');
      expect(accepted, 0);
      expect(find.textContaining('não é o seu PIN'), findsOneWidget);
      await _type(tester, pins[student.code]!);
      expect(accepted, 1);
    });

    testWidgets('apagar corrige um dígito', (tester) async {
      await open(tester);
      final pin = pins[student.code]!;
      await _type(tester, pin.substring(0, 3));
      await tester.tap(find.bySemanticsLabel('Apagar'));
      await tester.pump();
      await _type(tester, pin.substring(2));
      expect(accepted, 1);
    });

    testWidgets('bloqueia depois de errar demais', (tester) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await _type(tester, '9999');
      }
      expect(find.textContaining('chame o professor'), findsOneWidget);
      // Bloqueado, nem o PIN certo entra: o teclado não aceita toque.
      await _type(tester, pins[student.code]!);
      expect(accepted, 0);
    });

    testWidgets('o bloqueio vale ao voltar para a tela', (tester) async {
      for (var i = 0; i < 3; i++) {
        limiter.attempt(student, '9999');
      }
      await open(tester);
      expect(find.textContaining('chame o professor'), findsOneWidget);
    });

    testWidgets('não mostra os dígitos digitados', (tester) async {
      await open(tester);
      final pin = pins[student.code]!;
      await _type(tester, pin.substring(0, 2));
      // Cada dígito aparece uma vez, na tecla; nenhum eco na tela.
      for (final digit in pin.substring(0, 2).split('')) {
        expect(find.text(digit), findsOneWidget);
      }
    });
  });
}
