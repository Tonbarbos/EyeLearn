/// Teste diferencial contra o Python.
///
/// O pipeline existe duas vezes: em Python, onde o modelo é treinado, e em
/// Dart, onde o aparelho extrai as características. Nada garante que as duas
/// implementações concordem. Um limiar diferente, um limite de laço trocado ou
/// uma ordem de características embaralhada produzem um vetor ligeiramente
/// diferente -- e o modelo recebe uma entrada que nunca viu e devolve uma
/// predição errada sem erro nenhum: não há exceção, não há valor fora de faixa,
/// só uma resposta diferente.
///
/// `scripts/build_mobile_assets.py` congela o que o Python calcula, estágio por
/// estágio, em `assets/golden.json`. Este teste afirma que o Dart chega aos
/// mesmos números. Nenhum dos lados é oráculo isolado, mas a divergência entre
/// os dois é sempre defeito de um deles.
///
/// Foi assim que apareceu a divergência da floresta aleatória: o scikit-learn
/// converte a entrada das árvores para precisão simples antes de percorrê-las,
/// e sem reproduzir essa conversão a travessia caía em outra folha.
library;

import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Tolerância relativa das comparações numéricas.
///
/// Não é igualdade exata porque o lado Python usa `numpy.hypot` e somas
/// vetorizadas, cujas ordens de operação diferem das daqui no último bit. A
/// tolerância continua sete ordens de grandeza mais apertada do que qualquer
/// defeito real produziria.
const double tolerance = 1e-9;

void main() {
  final fixture = _loadJson('assets/golden.json');
  final artifact = ModelArtifact.fromJsonString(
    File('assets/model.json').readAsStringSync(),
  );

  final cases =
      (fixture['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

  group('contrato do arquivo de vetores de ouro', () {
    test('a versão é a esperada', () {
      expect(fixture['version'], equals(1));
    });

    test('há casos a verificar', () {
      // Um arquivo vazio faria a suíte inteira passar sem verificar nada.
      expect(cases, isNotEmpty);
    });

    test('a ordem das características coincide com a da biblioteca', () {
      expect(
        (fixture['feature_names'] as List<dynamic>).cast<String>(),
        equals(featureNames),
      );
    });

    test('a ordem das características coincide com a do artefato', () {
      expect(artifact.featureNames, equals(featureNames));
    });

    test('os parâmetros de extração coincidem com os do artefato', () {
      // O arquivo de ouro tem de descrever a mesma extração que o modelo
      // embarcado espera; montados de fontes separadas, poderiam divergir.
      final golden = fixture['preprocessing'] as Map<String, dynamic>;
      final config = artifact.preprocessing;

      expect(golden['method'], equals(config.method));
      expect(golden['smoothing_ms'], closeTo(config.smoothingMs, 0));
      expect(golden['max_gap'], closeTo(config.maxGap, 0));
      expect(
        golden['velocity_threshold'],
        closeTo(config.velocityThreshold, 0),
      );
      expect(
        golden['min_fixation_duration'],
        closeTo(config.minFixationDuration, 0),
      );
    });
  });

  group('o pipeline Dart reproduz o Python', () {
    for (final testCase in cases) {
      final id = testCase['id'] as String;
      final note = testCase['note'] as String;
      final expected = testCase['expected'] as Map<String, dynamic>;
      final trace = _traceFromJson(testCase['samples'] as Map<String, dynamic>);

      group('$id ($note)', () {
        late AnalysisResult result;

        setUp(() {
          result = analyse(trace, artifact.preprocessing);
        });

        test('conta as amostras válidas igual', () {
          final validCount =
              dropInvalid(trace, boundsDeg: artifact.preprocessing.boundsDeg)
                  .length;
          expect(validCount, equals(expected['valid_sample_count']));
        });

        test('detecta a mesma quantidade de fixações', () {
          expect(
            result.fixations.length,
            equals(expected['fixation_count']),
            reason: 'divergência na detecção de fixações, antes das '
                'características',
          );
        });

        test('detecta a mesma quantidade de sacadas', () {
          expect(result.saccades.length, equals(expected['saccade_count']));
        });

        test('classifica as sacadas igual', () {
          final regressions = result.saccades
              .where((s) => s.kind == SaccadeKind.regressive)
              .length;
          final sweeps = result.saccades
              .where((s) => s.kind == SaccadeKind.lineSweep)
              .length;

          expect(regressions, equals(expected['regression_count']));
          expect(sweeps, equals(expected['line_sweep_count']));
        });

        test('posiciona as fixações nos mesmos instantes', () {
          final goldenFixations = (expected['fixations'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          expect(result.fixations.length, equals(goldenFixations.length));

          for (var i = 0; i < goldenFixations.length; i++) {
            final actual = result.fixations[i];
            final golden = goldenFixations[i];
            expect(
              actual.tStart,
              _near(golden['t_start'] as num),
              reason: 'fixação $i: início',
            );
            expect(
              actual.tEnd,
              _near(golden['t_end'] as num),
              reason: 'fixação $i: fim',
            );
            expect(actual.x, _near(golden['x'] as num),
                reason: 'fixação $i: x');
            expect(actual.y, _near(golden['y'] as num),
                reason: 'fixação $i: y');
          }
        });

        test('calcula as mesmas características', () {
          final golden = expected['features'] as Map<String, dynamic>;
          for (final name in featureNames) {
            expect(
              result.features[name],
              _near(golden[name] as num),
              reason: 'característica $name',
            );
          }
        });

        test('produz a mesma pontuação e a mesma classe', () {
          final vector = buildVector(
            result.features,
            order: artifact.featureNames,
          );
          expect(
            artifact.score(vector),
            _near(expected['score'] as num),
            reason: 'pontuação do modelo',
          );
          expect(artifact.predict(vector), equals(expected['label']));
        });
      });
    }
  });
}

Map<String, dynamic> _loadJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// Monta o percurso a partir do JSON.
///
/// O lado Python grava `NaN` como `null`, porque `NaN` não é JSON válido. A
/// conversão de volta tem de acontecer aqui, ou as amostras perdidas por
/// piscada chegariam como zero -- uma coordenada legítima no centro da tela.
GazeTrace _traceFromJson(Map<String, dynamic> samples) => GazeTrace(
      t: _coordinates(samples['t']),
      x: _coordinates(samples['x']),
      y: _coordinates(samples['y']),
    );

List<double> _coordinates(dynamic value) => (value as List<dynamic>)
    .map((item) => item == null ? double.nan : (item as num).toDouble())
    .toList();

/// Comparação com tolerância relativa, que também aceita zero exato.
Matcher _near(num expected) {
  final target = expected.toDouble();
  final margin = target.abs() * tolerance;
  return closeTo(target, margin < tolerance ? tolerance : margin);
}
