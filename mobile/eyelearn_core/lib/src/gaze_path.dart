/// O percurso do olhar, reduzido, para o painel reproduzir a leitura.
///
/// O mapa de calor ([GazeHeatmap]) só soma tempo por região, sem ordem. Para
/// o professor ver o olhar *andando* pelo texto (um time-lapse da bolinha),
/// é preciso o percurso. Vai reduzido: no máximo 15 amostras por segundo,
/// posição arredondada a 0,1 grau e tempo a 0,01 s -- o bastante para a
/// animação, pouco mais de 1 KB por 10 s de leitura.
///
/// O percurso mostra o ritmo da leitura da criança, e por isso só viaja na
/// sessão, que vai cifrada para a chave do professor (`delivery.dart`):
/// nem a caixa de entrega nem quem a lê consegue abri-lo.
library;

import 'trace.dart';

class GazePath {
  /// Instantes em segundos, a partir do começo da leitura.
  final List<double> t;

  /// Posição em graus; `null` onde a amostra foi perdida (piscada, rosto
  /// fora do quadro).
  final List<double?> x;
  final List<double?> y;

  GazePath({required this.t, required this.x, required this.y})
      : assert(t.length == x.length && t.length == y.length);

  /// Amostras por segundo, no máximo.
  static const double maxRateHz = 15;

  factory GazePath.fromTrace(GazeTrace trace, {double rateHz = maxRateHz}) {
    final t = <double>[], x = <double?>[], y = <double?>[];
    if (trace.t.isEmpty) return GazePath(t: t, x: x, y: y);
    final start = trace.t.first;
    final step = 1 / rateHz;
    var next = start;
    double round(double v, int places) {
      final f = places == 1 ? 10 : 100;
      return (v * f).round() / f;
    }

    for (var i = 0; i < trace.t.length; i++) {
      if (trace.t[i] + 1e-9 < next) continue;
      next = trace.t[i] + step;
      final ok = trace.x[i].isFinite && trace.y[i].isFinite;
      t.add(round(trace.t[i] - start, 2));
      x.add(ok ? round(trace.x[i], 1) : null);
      y.add(ok ? round(trace.y[i], 1) : null);
    }
    return GazePath(t: t, x: x, y: y);
  }

  factory GazePath.fromJson(Map<String, dynamic> json) => GazePath(
        t: [for (final v in json['t'] as List) (v as num).toDouble()],
        x: [for (final v in json['x'] as List) (v as num?)?.toDouble()],
        y: [for (final v in json['y'] as List) (v as num?)?.toDouble()],
      );

  Map<String, dynamic> toJson() => {'t': t, 'x': x, 'y': y};

  double get duration => t.isEmpty ? 0 : t.last;

  bool get isEmpty => t.isEmpty;

  /// Onde o olhar estava no instante [time]: a última amostra válida até
  /// ali, se for recente (até 0,3 s); `null` numa falha da captura.
  ({double x, double y})? at(double time) {
    final i = _indexAt(time);
    for (var j = i; j >= 0 && time - t[j] <= 0.3; j--) {
      final px = x[j], py = y[j];
      if (px != null && py != null) return (x: px, y: py);
    }
    return null;
  }

  /// As posições válidas entre [from] e [to], em ordem: o rastro.
  List<({double x, double y})> between(double from, double to) {
    final out = <({double x, double y})>[];
    for (var i = _indexAt(from); i >= 0 && i < t.length && t[i] <= to; i++) {
      final px = x[i], py = y[i];
      if (t[i] >= from && px != null && py != null) out.add((x: px, y: py));
    }
    return out;
  }

  /// Índice da última amostra com instante até [time] (0 se antes de todas).
  int _indexAt(double time) {
    if (t.isEmpty) return -1;
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
