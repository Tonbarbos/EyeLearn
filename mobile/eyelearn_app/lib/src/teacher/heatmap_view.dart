/// O mapa de calor de uma sessão: a tela do celular, as linhas do texto onde
/// estavam e, por cima, onde o olhar ficou.
///
/// Serve para ver de relance se a captura acompanhou a leitura (o calor
/// sobre as linhas, descendo) ou se se perdeu (calor fora do texto, num
/// canto, ou espalhado).
library;

import 'dart:math' as math;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import '../activity/passages.dart';
import '../ui/theme.dart';

class GazeHeatmapView extends StatelessWidget {
  final GazeHeatmap heatmap;
  final String task;

  /// Largura do desenho; a altura segue a proporção da tela.
  final double width;

  const GazeHeatmapView({
    super.key,
    required this.heatmap,
    required this.task,
    this.width = 220,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * heatmap.halfHeight / heatmap.halfWidth;
    final onText = heatmap.onTextFraction;
    List<String> lines;
    try {
      lines = passageById(task).lines;
    } on ArgumentError {
      lines = const [];
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const Key('heatmap'),
          width: width + 12,
          height: height + 12,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Palette.ink,
            borderRadius: BorderRadius.circular(22),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: CustomPaint(
              size: Size(width, height),
              painter: _HeatmapPainter(heatmap, lines),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          onText == null
              ? '${heatmap.total.toStringAsFixed(0)} s de olhar registrado'
              : '${(100 * onText).round()}% do tempo de olhar sobre o texto',
          style: AppType.body.copyWith(fontSize: 13.5, color: Palette.inkMuted),
        ),
      ],
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final GazeHeatmap map;
  final List<String> lines;

  _HeatmapPainter(this.map, this.lines);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = Palette.readingSurface);
    double px(double deg) =>
        (deg + map.halfWidth) / (2 * map.halfWidth) * size.width;
    double py(double deg) =>
        (deg + map.halfHeight) / (2 * map.halfHeight) * size.height;

    // As linhas do texto, como barras cinzentas no lugar em que estavam.
    final area = map.textArea;
    if (area != null && lines.isNotEmpty) {
      final rect =
          Rect.fromLTRB(px(area[0]), py(area[1]), px(area[2]), py(area[3]));
      final step = rect.height / lines.length;
      final longest = lines.map((l) => l.length).reduce(math.max);
      for (var i = 0; i < lines.length; i++) {
        final y = rect.top + step * (i + 0.5);
        final w = rect.width * lines[i].length / longest;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(rect.left, y - step * 0.18, w, step * 0.36),
            const Radius.circular(2),
          ),
          Paint()..color = const Color(0xFFD5D3E3),
        );
      }
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF9AA0BF),
      );
    }

    // O calor: cada célula com opacidade proporcional ao tempo.
    final peak = map.seconds.fold<double>(0, math.max);
    if (peak <= 0) return;
    final cw = size.width / map.columns;
    final ch = size.height / map.rows;
    for (var row = 0; row < map.rows; row++) {
      for (var col = 0; col < map.columns; col++) {
        final v = map.seconds[row * map.columns + col] / peak;
        if (v <= 0) continue;
        final colour =
            Color.lerp(const Color(0xFFFFC94D), const Color(0xFFE5482F), v)!;
        canvas.drawRect(
          Rect.fromLTWH(col * cw, row * ch, cw, ch),
          Paint()
            ..color = colour.withValues(alpha: 0.15 + 0.6 * math.sqrt(v))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) => old.map != map;
}
