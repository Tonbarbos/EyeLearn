import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Sessões e comparação calculada pelo Python
/// (`scripts/make_comparison_fixture.py`).
final fixture = jsonDecode(
  File('assets/comparison_example.json').readAsStringSync(),
) as Map<String, dynamic>;
final sessions = [
  for (final payload
      in (fixture['sessions'] as List).cast<Map<String, dynamic>>())
    Session.fromJson(payload),
];
final expected = fixture['expected'] as Map<String, dynamic>;

void main() {
  final comparison = compareWithinClass(sessions, 'text');

  group('fronteira com o Python', () {
    test('mesmos participantes, na mesma ordem', () {
      // Fora: a gravação ruim (FFF777) e a de outra tarefa.
      expect(comparison.participantCodes, expected['participant_codes']);
    });

    test('mesmos escores z', () {
      final z = (expected['z_scores'] as List).cast<List>();
      for (var row = 0; row < z.length; row++) {
        for (var column = 0; column < z[row].length; column++) {
          expect(
            comparison.zScores[row][column],
            closeTo((z[row][column] as num).toDouble(), 1e-9),
            reason: '${comparison.participantCodes[row]} '
                '${featureNames[column]}',
          );
        }
      }
    });

    test('mesmos destacados', () {
      final outliers = (expected['outliers'] as Map).map(
        (key, value) => MapEntry(key as String, (value as List).cast<String>()),
      );
      expect(comparison.outliers(), outliers);
    });

    test('mesmas sugestões', () {
      final suggestions = (expected['suggestions'] as Map).map(
        (key, value) => MapEntry(key as String, (value as List).cast<String>()),
      );
      for (final code in comparison.participantCodes) {
        expect(comparison.suggestionsFor(code), suggestions[code],
            reason: code);
      }
    });
  });

  group('regras', () {
    test('vale a última gravação de quem repetiu', () {
      // A gravação antiga de BBB333 tinha tudo 3x maior; se entrasse, a média
      // subiria muito.
      final mean = comparison.classMean[featureNames.indexOf('reading_time')];
      final newest = sessions
          .where((s) => s.participantCode == 'BBB333' && s.task == 'text')
          .reduce((a, b) => a.startedAt.isAfter(b.startedAt) ? a : b);
      expect(newest.startedAt.day, 20);
      expect(mean, lessThan(newest.features['reading_time']! * 2));
    });

    test('característica constante dá escore zero, não infinito', () {
      final column = featureNames.indexOf('peak_velocity_mean');
      for (final row in comparison.zScores) {
        expect(row[column], 0.0);
      }
    });

    test('menos de três participantes avisa em vez de calcular', () {
      expect(
        () => compareWithinClass(sessions, 'syllables'),
        throwsA(isA<NotEnoughParticipants>()
            .having((e) => e.count, 'count', 1)
            .having((e) => e.message, 'message', contains('pelo menos 3'))),
      );
    });

    test('incluir as gravações ruins traz FFF777 de volta', () {
      final all = compareWithinClass(sessions, 'text', includeLowQuality: true);
      expect(all.participantCodes, contains('FFF777'));
    });
  });

  group('descreve sem diagnosticar', () {
    test('frases sem juízo', () {
      for (final value in [-3.0, -0.2, 0.0, 0.4, 3.0]) {
        final phrase = describeDirection(value);
        for (final word in ['ruim', 'pior', 'risco', 'alerta', 'grave']) {
          expect(phrase, isNot(contains(word)));
        }
      }
      expect(describeDirection(0.0), 'dentro da turma');
      expect(describeDirection(2.0), 'acima da turma');
      expect(describeDirection(-2.0), 'abaixo da turma');
    });

    test('rótulos em linguagem do professor', () {
      for (final (name, label) in presentedFeatures) {
        expect(featureNames, contains(name));
        expect(label, isNot(contains('_')));
      }
    });

    test('nenhuma sugestão fala em condição', () {
      for (final text in pedagogicalSuggestions.values) {
        for (final word in ['dislexia', 'TDAH', 'diagnóstico', 'transtorno']) {
          expect(text.toLowerCase(), isNot(contains(word.toLowerCase())));
        }
      }
    });
  });
}
