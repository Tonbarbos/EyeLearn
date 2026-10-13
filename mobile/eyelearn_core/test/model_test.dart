/// Testes da leitura do artefato e da inferência.
///
/// O teste diferencial (`golden_test.dart`) verifica que a aritmética concorda
/// com o Python. Estes verificam o que o Python não pode verificar: o que
/// acontece quando o arquivo embarcado está errado, truncado ou de outra
/// versão. No aparelho isso é um caso real -- um ativo mal gerado chega ao
/// aplicativo instalado, e carregar silenciosamente um artefato inconsistente
/// produziria predição errada em vez de falha visível.
library;

import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

void main() {
  final source = File('assets/model_text.json').readAsStringSync();
  final payload = jsonDecode(source) as Map<String, dynamic>;

  /// Cópia profunda do artefato embarcado, para alterar sem contaminar os
  /// outros testes.
  Map<String, dynamic> mutated(void Function(Map<String, dynamic>) change) {
    final copy = jsonDecode(source) as Map<String, dynamic>;
    change(copy);
    return copy;
  }

  group('leitura do artefato', () {
    test('carrega o modelo embarcado', () {
      final artifact = ModelArtifact.fromJsonString(source);
      expect(artifact.version, equals(supportedArtifactVersion));
      expect(artifact.featureNames, equals(featureNames));
    });

    test('expõe a procedência do treino', () {
      // O aplicativo mostra um aviso enquanto o modelo vier de dados
      // sintéticos; sem este campo o aviso não poderia existir.
      final artifact = ModelArtifact.fromJsonString(source);
      expect(artifact.metadata['training_data'], isNotNull);
    });

    test('recusa versão desconhecida', () {
      // Um formato futuro pode ter a mesma forma e outra semântica.
      final payload = mutated((json) => json['version'] = 999);
      expect(
        () => ModelArtifact.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa modelo desconhecido', () {
      final payload = mutated(
        (json) =>
            (json['model'] as Map<String, dynamic>)['kind'] = 'transformer',
      );
      expect(
        () => ModelArtifact.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa padronizador de tamanho incompatível', () {
      final payload = mutated((json) {
        final scaler = json['scaler'] as Map<String, dynamic>;
        scaler['mean'] = (scaler['mean'] as List<dynamic>).sublist(1);
      });
      expect(
        () => ModelArtifact.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa escala nula no padronizador', () {
      // Escala zero faria a padronização dividir por zero e produzir
      // infinito, que atravessaria o modelo sem erro.
      final payload = mutated((json) {
        final scaler = json['scaler'] as Map<String, dynamic>;
        final scale = [...(scaler['scale'] as List<dynamic>)];
        scale[0] = 0;
        scaler['scale'] = scale;
      });
      expect(
        () => ModelArtifact.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa coeficientes em quantidade errada', () {
      final payload = mutated((json) {
        final model = json['model'] as Map<String, dynamic>;
        model['coef'] = (model['coef'] as List<dynamic>).sublist(1);
      });
      expect(
        () => ModelArtifact.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa score_kind desconhecido', () {
      final payload = mutated((json) => json['score_kind'] = 'logit');
      expect(
        () => ModelArtifact.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('inferência', () {
    final artifact = ModelArtifact.fromJsonString(source);

    test('recusa vetor de tamanho errado', () {
      expect(
        () => artifact.score(List<double>.filled(featureNames.length - 1, 0.0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('é determinística', () {
      final vector = List<double>.filled(featureNames.length, 0.5);
      expect(artifact.score(vector), equals(artifact.score(vector)));
    });

    test('a probabilidade fica entre zero e um', () {
      if (artifact.scoreKind != ScoreKind.probability) return;

      // Inclui valores absurdos: no aparelho uma captura ruim produz
      // características fora de qualquer faixa plausível, e a sigmoide tem de
      // saturar em vez de estourar.
      for (final value in [-1e6, -10.0, 0.0, 1.0, 1e6]) {
        final score = artifact.score(
          List<double>.filled(featureNames.length, value),
        );
        expect(score, inInclusiveRange(0.0, 1.0), reason: 'entrada $value');
        expect(score.isFinite, isTrue, reason: 'entrada $value');
      }
    });

    test('o limiar corresponde à natureza da pontuação', () {
      expect(
        artifact.threshold,
        equals(artifact.scoreKind == ScoreKind.probability ? 0.5 : 0.0),
      );
    });

    test('a classe prevista concorda com a pontuação e o limiar', () {
      final vector = List<double>.filled(featureNames.length, 0.3);
      final expected = artifact.score(vector) > artifact.threshold ? 1 : 0;
      expect(artifact.predict(vector), equals(expected));
    });

    test('monta o vetor na ordem do artefato, não na da biblioteca', () {
      // Se um dia o aplicativo extrair características a mais, o vetor tem de
      // continuar na ordem com que *este* modelo foi treinado.
      final features = {
        for (final name in featureNames) name: 0.0,
        'caracteristica_futura': 42.0,
      };
      expect(
        buildVector(features, order: artifact.featureNames).length,
        equals(artifact.featureNames.length),
      );
    });

    test('reclama de característica ausente', () {
      final features = {
        for (final name in featureNames.skip(1)) name: 0.0,
      };
      expect(
        () => artifact.scoreFeatures(features),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('janela de suavização', () {
    final config = ModelArtifact.fromJsonString(source).preprocessing;

    test('é sempre ímpar', () {
      // Janela par descentraria a média e deslocaria o sinal no tempo.
      for (final rate in [15.0, 24.0, 30.0, 60.0, 120.0, 250.0, 1000.0]) {
        expect(config.smoothingWindow(rate).isOdd, isTrue,
            reason: 'taxa $rate');
      }
    });

    test('taxa degenerada cai na identidade', () {
      expect(config.smoothingWindow(0.0), equals(1));
      expect(config.smoothingWindow(-1.0), equals(1));
    });

    test('coincide com a conversão do lado Python', () {
      // Os valores vêm de tests/test_features.py::TestSmoothingWindow. A
      // conversão vive nos dois lados porque a taxa só é conhecida em tempo de
      // execução, e no celular ela varia com a câmera e com a carga.
      if (config.smoothingMs != 20.0) return;

      expect(config.smoothingWindow(250.0), equals(5));
      expect(config.smoothingWindow(500.0), equals(9));
      expect(config.smoothingWindow(120.0), equals(3));
      expect(config.smoothingWindow(100.0), equals(1));
      expect(config.smoothingWindow(60.0), equals(1));
      expect(config.smoothingWindow(30.0), equals(1));
    });

    test('a 30 Hz não suaviza', () {
      // A taxa da câmera do celular. Cinco amostras ali durariam 167 ms e
      // apagariam a sacada inteira -- foi o defeito que a geração dos ativos
      // revelou.
      expect(config.smoothingWindow(30.0), equals(1));
    });
  });

  group('contrato do ativo embarcado', () {
    test('o arquivo é pequeno o bastante para embarcar', () {
      expect(source.length, lessThan(512 * 1024));
    });

    test('declara os parâmetros de extração', () {
      final preprocessing = payload['preprocessing'] as Map<String, dynamic>;
      expect(preprocessing['method'], isNotNull);
      expect(preprocessing['smoothing_ms'], isNotNull);
      expect(preprocessing['velocity_threshold'], isNotNull);
    });

    test('declara qual classe é a positiva', () {
      // Sem isso, a pontuação poderia ser lida ao contrário.
      final metadata = payload['metadata'] as Map<String, dynamic>;
      expect(metadata['positive_class'], equals('dyslexic'));
    });
  });
}
