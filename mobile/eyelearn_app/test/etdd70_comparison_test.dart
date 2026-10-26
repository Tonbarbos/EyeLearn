import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_app/src/teacher/etdd70_comparison.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _reference =
    jsonDecode(File('assets/etdd70_reference.json').readAsStringSync())
        as Map<String, dynamic>;

final _session = Session.fromJson(Map<String, dynamic>.from((jsonDecode(
        File('../eyelearn_core/assets/comparison_example.json')
            .readAsStringSync())['sessions'] as List)
    .first as Map));

void main() {
  test('a referência tem as três tarefas e as três condições', () {
    final tasks = _reference['tasks'] as Map<String, dynamic>;
    expect(tasks.keys, containsAll(['syllables', 'text', 'pseudotext']));
    for (final task in tasks.values) {
      expect((task as Map).keys,
          containsAll(['original', '30hz_2deg', '15hz_2deg']));
    }
  });

  test('escolhe a condição pela taxa da sessão', () {
    expect(etdd70Condition(250), 'original');
    expect(etdd70Condition(29), '30hz_2deg');
    expect(etdd70Condition(19), '15hz_2deg');
  });

  test('desvios em relação às crianças sem dislexia', () {
    final c = compareWithEtdd70(_session, _reference)!;
    expect(c.conditionLabel, '30 Hz + 2°');
    expect(c.nTypical, 35);
    expect(c.rows, hasLength(featureNames.length));
    final row = c.rows.firstWhere((r) => r.feature == 'fixation_rate');
    final stats = ((((_reference['tasks'] as Map)['text'] as Map)['30hz_2deg']
            as Map)['groups'] as Map)['typical']['features']['fixation_rate']
        as Map;
    expect(row.typical.mean, stats['mean']);
    expect(row.zTypical,
        closeTo((row.value - stats['mean']) / stats['std'], 1e-12));
  });

  testWidgets('o painel mostra a tabela e o aviso', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showEtdd70Comparison(context, _session, 'Alice',
              loadReference: () async => _reference),
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Alice × ETDD70'), findsOneWidget);
    expect(find.byKey(const Key('etdd70-table')), findsOneWidget);
    expect(find.textContaining('Não é diagnóstico'), findsOneWidget);
    expect(find.text('Fixações por segundo'), findsOneWidget);
  });
}
