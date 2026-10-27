/// Mapa de calor do olhar: quanto tempo o olhar ficou em cada região da tela.
///
/// Vai na sessão em vez do percurso. O percurso amostra a amostra
/// reconstituiria o ritmo de leitura da criança em detalhe; a grade é
/// grossa (12 x 16 células na tela inteira, cada uma com uns 2 a 3 graus) e
/// só soma tempo, sem ordem. Basta para o professor ver se o olhar ficou no
/// texto, em que linhas se demorou, ou se a captura se perdeu fora da tela --
/// que é o uso de depuração mais imediato.
///
/// Junto vai o retângulo do texto, em graus, para o painel desenhar as linhas
/// sob o mapa.
library;

import 'dart:math' as math;

import 'trace.dart';

class GazeHeatmap {
  final int columns;
  final int rows;

  /// Extensão da grade em graus, a partir do centro da tela.
  final double halfWidth;
  final double halfHeight;

  /// Segundos de olhar em cada célula, linha a linha (de cima para baixo).
  final List<double> seconds;

  /// Retângulo do texto em graus: esquerda, topo, direita, base.
  final List<double>? textArea;

  const GazeHeatmap({
    required this.columns,
    required this.rows,
    required this.halfWidth,
    required this.halfHeight,
    required this.seconds,
    this.textArea,
  });

  /// Soma o tempo de cada amostra válida na célula em que ela cai.
  ///
  /// Cada amostra vale o intervalo até a seguinte (limitado a 0,2 s, para
  /// que um buraco na captura não pinte uma célula inteira). Amostras fora
  /// da tela ficam fora.
  factory GazeHeatmap.fromTrace(
    GazeTrace trace, {
    int columns = 12,
    int rows = 16,
    double halfWidth = 14,
    double halfHeight = 24,
    List<double>? textArea,
  }) {
    final cells = List<double>.filled(columns * rows, 0);
    for (var i = 0; i < trace.t.length - 1; i++) {
      final x = trace.x[i];
      final y = trace.y[i];
      if (!x.isFinite || !y.isFinite) continue;
      final col = ((x + halfWidth) / (2 * halfWidth) * columns).floor();
      final row = ((y + halfHeight) / (2 * halfHeight) * rows).floor();
      if (col < 0 || col >= columns || row < 0 || row >= rows) continue;
      cells[row * columns + col] += math.min(trace.t[i + 1] - trace.t[i], 0.2);
    }
    return GazeHeatmap(
      columns: columns,
      rows: rows,
      halfWidth: halfWidth,
      halfHeight: halfHeight,
      seconds: [for (final c in cells) (c * 100).round() / 100],
      textArea: textArea,
    );
  }

  factory GazeHeatmap.fromJson(Map<String, dynamic> json) => GazeHeatmap(
        columns: json['columns'] as int,
        rows: json['rows'] as int,
        halfWidth: (json['half_width_deg'] as num).toDouble(),
        halfHeight: (json['half_height_deg'] as num).toDouble(),
        seconds: [
          for (final v in json['seconds'] as List) (v as num).toDouble(),
        ],
        textArea: (json['text_area_deg'] as List?)
            ?.map((v) => (v as num).toDouble())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'columns': columns,
        'rows': rows,
        'half_width_deg': halfWidth,
        'half_height_deg': halfHeight,
        'seconds': seconds,
        if (textArea != null) 'text_area_deg': textArea,
      };

  double get total => seconds.fold(0, (a, b) => a + b);

  /// Fração do tempo que caiu dentro do retângulo do texto; `null` sem ele.
  double? get onTextFraction {
    final area = textArea;
    if (area == null || total == 0) return null;
    var inside = 0.0;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final cx = -halfWidth + (col + 0.5) * 2 * halfWidth / columns;
        final cy = -halfHeight + (row + 0.5) * 2 * halfHeight / rows;
        if (cx >= area[0] && cx <= area[2] && cy >= area[1] && cy <= area[3]) {
          inside += seconds[row * columns + col];
        }
      }
    }
    return inside / total;
  }
}
