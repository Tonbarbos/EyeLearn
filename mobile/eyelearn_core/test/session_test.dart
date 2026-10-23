/// Testes da sessão exportável.
///
/// A sessão é o que sai do aparelho. Dois requisitos vêm do relatório, não da
/// conveniência: nada de imagem de rosto e nada de nome de criança (seção 4.6).
/// Os testes abaixo verificam os dois no formato serializado, que é onde eles
/// podem ser violados sem ninguém notar.
library;

import 'dart:convert';
import 'dart:io';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

void main() {
  final artifact = ModelArtifact.fromJsonString(
    File('assets/model_text.json').readAsStringSync(),
  );

  Session buildSession({
    double validRatio = 0.95,
    double samplingRate = 28.0,
    String code = 'A17',
  }) =>
      Session.fromAnalysis(
        participantCode: code,
        task: 'leitura_de_texto',
        startedAt: DateTime.utc(2026, 10, 12, 14, 30),
        durationSeconds: 42.5,
        samplingRateHz: samplingRate,
        validSampleRatio: validRatio,
        features: {for (final name in featureNames) name: 1.0},
        artifact: artifact,
      );

  group('serialização', () {
    test('faz ida e volta sem perder nada', () {
      final original = buildSession();
      final restored = Session.fromJsonString(original.toJsonString());

      expect(restored.participantCode, equals(original.participantCode));
      expect(restored.task, equals(original.task));
      expect(restored.startedAt, equals(original.startedAt));
      expect(restored.durationSeconds, equals(original.durationSeconds));
      expect(restored.samplingRateHz, equals(original.samplingRateHz));
      expect(restored.validSampleRatio, equals(original.validSampleRatio));
      expect(restored.score, equals(original.score));
      for (final name in featureNames) {
        expect(restored.features[name], equals(original.features[name]));
      }
    });

    test('grava todas as características na ordem canônica', () {
      final json = buildSession().toJson();
      final features = json['features'] as Map<String, dynamic>;
      expect(features.keys.toList(), equals(featureNames));
    });

    test('recusa versão de formato desconhecida', () {
      final json = buildSession().toJson();
      json['format_version'] = 999;
      expect(
        () => Session.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('grava o instante em UTC', () {
      // O painel do professor compara sessões de aparelhos diferentes; sem
      // fuso comum a ordenação ficaria errada.
      final json = buildSession().toJson();
      expect(json['started_at'] as String, endsWith('Z'));
    });

    test('registra a procedência do modelo', () {
      final json = buildSession().toJson();
      final model = json['model'] as Map<String, dynamic>;
      expect(model['score_kind'], isNotNull);
      expect(model['training_data'], isNotNull);
    });
  });

  group('privacidade do que sai do aparelho', () {
    test('não carrega quadros nem imagem', () {
      // Imagem facial é dado biométrico, e portanto dado pessoal sensível
      // segundo o artigo 5º da LGPD. A sessão não tem onde guardá-la, e este
      // teste é o que impede que um campo assim seja acrescentado sem
      // discussão.
      final json = jsonEncode(buildSession().toJson()).toLowerCase();
      for (final forbidden in ['image', 'frame', 'jpeg', 'png', 'base64']) {
        expect(json.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('não carrega coordenadas brutas do olhar', () {
      // O percurso completo é dado comportamental identificável e não é
      // necessário ao painel: as características agregadas bastam.
      final json = buildSession().toJson();
      expect(json.containsKey('samples'), isFalse);
      expect(json.containsKey('gaze'), isFalse);
    });

    test('identifica por código, não por nome', () {
      final json = buildSession(code: 'A17').toJson();
      expect(json['participant_code'], equals('A17'));
      expect(json.containsKey('name'), isFalse);
      expect(json.containsKey('student_name'), isFalse);
    });
  });

  group('qualidade da gravação', () {
    test('aceita uma captura boa', () {
      expect(
        buildSession(validRatio: 0.95, samplingRate: 28.0).hasUsableQuality(),
        isTrue,
      );
    });

    test('reprova perda excessiva de amostras', () {
      expect(
        buildSession(validRatio: 0.4, samplingRate: 28.0).hasUsableQuality(),
        isFalse,
      );
    });

    test('reprova taxa de amostragem baixa', () {
      // Uma sessão a 12 Hz não é comparável a uma a 30 Hz: a curva de
      // degradação mostra que a acurácia depende da taxa.
      expect(
        buildSession(validRatio: 0.95, samplingRate: 12.0).hasUsableQuality(),
        isFalse,
      );
    });

    test('os pisos são ajustáveis', () {
      final session = buildSession(validRatio: 0.6, samplingRate: 25.0);
      expect(session.hasUsableQuality(minValidRatio: 0.5), isTrue);
      expect(session.hasUsableQuality(minValidRatio: 0.7), isFalse);
    });
  });

  group('pontuação', () {
    test('vem do artefato, não é recalculada na sessão', () {
      final features = {for (final name in featureNames) name: 1.0};
      expect(
        buildSession().score,
        equals(artifact.scoreFeatures(features)),
      );
    });
  });
}
