/// Características de leitura: porta de `eyelearn/features/reading.py`.
///
/// Todas as características são taxas, médias ou proporções, nunca contagens
/// brutas: contagem bruta cresce com a duração da gravação, e gravações de
/// duração diferente não seriam comparáveis entre participantes.
library;

import 'dart:math' as math;

import 'events.dart';

/// Ordem canônica das características.
///
/// O vetor de entrada do modelo segue esta ordem. Ela tem de ser idêntica à de
/// `FEATURE_NAMES` no lado Python: uma ordem diferente troca o significado das
/// colunas sem erro nenhum -- o modelo recebe a duração média onde espera a
/// proporção de regressões e devolve uma resposta plausível e errada. O
/// artefato de modelo carrega a sua própria lista, e [buildVector] confere.
const List<String> featureNames = [
  'fixation_rate',
  'fixation_duration_mean',
  'fixation_duration_std',
  'fixation_duration_median',
  'saccade_rate',
  'saccade_amplitude_mean',
  'saccade_amplitude_std',
  'progressive_amplitude_mean',
  'regression_ratio',
  'regression_rate',
  'peak_velocity_mean',
  'line_sweep_rate',
  'reading_time',
  'scanpath_length',
];

/// Calcula o vetor de características de uma gravação.
///
/// Com listas vazias todas as características valem `0.0`. A alternativa --
/// devolver `NaN` -- obrigaria o classificador a imputar valores, e o valor
/// imputado diria mais sobre a imputação do que sobre o leitor. Uma gravação
/// sem fixação detectada é problema de qualidade de sinal e deve ser filtrada
/// antes, por `validSampleRatio`.
///
/// [readingTime] é a duração da tarefa em segundos. Quando omitida, é estimada
/// pelo intervalo entre o início da primeira fixação e o fim da última.
Map<String, double> extractFeatures(
  List<Fixation> fixations,
  List<Saccade> saccades, {
  double? readingTime,
}) {
  if (readingTime != null && readingTime < 0) {
    throw ArgumentError('readingTime não pode ser negativo');
  }

  final span = readingTime ??
      (fixations.isEmpty ? 0.0 : fixations.last.tEnd - fixations.first.tStart);

  final durations = fixations.map((f) => f.duration).toList();
  final amplitudes = saccades.map((s) => s.amplitude).toList();
  final peaks = saccades.map((s) => s.peakVelocity).toList();

  final progressive =
      saccades.where((s) => s.kind == SaccadeKind.progressive).toList();
  final regressive =
      saccades.where((s) => s.kind == SaccadeKind.regressive).toList();
  final lineSweeps =
      saccades.where((s) => s.kind == SaccadeKind.lineSweep).toList();

  // As regressões são medidas contra as sacadas dentro da linha: o retorno de
  // linha é obrigatório em qualquer leitor e, no denominador, diluiria a
  // diferença entre os grupos.
  final withinLine = progressive.length + regressive.length;

  return {
    'fixation_rate': _rate(fixations.length, span),
    'fixation_duration_mean': _mean(durations),
    'fixation_duration_std': _std(durations),
    'fixation_duration_median': _median(durations),
    'saccade_rate': _rate(saccades.length, span),
    'saccade_amplitude_mean': _mean(amplitudes),
    'saccade_amplitude_std': _std(amplitudes),
    'progressive_amplitude_mean':
        _mean(progressive.map((s) => s.amplitude).toList()),
    'regression_ratio': withinLine > 0 ? regressive.length / withinLine : 0.0,
    'regression_rate': _rate(regressive.length, span),
    'peak_velocity_mean': _mean(peaks),
    'line_sweep_rate': _rate(lineSweeps.length, span),
    'reading_time': span,
    'scanpath_length': _sum(amplitudes),
  };
}

/// Converte o mapa de características no vetor na ordem de [order].
///
/// [order] vem do artefato de modelo, não desta biblioteca: é o que garante que
/// o vetor seja montado na ordem com que *aquele* modelo foi treinado, mesmo
/// que uma versão futura do aplicativo passe a extrair características a mais.
List<double> buildVector(
  Map<String, double> features, {
  List<String> order = featureNames,
}) {
  final missing = order.where((name) => !features.containsKey(name)).toList();
  if (missing.isNotEmpty) {
    throw ArgumentError('características ausentes: $missing');
  }
  return [for (final name in order) features[name]!];
}

double _rate(int count, double span) => span > 0 ? count / span : 0.0;

double _sum(List<double> values) {
  var total = 0.0;
  for (final value in values) {
    total += value;
  }
  return total;
}

double _mean(List<double> values) =>
    values.isEmpty ? 0.0 : _sum(values) / values.length;

/// Desvio padrão populacional, como o `numpy.std` sem `ddof`.
double _std(List<double> values) {
  if (values.isEmpty) return 0.0;
  final mean = _mean(values);
  var total = 0.0;
  for (final value in values) {
    final deviation = value - mean;
    total += deviation * deviation;
  }
  return math.sqrt(total / values.length);
}

/// Mediana, com a mesma convenção do `numpy.median` para tamanho par.
double _median(List<double> values) {
  if (values.isEmpty) return 0.0;
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) / 2.0;
}
