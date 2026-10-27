/// Sessão exportável: o que viaja do celular para o painel do professor.
///
/// **Sem servidor.** O aplicativo grava um arquivo JSON e o entrega pela folha
/// de compartilhamento do sistema; o painel do professor o importa. Nada
/// trafega pela rede, o que mantém verdadeiro o parágrafo de privacidade da
/// seção 4.6 do relatório, em vez de exigir reescrevê-lo.
///
/// **Sem quadros de vídeo.** As imagens da câmera são processadas e descartadas
/// quadro a quadro; o que sobra são coordenadas do olhar. Nenhuma imagem de
/// rosto entra na sessão, nem fica no aparelho.
///
/// **Sem nome.** A sessão carrega um identificador pseudônimo; a associação
/// entre identificador e aluno fica com o professor, fora do aplicativo.
library;

import 'dart:convert';

import 'features.dart';
import 'gaze_heatmap.dart';
import 'model.dart';

/// Versão do formato de sessão.
const int sessionFormatVersion = 1;

/// Uma gravação concluída, pronta para exportação.
class Session {
  /// Identificador pseudônimo do participante.
  ///
  /// Nunca o nome da criança: é o código do aluno na lista da turma, e a
  /// correspondência com o nome fica no banco do professor.
  final String participantCode;

  /// Código da atividade em que a criança entrou pelo QR, ou `null` para
  /// sessões sem atividade (demonstração e formato anterior). O painel recusa
  /// a sessão se a atividade não for da turma do aluno.
  final String? activityCode;

  /// Nome da tarefa de leitura.
  final String task;

  final DateTime startedAt;

  /// Duração da tarefa, em segundos.
  final double durationSeconds;

  /// Taxa de amostragem mediana observada, em Hz.
  ///
  /// Viaja porque é o principal indicador de qualidade da captura em aparelho
  /// de mão, e porque o estudo de degradação mostra que a acurácia depende
  /// dela: uma sessão a 12 Hz não é comparável a uma a 30 Hz.
  final double samplingRateHz;

  /// Proporção de amostras aproveitáveis.
  final double validSampleRatio;

  final Map<String, double> features;

  /// Pontuação do modelo.
  ///
  /// Viaja para o painel do professor, e **não** é apresentada à criança: o
  /// aplicativo do aluno não mostra resultado nenhum. Ver [toJson].
  final double score;

  /// Procedência do modelo que produziu [score].
  final Map<String, dynamic> modelMetadata;

  /// Onde o olhar ficou, numa grade grossa; `null` em sessão antiga.
  final GazeHeatmap? heatmap;

  const Session({
    required this.participantCode,
    required this.task,
    required this.startedAt,
    required this.durationSeconds,
    required this.samplingRateHz,
    required this.validSampleRatio,
    required this.features,
    required this.score,
    required this.modelMetadata,
    this.activityCode,
    this.heatmap,
  });

  /// Monta a sessão a partir da análise e do artefato usado.
  factory Session.fromAnalysis({
    required String participantCode,
    required String task,
    required DateTime startedAt,
    required double durationSeconds,
    required double samplingRateHz,
    required double validSampleRatio,
    required Map<String, double> features,
    required ModelArtifact artifact,
    String? activityCode,
    GazeHeatmap? heatmap,
  }) =>
      Session(
        participantCode: participantCode,
        activityCode: activityCode,
        task: task,
        startedAt: startedAt,
        durationSeconds: durationSeconds,
        samplingRateHz: samplingRateHz,
        validSampleRatio: validSampleRatio,
        features: features,
        score: artifact.scoreFeatures(features),
        modelMetadata: {
          'score_kind': artifact.scoreKind.wireName,
          'feature_names': artifact.featureNames,
          ...artifact.metadata,
        },
        heatmap: heatmap,
      );

  /// Se a gravação tem qualidade suficiente para ser interpretada.
  ///
  /// O painel do professor marca a sessão abaixo do piso em vez de escondê-la:
  /// saber que a captura falhou é informação, e uma sessão que desaparece sem
  /// explicação levaria o professor a repetir a atividade sem saber por quê.
  bool hasUsableQuality({
    double minValidRatio = 0.75,
    // Igual a MIN_SAMPLING_RATE_HZ em eyelearn/session.py; ver a nota lá.
    double minSamplingRateHz = 10.0,
  }) =>
      validSampleRatio >= minValidRatio && samplingRateHz >= minSamplingRateHz;

  Map<String, dynamic> toJson() => {
        'format_version': sessionFormatVersion,
        'participant_code': participantCode,
        if (activityCode != null) 'activity_code': activityCode,
        'task': task,
        'started_at': startedAt.toUtc().toIso8601String(),
        'duration_seconds': durationSeconds,
        'sampling_rate_hz': samplingRateHz,
        'valid_sample_ratio': validSampleRatio,
        'features': {
          for (final name in featureNames) name: features[name] ?? 0.0,
        },
        'score': score,
        'model': modelMetadata,
        if (heatmap != null) 'heatmap': heatmap!.toJson(),
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory Session.fromJson(Map<String, dynamic> json) {
    final version = json['format_version'];
    if (version != sessionFormatVersion) {
      throw FormatException(
        'versão de sessão não suportada: $version; '
        'esperada $sessionFormatVersion',
      );
    }

    final rawFeatures = (json['features'] as Map<String, dynamic>);
    return Session(
      participantCode: json['participant_code'] as String,
      activityCode: json['activity_code'] as String?,
      task: json['task'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      durationSeconds: (json['duration_seconds'] as num).toDouble(),
      samplingRateHz: (json['sampling_rate_hz'] as num).toDouble(),
      validSampleRatio: (json['valid_sample_ratio'] as num).toDouble(),
      features: {
        for (final entry in rawFeatures.entries)
          entry.key: (entry.value as num).toDouble(),
      },
      score: (json['score'] as num).toDouble(),
      modelMetadata: (json['model'] as Map<String, dynamic>?) ?? const {},
      heatmap: json['heatmap'] == null
          ? null
          : GazeHeatmap.fromJson(json['heatmap'] as Map<String, dynamic>),
    );
  }

  factory Session.fromJsonString(String source) =>
      Session.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
