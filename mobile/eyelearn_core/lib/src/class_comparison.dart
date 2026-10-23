/// Onde a leitura de cada criança fica em relação à da turma.
///
/// Porta de `compare_within_class`, `suggestions_for` e dos rótulos do painel
/// (`eyelearn/session.py`, `eyelearn/panel/charts.py`), para o painel do
/// professor no navegador. `test/class_comparison_test.dart` confere os escores
/// contra os que o Python calcula para as mesmas sessões.
///
/// **A normalização é intraturma, não contra um modelo clínico.** O painel
/// mostra a que distância da média da turma a criança está, em desvios, por
/// característica -- "lê mais devagar que a maioria dos colegas" é acionável
/// pelo professor; "pontuação 0,62" não é. Nada aqui produz rótulo
/// diagnóstico, e não há função que o produza.
library;

import 'dart:math' as math;

import 'features.dart';
import 'session.dart';

/// A partir de quantos desvios a característica é destacada.
///
/// Não é ponto de corte diagnóstico: é o que destaca, numa turma de trinta, as
/// poucas crianças que valem uma observação mais atenta. Com 1,0 metade da
/// turma apareceria; com 2,0, numa turma pequena, ninguém apareceria nunca.
const double highlightThreshold = 1.5;

/// As características que o painel mostra, com o nome que o professor lê.
///
/// O modelo usa catorze; o painel mostra as que têm leitura pedagógica.
const List<(String, String)> presentedFeatures = [
  ('fixation_duration_mean', 'Tempo em cada palavra'),
  ('fixation_rate', 'Paradas por segundo'),
  ('regression_ratio', 'Voltas no texto'),
  ('saccade_amplitude_mean', 'Tamanho dos saltos'),
  ('line_sweep_rate', 'Trocas de linha'),
  ('reading_time', 'Tempo total'),
];

/// Sugestões pedagógicas por característica em que a criança fica acima da
/// turma. Descrevem o que foi observado antes de propor o que fazer, para que
/// o professor possa discordar da leitura, e não só da sugestão.
const Map<String, String> pedagogicalSuggestions = {
  'fixation_duration_mean':
      'Fixa o olhar em cada palavra por mais tempo que a maioria da turma. '
          'Pode ajudar: textos com fonte maior e mais espaçamento, e tempo '
          'extra em atividades de leitura.',
  'regression_ratio':
      'Volta atrás no texto com mais frequência que a maioria da turma, o que '
          'costuma indicar que a decodificação está custando esforço. Pode '
          'ajudar: leitura acompanhada, com apoio na linha, e textos mais '
          'curtos por vez.',
  'fixation_rate': 'Faz mais paradas por segundo que a maioria da turma. Pode '
      'ajudar: dividir o texto em trechos menores, com pausa entre eles.',
  'reading_time': 'Levou mais tempo que a maioria da turma para a mesma '
      'tarefa. Pode ajudar: prever tempo adicional em leituras avaliativas.',
  'saccade_amplitude_mean':
      'Avança em saltos menores que a maioria da turma, lendo em pedaços '
          'mais curtos. Pode ajudar: destacar sílabas ou blocos de palavras no '
          'material.',
  'line_sweep_rate':
      'Troca de linha com dificuldade mais frequente que a maioria da turma. '
          'Pode ajudar: régua de leitura ou marcador de linha.',
};

/// Frase curta para o escore, sem juízo de valor: "acima da turma", nunca
/// "ruim" ou "preocupante".
String describeDirection(double value,
    {double threshold = highlightThreshold}) {
  if (value.abs() < threshold) return 'dentro da turma';
  return value > 0 ? 'acima da turma' : 'abaixo da turma';
}

/// Turma com menos de três participantes utilizáveis na tarefa.
class NotEnoughParticipants implements Exception {
  final String task;
  final int count;

  const NotEnoughParticipants(this.task, this.count);

  String get message => count == 0
      ? 'Ainda não há gravação utilizável desta tarefa.'
      : 'Só $count ${count == 1 ? 'criança tem' : 'crianças têm'} gravação '
          'utilizável desta tarefa; a comparação com a turma precisa de pelo '
          'menos 3.';

