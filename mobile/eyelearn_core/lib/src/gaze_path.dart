/// O percurso do olhar, reduzido, para o painel reproduzir a leitura.
///
/// O mapa de calor ([GazeHeatmap]) só soma tempo por região, sem ordem. Para
/// o professor ver o olhar *andando* pelo texto (um time-lapse da bolinha),
/// é preciso o percurso. Vai reduzido: no máximo 15 amostras por segundo,
/// posição arredondada a 0,1 grau e tempo a 0,01 s -- o bastante para a
/// animação, pouco mais de 1 KB por 10 s de leitura.
///
/// Diferente do percurso da análise ([GazeTrace]), este **guarda o olhar fora
/// da tela** (onde a análise põe `NaN`) e o motivo de cada amostra perdida:
/// olhar para fora do celular é justamente o que o time-lapse precisa mostrar,
/// e não pode se confundir com uma piscada.
///
/// O percurso mostra o ritmo da leitura da criança, e por isso só viaja na
/// sessão, que vai cifrada para a chave do professor (`delivery.dart`):
/// nem a caixa de entrega nem quem a lê consegue abri-lo.
library;

import 'dart:math' as math;

import 'trace.dart';

/// O que havia em cada amostra.
enum GazeSampleState {
  /// Olhar medido (dentro ou fora da tela: isso se vê pela posição).
  gaze,

  /// Olhos fechados ou piscando: não diz nada sobre a atenção.
  eyesClosed,

  /// Rosto fora da câmera.
  noFace,
}

class GazePath {
  /// Instantes em segundos, a partir do começo da leitura.
  final List<double> t;

  /// Posição em graus, a partir do centro da tela; `null` quando não há
  /// olhar medido. Pode passar da borda da tela: é o olhar fora dela.
  final List<double?> x;
  final List<double?> y;

  final List<GazeSampleState> state;

  GazePath({
    required this.t,
    required this.x,
    required this.y,
    List<GazeSampleState>? state,
  }) : state = state ??
            [
              for (var i = 0; i < t.length; i++)
                x[i] != null && y[i] != null
                    ? GazeSampleState.gaze
                    : GazeSampleState.eyesClosed,
            ] {
    assert(t.length == x.length &&
        t.length == y.length &&
        t.length == this.state.length);
  }

  /// Amostras por segundo, no máximo.
  static const double maxRateHz = 15;

  /// Até onde o olhar fora da tela é guardado, em graus: além disso a
  /// estimativa já não vale nada, só a direção.
  static const double maxDegrees = 60;

  /// Reduz amostras a [rateHz], com os arredondamentos do cabeçalho.
  factory GazePath.sample({
    required List<double> t,
    required List<double> x,
    required List<double> y,
    required List<GazeSampleState> state,
    double rateHz = maxRateHz,
  }) {
    final ot = <double>[], ox = <double?>[], oy = <double?>[];
    final os = <GazeSampleState>[];
    if (t.isEmpty) return GazePath(t: ot, x: ox, y: oy, state: os);
    final start = t.first;
    final step = 1 / rateHz;
    var next = start;
    double round(double v, int f) => (v * f).round() / f;
    double clamp(double v) => v.clamp(-maxDegrees, maxDegrees).toDouble();

    for (var i = 0; i < t.length; i++) {
      if (t[i] + 1e-9 < next) continue;
      next = t[i] + step;
      final ok =
          state[i] == GazeSampleState.gaze && x[i].isFinite && y[i].isFinite;
      ot.add(round(t[i] - start, 100));
      ox.add(ok ? round(clamp(x[i]), 10) : null);
      oy.add(ok ? round(clamp(y[i]), 10) : null);
      os.add(ok
          ? GazeSampleState.gaze
          : state[i] == GazeSampleState.gaze
              ? GazeSampleState.noFace
              : state[i]);
    }
    return GazePath(t: ot, x: ox, y: oy, state: os);
  }

  /// A partir do percurso da análise, que não distingue os motivos de perda
  /// nem guarda o olhar fora dos limites; o gravador usa [GazePath.sample].
  factory GazePath.fromTrace(GazeTrace trace, {double rateHz = maxRateHz}) =>
      GazePath.sample(
        t: trace.t,
        x: trace.x,
        y: trace.y,
        state: [
          for (var i = 0; i < trace.t.length; i++)
            trace.x[i].isFinite && trace.y[i].isFinite
                ? GazeSampleState.gaze
                : GazeSampleState.eyesClosed,
        ],
        rateHz: rateHz,
      );

  /// Sessões sem `s` (anteriores à distinção) leem as perdas como piscada:
  /// o neutro, que não acusa nada.
  factory GazePath.fromJson(Map<String, dynamic> json) {
    final x = [for (final v in json['x'] as List) (v as num?)?.toDouble()];
    final y = [for (final v in json['y'] as List) (v as num?)?.toDouble()];
    final codes = json['s'] as List?;
    return GazePath(
      t: [for (final v in json['t'] as List) (v as num).toDouble()],
      x: x,
      y: y,
      state: codes == null
          ? null
          : [
              for (final c in codes)
                GazeSampleState.values[(c as num)
                    .toInt()
                    .clamp(0, GazeSampleState.values.length - 1)]
            ],
    );
  }

  Map<String, dynamic> toJson() => {
        't': t,
        'x': x,
        'y': y,
        's': [for (final s in state) s.index],
      };

  double get duration => t.isEmpty ? 0 : t.last;

  bool get isEmpty => t.isEmpty;

  /// A amostra vigente no instante [time] (a última até ali, se for de até
  /// 0,3 s atrás); `null` se não houver.
  ({double? x, double? y, GazeSampleState state})? sampleAt(double time) {
    final i = _indexAt(time);
    if (i < 0 || time - t[i] > 0.3) return null;
    return (x: x[i], y: y[i], state: state[i]);
  }

  /// Onde o olhar estava no instante [time]; `null` se não havia olhar
  /// medido.
  ({double x, double y})? at(double time) {
    final s = sampleAt(time);
    final px = s?.x, py = s?.y;
    return px == null || py == null ? null : (x: px, y: py);
  }

  /// As posições medidas entre [from] e [to], em ordem: o rastro.
  List<({double x, double y})> between(double from, double to) {
    final out = <({double x, double y})>[];
    final first = math.max(0, _indexAt(from));
    for (var i = first; i < t.length && t[i] <= to; i++) {
      final px = x[i], py = y[i];
      if (t[i] >= from && px != null && py != null) out.add((x: px, y: py));
    }
    return out;
  }

  /// Fração do tempo com o olhar medido fora da tela (meia-largura e
  /// meia-altura em graus), entre o tempo com o rosto na câmera.
  double offScreenFraction(double halfWidth, double halfHeight) {
    var off = 0.0, total = 0.0;
    for (var i = 0; i < t.length - 1; i++) {
      if (state[i] == GazeSampleState.noFace) continue;
      final dt = math.min(t[i + 1] - t[i], 0.2);
      total += dt;
      final px = x[i], py = y[i];
      if (px != null &&
          py != null &&
          (px.abs() > halfWidth || py.abs() > halfHeight)) {
        off += dt;
      }
    }
    return total == 0 ? 0 : off / total;
  }

  /// Índice da última amostra com instante até [time]; -1 se antes de todas.
  int _indexAt(double time) {
    if (t.isEmpty || time < t.first) return -1;
    var lo = 0, hi = t.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (t[mid] <= time) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}
