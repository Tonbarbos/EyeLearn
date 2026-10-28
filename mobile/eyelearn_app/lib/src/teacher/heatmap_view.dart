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

/// Largura de cada linha do texto em fração da mais larga (as barras
/// cinzentas do desenho); vazia se a tarefa não existe mais.
List<double> passageLineFractions(String task) {
  try {
    final lines = passageById(task).lines;
    final longest = lines.map((l) => l.length).reduce(math.max);
    return [for (final l in lines) l.length / longest];
  } on ArgumentError {
    return const [];
  }
}

/// A tela de leitura vista de longe: fundo e linhas do texto onde estavam.
void _paintScreen(Canvas canvas, Size size, double halfWidth, double halfHeight,
    List<double>? area, List<double> fractions) {
  canvas.drawRect(Offset.zero & size, Paint()..color = Palette.readingSurface);
  if (area == null || fractions.isEmpty) return;
  double px(double deg) => (deg + halfWidth) / (2 * halfWidth) * size.width;
  double py(double deg) => (deg + halfHeight) / (2 * halfHeight) * size.height;
  final rect =
      Rect.fromLTRB(px(area[0]), py(area[1]), px(area[2]), py(area[3]));
  final step = rect.height / fractions.length;
  for (var i = 0; i < fractions.length; i++) {
    final y = rect.top + step * (i + 0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
            rect.left, y - step * 0.18, rect.width * fractions[i], step * 0.36),
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

class _HeatmapPainter extends CustomPainter {
  final GazeHeatmap map;
  final List<String> lines;

  _HeatmapPainter(this.map, this.lines);

  @override
  void paint(Canvas canvas, Size size) {
    final longest =
        lines.isEmpty ? 1 : lines.map((l) => l.length).reduce(math.max);
    _paintScreen(canvas, size, map.halfWidth, map.halfHeight, map.textArea,
        [for (final l in lines) l.length / longest]);

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

/// O time-lapse do olhar: a bolinha andando pela tela de leitura, mais
/// rápido que a leitura de verdade.
///
/// A criança nunca viu esta bolinha: durante a atividade ela não aparece
/// (quem vê o próprio olhar passa a persegui-lo). Aqui é só para o professor
/// entender o percurso.
class GazeReplayView extends StatefulWidget {
  final GazePath path;
  final GazeHeatmap? heatmap;
  final String task;
  final double width;

  /// Baixar o GIF; `null` esconde o botão.
  final void Function(double speed)? onSaveGif;

  const GazeReplayView({
    super.key,
    required this.path,
    required this.task,
    this.heatmap,
    this.width = 220,
    this.onSaveGif,
  });

  @override
  State<GazeReplayView> createState() => _GazeReplayViewState();
}

class _GazeReplayViewState extends State<GazeReplayView>
    with SingleTickerProviderStateMixin {
  static const speeds = [2.0, 4.0, 8.0];
  double _speed = 4;
  late final AnimationController _controller;
  late final List<double> _fractions = passageLineFractions(widget.task);

  double get _halfWidth => widget.heatmap?.halfWidth ?? 14;
  double get _halfHeight => widget.heatmap?.halfHeight ?? 24;

  Duration get _duration => Duration(
      milliseconds:
          math.max(1, (widget.path.duration / _speed * 1000).round()));

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration)
      ..addListener(() => setState(() {}))
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setSpeed(double speed) {
    final playing = _controller.isAnimating;
    setState(() => _speed = speed);
    _controller.duration = _duration;
    if (playing) _controller.forward();
  }

  void _toggle() {
    if (_controller.isAnimating) {
      _controller.stop();
    } else {
      if (_controller.value >= 1) _controller.value = 0;
      _controller.forward();
    }
    setState(() {});
  }

  static String _clock(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = width * _halfHeight / _halfWidth;
    final now = _controller.value * widget.path.duration;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const Key('gaze-replay'),
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
              painter: _ReplayPainter(
                path: widget.path,
                now: now,
                halfWidth: _halfWidth,
                halfHeight: _halfHeight,
                textArea: widget.heatmap?.textArea,
                fractions: _fractions,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: width + 12,
          child: Row(
            children: [
              IconButton(
                key: const Key('gaze-replay-play'),
                onPressed: _toggle,
                icon: Icon(_controller.isAnimating
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
              ),
              Expanded(
                child: Slider(
                  value: _controller.value,
                  onChanged: (v) {
                    _controller.stop();
                    _controller.value = v;
                  },
                ),
              ),
            ],
          ),
        ),
        Text(
          '${_clock(now)} de ${_clock(widget.path.duration)} de leitura',
          style: AppType.body.copyWith(fontSize: 13.5, color: Palette.inkMuted),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final s in speeds)
              ChoiceChip(
                label: Text('${s.round()}×'),
                selected: _speed == s,
                onSelected: (_) => _setSpeed(s),
              ),
          ],
        ),
        if (widget.onSaveGif != null) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            key: const Key('gaze-replay-gif'),
            onPressed: () => widget.onSaveGif!(_speed),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Baixar GIF'),
          ),
        ],
      ],
    );
  }
}

class _ReplayPainter extends CustomPainter {
  final GazePath path;
  final double now;
  final double halfWidth;
  final double halfHeight;
  final List<double>? textArea;
  final List<double> fractions;

  _ReplayPainter({
    required this.path,
    required this.now,
    required this.halfWidth,
    required this.halfHeight,
    required this.textArea,
    required this.fractions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintScreen(canvas, size, halfWidth, halfHeight, textArea, fractions);
    Offset place(({double x, double y}) p) => Offset(
          (p.x + halfWidth) / (2 * halfWidth) * size.width,
          (p.y + halfHeight) / (2 * halfHeight) * size.height,
        );
    // O rastro: o último segundo de leitura, mais forte perto do agora.
    final trail = path.between(now - 1.0, now);
    for (var i = 0; i < trail.length; i++) {
      final age = (i + 1) / trail.length;
      canvas.drawCircle(
        place(trail[i]),
        2 + 3 * age,
        Paint()..color = Palette.amber.withValues(alpha: 0.12 + 0.4 * age),
      );
    }
    final at = path.at(now);
    if (at == null) return;
    final c = place(at);
    canvas.drawCircle(c, 9, Paint()..color = Colors.white);
    canvas.drawCircle(c, 7, Paint()..color = Palette.amber);
  }

  @override
  bool shouldRepaint(_ReplayPainter old) => old.now != now || old.path != path;
}
