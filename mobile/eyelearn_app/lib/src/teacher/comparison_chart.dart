/// Onde a leitura de uma criança fica em relação à turma, por característica.
///
/// Porta do gráfico do painel Python (`eyelearn/panel/charts.py`): barras
/// horizontais a partir do zero, âmbar acima da turma e violeta abaixo, duas
/// tracejadas na faixa de ±1,5 desvio e contorno em quem passa dela -- o
/// contorno sobrevive à impressão em preto, a cor não.
library;

import 'dart:math' as math;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import '../ui/theme.dart';

const aboveClass = Color(0xFFC27A00);
const belowClass = Color(0xFF5B4BE8);
const _zeroLine = Color(0xFF9AA0BF);

class ComparisonChart extends StatelessWidget {
  /// Escore z por característica (nome interno).
  final Map<String, double> scores;
  final double threshold;

  /// Legenda sob o gráfico: a quem os desvios se referem.
  final String reference;

  /// A barra para neste valor; o número ao lado mostra o valor de verdade.
  /// Sem isso, um escore de +28 (sessão de câmera contra a base de
  /// laboratório) achata todas as outras barras até sumirem.
  final double maxAbs;

  const ComparisonChart({
    super.key,
    required this.scores,
    this.threshold = highlightThreshold,
    this.reference = 'à turma',
    this.maxAbs = 6,
  });

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final (name, label) in presentedFeatures)
        if (scores.containsKey(name)) (label, scores[name]!),
    ];
    return Semantics(
      label: [
        for (final (label, value) in rows)
          '$label: ${value.toStringAsFixed(1)} desvios, '
              '${describeDirection(value, threshold: threshold)}',
      ].join('; '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: rows.length * 44.0 + 8,
            child: CustomPaint(
              painter: _ChartPainter(rows, threshold, maxAbs),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'desvios em relação $reference · tracejado: faixa de ±'
            '${threshold.toStringAsFixed(1).replaceAll('.', ',')}',
            textAlign: TextAlign.center,
            style: AppType.body.copyWith(fontSize: 13, color: Palette.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<(String, double)> rows;
  final double threshold;
  final double maxAbs;

  _ChartPainter(this.rows, this.threshold, this.maxAbs);

  TextPainter _text(String text, TextStyle style, double maxWidth) =>
      TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: maxWidth);

  @override
  void paint(Canvas canvas, Size size) {
    final labelWidth = math.min(170.0, size.width * 0.34);
    // Folga dos dois lados das barras para o número, que não pode cortar.
    const numberRoom = 40.0;
    final left = labelWidth + 8 + numberRoom;
    final width = math.max(40.0, size.width - left - numberRoom);
    final limit = math.max(
      2.4,
      rows.fold<double>(0, (m, r) => math.max(m, math.min(r.$2.abs(), maxAbs))),
    );
    double x(double value) => left + (value + limit) / (2 * limit) * width;
    const rowHeight = 44.0;

    final dashed = Paint()
      ..color = Palette.line
      ..strokeWidth = 1.4;
    for (final edge in [-threshold, threshold]) {
      for (var y = 0.0; y < size.height; y += 8) {
        canvas.drawLine(Offset(x(edge), y), Offset(x(edge), y + 4), dashed);
      }
    }
    canvas.drawLine(
      Offset(x(0), 0),
      Offset(x(0), size.height),
      Paint()
        ..color = _zeroLine
        ..strokeWidth = 1.4,
    );

    for (var i = 0; i < rows.length; i++) {
      final (label, raw) = rows[i];
      final value = raw.clamp(-maxAbs, maxAbs);
      final clamped = value != raw;
      final centre = i * rowHeight + rowHeight / 2 + 4;
      final flagged = raw.abs() >= threshold;

      final name = _text(label,
          AppType.body.copyWith(fontSize: 14, color: Palette.ink), labelWidth);
      name.paint(canvas, Offset(0, centre - name.height / 2));

      if (value.abs() < 0.04 * limit) {
        canvas.drawCircle(
            Offset(x(0), centre), 4.5, Paint()..color = _zeroLine);
      } else {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTRB(math.min(x(0), x(value)), centre - 10,
              math.max(x(0), x(value)), centre + 10),
          const Radius.circular(6),
        );
        canvas.drawRRect(
            rect, Paint()..color = value >= 0 ? aboveClass : belowClass);
        if (flagged) {
          canvas.drawRRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = Palette.ink,
          );
        }
      }

      final number = _text(
        '${raw >= 0 ? '+' : '−'}'
                '${raw.abs().toStringAsFixed(clamped ? 0 : 1)}'
            .replaceAll('.', ','),
        AppType.body.copyWith(
          fontSize: 13,
          fontWeight: flagged ? FontWeight.w700 : FontWeight.w400,
          color: flagged ? Palette.ink : Palette.inkMuted,
        ),
        numberRoom + 4,
      );
      final nx = value >= 0 ? x(value) + 6 : x(value) - 6 - number.width;
      number.paint(canvas, Offset(nx, centre - number.height / 2));
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.rows != rows || old.threshold != threshold || old.maxAbs != maxAbs;
}
