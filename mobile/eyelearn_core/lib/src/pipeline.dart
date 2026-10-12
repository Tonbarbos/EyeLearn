/// Do sinal bruto ao vetor de características: porta de `eyelearn/pipeline.py`.
///
/// Existe para que o aparelho e o treino tenham um caminho só. Qualquer
/// divergência de ordem ou de parâmetro entre os dois lados produz um vetor que
/// o modelo não reconhece, e o erro não aparece como erro -- aparece como
/// predição diferente.
library;

import 'events.dart';
import 'features.dart';
import 'model.dart';
import 'preprocess.dart' as preprocess;
import 'trace.dart';

/// Resultado da análise de uma gravação.
class AnalysisResult {
  final Map<String, double> features;
  final List<Fixation> fixations;
  final List<Saccade> saccades;

  /// Proporção de amostras aproveitáveis, antes do descarte.
  final double validSampleRatio;

  const AnalysisResult({
    required this.features,
    required this.fixations,
    required this.saccades,
    required this.validSampleRatio,
  });
}

/// Extrai as características de um percurso, com os parâmetros do artefato.
///
/// A ordem das etapas é a da metodologia: descarte das amostras inválidas,
/// suavização, detecção de eventos e extração. O tempo de leitura passado ao
/// extrator é a duração do percurso **antes** do descarte, que é a duração real
/// da tarefa; medi-lo depois encurtaria a tarefa de quem perdeu mais amostras e
/// distorceria todas as taxas.
AnalysisResult analyse(GazeTrace trace, PreprocessingConfig config) {
  final taskDuration = trace.duration;
  final ratio = preprocess.validSampleRatio(
    trace,
    boundsDeg: config.boundsDeg,
  );

  final cleaned = preprocess.dropInvalid(trace, boundsDeg: config.boundsDeg);
  // A janela vem da taxa do percurso já limpo, que é a taxa com que o sinal
  // efetivamente chega ao detector.
  final smoothed = preprocess.smooth(
    cleaned,
    config.smoothingWindow(cleaned.samplingRate),
  );

  final detected = detectEvents(
    smoothed,
    maxGap: config.maxGap,
    velocityThreshold: config.velocityThreshold,
    minFixationDuration: config.minFixationDuration,
  );

  return AnalysisResult(
    features: extractFeatures(
      detected.fixations,
      detected.saccades,
      readingTime: taskDuration,
    ),
    fixations: detected.fixations,
    saccades: detected.saccades,
    validSampleRatio: ratio,
  );
}
