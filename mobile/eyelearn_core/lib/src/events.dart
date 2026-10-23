/// Detecção de fixações e sacadas: porta de `eyelearn/signal/events.py`.
///
/// Só o I-VT está portado. O I-DT serve à comparação entre detectores, que é um
/// resultado do estudo e roda no computador; o aplicativo precisa de um
/// detector só, e o I-VT é o mais barato -- uma passada de velocidade, sem
/// janela que cresce e encolhe. Em um aparelho que também está decodificando
/// vídeo e localizando a íris a cada quadro, isso conta.
library;

import 'dart:math' as math;

import 'preprocess.dart' as preprocess;
import 'trace.dart';

/// Duração mínima aceita para uma fixação, em segundos.
///
/// Fixações de leitura em crianças ficam entre 150 e 400 ms; o piso de 60 ms
/// descarta agrupamentos espúrios sem cortar fixações curtas legítimas.
const double defaultMinFixationDuration = 0.06;

/// Limiar de velocidade do I-VT, em graus por segundo.
const double defaultVelocityThreshold = 30.0;

/// Intervalo máximo tolerado entre amostras consecutivas, em segundos.
const double defaultMaxGap = 0.075;

/// Natureza de uma sacada, segundo o sentido da leitura.
enum SaccadeKind {
  progressive('progressive'),
  regressive('regressive'),
  lineSweep('line_sweep');

  const SaccadeKind(this.wireName);

  /// Nome usado no JSON, igual ao do lado Python.
  final String wireName;
}

/// Período em que o olhar permanece parado sobre uma região.
class Fixation {
  /// Início, em segundos.
  final double tStart;

  /// Fim, em segundos.
  final double tEnd;

  /// Centroide horizontal, em graus.
  final double x;

  /// Centroide vertical, em graus.
  final double y;

  /// Quantidade de amostras que a compõem.
  final int nSamples;

  const Fixation({
    required this.tStart,
    required this.tEnd,
    required this.x,
    required this.y,
    required this.nSamples,
  });

  double get duration => tEnd - tStart;
}

/// Movimento rápido entre duas fixações consecutivas.
class Saccade {
  final double tStart;
  final double tEnd;

  /// Deslocamento horizontal, em graus. Positivo para a direita, o sentido da
  /// leitura.
  final double dx;

  /// Deslocamento vertical, em graus. Positivo para baixo.
  final double dy;

  /// Maior velocidade angular observada no trajeto, em graus por segundo.
  final double peakVelocity;

  final SaccadeKind kind;

  const Saccade({
    required this.tStart,
    required this.tEnd,
    required this.dx,
    required this.dy,
    required this.peakVelocity,
    required this.kind,
  });

  double get duration => tEnd - tStart;

  /// Distância euclidiana percorrida, em graus.
  double get amplitude => math.sqrt(dx * dx + dy * dy);
}

/// Detecta fixações por limiar de velocidade (I-VT).
///
/// Recebe um segmento de amostragem contínua. Buracos deixados por piscadas
/// devem ser separados antes; [detectEvents] faz isso.
List<Fixation> ivt(
  GazeTrace trace, {
  double velocityThreshold = defaultVelocityThreshold,
  double minFixationDuration = defaultMinFixationDuration,
}) {
  if (velocityThreshold <= 0) {
    throw ArgumentError('velocityThreshold deve ser positivo');
  }
  if (minFixationDuration < 0) {
    throw ArgumentError('minFixationDuration não pode ser negativo');
  }
  if (trace.length < 2) return const [];

  final v = preprocess.velocity(trace);
  final fixations = <Fixation>[];

  // Percorre uma posição além do fim para fechar uma corrida que termine na
  // última amostra.
  var start = -1;
  for (var i = 0; i <= trace.length; i++) {
    final slow = i < trace.length && v[i] <= velocityThreshold;
    if (slow) {
      if (start < 0) start = i;
      continue;
    }
    if (start >= 0) {
      final candidate = _fixationFromSlice(trace, start, i);
      if (candidate.duration >= minFixationDuration) fixations.add(candidate);
      start = -1;
    }
  }

  return fixations;
}