  @override
  String toString() => 'NotEnoughParticipants: $message';
}

class ClassComparison {
  final String task;

  /// Códigos dos participantes, em ordem.
  final List<String> participantCodes;

  /// Escores z, por participante e característica, na ordem de [featureNames].
  final List<List<double>> zScores;

  final List<double> classMean;
  final List<double> classStd;

  const ClassComparison({
    required this.task,
    required this.participantCodes,
    required this.zScores,
    required this.classMean,
    required this.classStd,
  });

  Map<String, double> forParticipant(String code) {
    final row = participantCodes.indexOf(code);
    if (row < 0) {
      throw ArgumentError.value(
          code, 'code', 'participante fora da comparação');
    }
    return {
      for (var column = 0; column < featureNames.length; column++)
        featureNames[column]: zScores[row][column],
    };
  }

  /// Características em que cada participante se afasta da turma.
  Map<String, List<String>> outliers({double threshold = highlightThreshold}) {
    final result = <String, List<String>>{};
    for (var row = 0; row < participantCodes.length; row++) {
      final flagged = [
        for (var column = 0; column < featureNames.length; column++)
          if (zScores[row][column].abs() >= threshold) featureNames[column],
      ];
      if (flagged.isNotEmpty) result[participantCodes[row]] = flagged;
    }
    return result;
  }

  /// Sugestões para um participante.
  ///
  /// Só as características em que a criança fica **acima** da turma: as seis
  /// com sugestão indicam mais esforço de leitura quando sobem. Ficar abaixo
  /// da média em duração de fixação não pede adaptação nenhuma.
  List<String> suggestionsFor(
    String code, {
    double threshold = highlightThreshold,
  }) {
    final scores = forParticipant(code);
    return [
      for (final MapEntry(key: name, value: z) in scores.entries)
        if (pedagogicalSuggestions.containsKey(name) && z >= threshold)
          pedagogicalSuggestions[name]!,
    ];
  }
}

/// Os escores z da turma numa tarefa.
///
/// Uma criança pode repetir a tarefa; vale a última gravação. Gravações abaixo
/// dos pisos de qualidade ficam fora por padrão: uma captura ruim distorceria
/// a média contra a qual todos os outros são medidos.
///
/// Lança [NotEnoughParticipants] com menos de três crianças: com duas, o
/// desvio padrão não descreve dispersão nenhuma, e o escore de cada uma seria
/// mecanicamente ±1.
ClassComparison compareWithinClass(
  List<Session> sessions,
  String task, {
  bool includeLowQuality = false,
}) {
  final selected = [
    for (final session in sessions)
      if (session.task == task &&
          (includeLowQuality || session.hasUsableQuality()))
        session,
  ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  final latest = <String, Session>{};
  for (final session in selected) {
    latest[session.participantCode] = session;
  }
  if (latest.length < 3) throw NotEnoughParticipants(task, latest.length);

  final codes = latest.keys.toList()..sort();
  final matrix = [
    for (final code in codes)
      [for (final name in featureNames) latest[code]!.features[name] ?? 0.0],
  ];

  final n = codes.length;
  final mean = List<double>.filled(featureNames.length, 0);
  final std = List<double>.filled(featureNames.length, 0);
  for (var column = 0; column < featureNames.length; column++) {
    var sum = 0.0;
    for (final row in matrix) {
      sum += row[column];
    }
    mean[column] = sum / n;
    var squares = 0.0;
    for (final row in matrix) {
      final d = row[column] - mean[column];
      squares += d * d;
    }
    // Desvio populacional, como o numpy.std padrão do lado Python.
    std[column] = math.sqrt(squares / n);
  }

  return ClassComparison(
    task: task,
    participantCodes: codes,
    zScores: [
      for (final row in matrix)
        [
          for (var column = 0; column < featureNames.length; column++)
            // Característica constante na turma: escore zero, não infinito.
            std[column] > 0 ? (row[column] - mean[column]) / std[column] : 0.0,
        ],
    ],
    classMean: mean,
    classStd: std,
  );
}