/// Deriva as sacadas dos intervalos entre fixações consecutivas.
///
/// As sacadas não são detectadas diretamente: o que sobra entre duas fixações
/// é, por definição, o movimento que levou de uma à outra. A velocidade de pico
/// é lida das amostras do intervalo; quando o intervalo não contém nenhuma
/// amostra, ela é estimada pela razão entre amplitude e duração.
List<Saccade> saccadesBetween(GazeTrace trace, List<Fixation> fixations) {
  if (fixations.length < 2) return const [];

  final v = preprocess.velocity(trace);
  final saccades = <Saccade>[];

  for (var i = 0; i < fixations.length - 1; i++) {
    final previous = fixations[i];
    final following = fixations[i + 1];

    final dx = following.x - previous.x;
    final dy = following.y - previous.y;
    final duration = following.tStart - previous.tEnd;

    double? peak;
    for (var j = 0; j < trace.length; j++) {
      final tj = trace.t[j];
      if (tj > previous.tEnd && tj < following.tStart) {
        if (peak == null || v[j] > peak) peak = v[j];
      }
    }
    peak ??= duration > 0 ? math.sqrt(dx * dx + dy * dy) / duration : 0.0;

    saccades.add(
      Saccade(
        tStart: previous.tEnd,
        tEnd: following.tStart,
        dx: dx,
        dy: dy,
        peakVelocity: peak,
        kind: classifySaccade(dx, dy),
      ),
    );
  }

  return saccades;
}

/// Classifica uma sacada segundo o sentido da leitura.
///
/// A distinção importa para a proporção de regressões, uma das características
/// mais discriminantes. O retorno de linha também é um movimento grande para a
/// esquerda, mas não é regressão: é o salto normal para o início da linha
/// seguinte, e contá-lo como regressão inflaria a medida em todo leitor,
/// apagando a diferença entre os grupos.
SaccadeKind classifySaccade(
  double dx,
  double dy, {
  double minRegressionAmplitude = 0.5,
  double lineSweepDescent = 0.75,
}) {
  if (dx < -minRegressionAmplitude) {
    if (dy > lineSweepDescent) return SaccadeKind.lineSweep;
    return SaccadeKind.regressive;
  }
  return SaccadeKind.progressive;
}

/// Detecta fixações e sacadas em um percurso, respeitando os buracos.
///
/// Nenhuma sacada é criada atravessando um buraco: o deslocamento observado ali
/// não corresponde a um movimento rastreado.
({List<Fixation> fixations, List<Saccade> saccades}) detectEvents(
  GazeTrace trace, {
  double maxGap = defaultMaxGap,
  double velocityThreshold = defaultVelocityThreshold,
  double minFixationDuration = defaultMinFixationDuration,
}) {
  final allFixations = <Fixation>[];
  final allSaccades = <Saccade>[];

  for (final segment in preprocess.splitOnGaps(trace, maxGap: maxGap)) {
    final fixations = ivt(
      segment,
      velocityThreshold: velocityThreshold,
      minFixationDuration: minFixationDuration,
    );
    allFixations.addAll(fixations);
    allSaccades.addAll(saccadesBetween(segment, fixations));
  }

  return (fixations: allFixations, saccades: allSaccades);
}

Fixation _fixationFromSlice(GazeTrace trace, int start, int stop) {
  var sumX = 0.0;
  var sumY = 0.0;
  for (var i = start; i < stop; i++) {
    sumX += trace.x[i];
    sumY += trace.y[i];
  }
  final count = stop - start;

  return Fixation(
    tStart: trace.t[start],
    tEnd: trace.t[stop - 1],
    x: sumX / count,
    y: sumY / count,
    nSamples: count,
  );
}
