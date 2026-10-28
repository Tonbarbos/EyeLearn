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
import '../ui/reading_screen.dart';
import '../ui/theme.dart';

class GazeHeatmapView extends StatelessWidget {
  final GazeHeatmap heatmap;
  final String task;

  /// Largura do desenho; a altura segue a proporção da tela.
  final double width;

  /// O percurso, quando há: dá o tempo com o olhar fora da tela, que o mapa
  /// (só a tela) não mostra.
  final GazePath? path;

  const GazeHeatmapView({
    super.key,
    required this.heatmap,
    required this.task,
    this.width = 220,
    this.path,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * heatmap.halfHeight / heatmap.halfWidth;
    final onText = heatmap.onTextFraction;
    final passage = sessionPassage(task);
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
              painter: _HeatmapPainter(heatmap, passage),
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
        if (path case final p? when !p.isEmpty)
          Text(
            '${(100 * p.offScreenFraction(heatmap.halfWidth, heatmap.halfHeight)).round()}% '
            'do tempo olhando fora da tela',
            key: const Key('off-screen-share'),
            style:
                AppType.body.copyWith(fontSize: 13.5, color: Palette.inkMuted),
          ),
      ],
    );
  }
}

/// A tarefa da sessão, ou `null` se ela não existe mais no aplicativo.
Passage? sessionPassage(String task) {
  try {
    return passageById(task);
  } on ArgumentError {
    return null;
  }
}

/// O retângulo do texto, em pixels do desenho.
Rect? _textRect(
    Size size, double halfWidth, double halfHeight, List<double>? area) {
  if (area == null) return null;
  double px(double deg) => (deg + halfWidth) / (2 * halfWidth) * size.width;
  double py(double deg) => (deg + halfHeight) / (2 * halfHeight) * size.height;
  return Rect.fromLTRB(px(area[0]), py(area[1]), px(area[2]), py(area[3]));
}

/// A tela de leitura vista de longe: o fundo e a moldura de onde o texto
/// estava.
void paintScreenBackground(Canvas canvas, Size size, double halfWidth,
    double halfHeight, List<double>? area) {
  canvas.drawRect(Offset.zero & size, Paint()..color = Palette.readingSurface);
  final rect = _textRect(size, halfWidth, halfHeight, area);
  if (rect == null) return;
  canvas.drawRect(
    rect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF9AA0BF),
  );
}

/// O texto da tarefa onde ele estava na tela, linha a linha.
///
/// Desde que a leitura passou a medir o bloco justo em volta das linhas
/// (`ReadingScreenBody.linesKey`), cada linha ocupa uma faixa igual dele e a
/// mais larga ocupa a largura toda: a fonte é escalada para isso, com o
/// mesmo estilo da leitura. Em sessões mais antigas o retângulo era a área
/// inteira do texto, e as linhas saem espalhadas na altura.
void paintPassageText(Canvas canvas, Size size, double halfWidth,
    double halfHeight, List<double>? area, Passage? passage,
    {Color colour = const Color(0xFF4A4F6A)}) {
  final rect = _textRect(size, halfWidth, halfHeight, area);
  if (rect == null || passage == null || passage.lines.isEmpty) return;
  final widest = ReadingScreenBody.widestLine(passage);
  if (widest <= 0) return;
  final style = ReadingScreenBody.lineStyle.copyWith(
    fontSize: ReadingScreenBody.lineStyle.fontSize! * rect.width / widest,
    height: 1,
    color: colour,
  );
  final step = rect.height / passage.lines.length;
  for (var i = 0; i < passage.lines.length; i++) {
    final painter = TextPainter(
      text: TextSpan(text: passage.lines[i], style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(
      canvas,
      Offset(rect.left, rect.top + step * (i + 0.5) - painter.height / 2),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final GazeHeatmap map;
  final Passage? passage;

  _HeatmapPainter(this.map, this.passage);

  @override
  void paint(Canvas canvas, Size size) {
    paintScreenBackground(
        canvas, size, map.halfWidth, map.halfHeight, map.textArea);
    _paintHeat(canvas, size);
    // O texto por cima do calor, para ler onde o olhar se demorou.
    paintPassageText(
        canvas, size, map.halfWidth, map.halfHeight, map.textArea, passage,
        colour: Palette.ink.withValues(alpha: 0.85));
  }

  void _paintHeat(Canvas canvas, Size size) {
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
  final Future<void> Function(double speed)? onSaveGif;

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
  late final Passage? _passage = sessionPassage(widget.task);

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

  bool _makingGif = false;

  Future<void> _saveGif() async {
    setState(() => _makingGif = true);
    try {
      await widget.onSaveGif!(_speed);
    } finally {
      if (mounted) setState(() => _makingGif = false);
    }
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
                passage: _passage,
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
            onPressed: _makingGif ? null : _saveGif,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(_makingGif ? 'Gerando o GIF…' : 'Baixar GIF'),
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
  final Passage? passage;

  _ReplayPainter({
    required this.path,
    required this.now,
    required this.halfWidth,
    required this.halfHeight,
    required this.textArea,
    required this.passage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    paintScreenBackground(canvas, size, halfWidth, halfHeight, textArea);
    paintPassageText(canvas, size, halfWidth, halfHeight, textArea, passage);
    Offset place(({double x, double y}) p) => Offset(
          (p.x + halfWidth) / (2 * halfWidth) * size.width,
          (p.y + halfHeight) / (2 * halfHeight) * size.height,
        );
    bool inside(({double x, double y}) p) =>
        p.x.abs() <= halfWidth && p.y.abs() <= halfHeight;
    final sample = path.sampleAt(now);

    if (sample?.state == GazeSampleState.noFace) {
      // Rosto fora da câmera: a tela apaga.
      canvas.drawRect(Offset.zero & size,
          Paint()..color = const Color(0xFF8A8FA8).withValues(alpha: 0.55));
      _label(canvas, size, 'rosto fora da câmera', Palette.ink);
      return;
    }
    final at = path.at(now);
    final away = at != null && !inside(at);
    if (away) {
      canvas.drawRect(Offset.zero & size,
          Paint()..color = Palette.ink.withValues(alpha: 0.14));
    }

    // O rastro: o último segundo de leitura, mais forte perto do agora. Só o
    // que caiu na tela; o olhar fora dela aparece na borda.
    final trail = path.between(now - 1.0, now).where(inside).toList();
    for (var i = 0; i < trail.length; i++) {
      final age = (i + 1) / trail.length;
      canvas.drawCircle(
        place(trail[i]),
        2 + 3 * age,
        Paint()..color = Palette.amber.withValues(alpha: 0.12 + 0.4 * age),
      );
    }
    if (at == null) return;
    if (!away) {
      final c = place(at);
      canvas.drawCircle(c, 9, Paint()..color = Colors.white);
      canvas.drawCircle(c, 7, Paint()..color = Palette.amber);
      return;
    }

    // Olhar fora da tela: bolinha vermelha presa na borda, com uma seta
    // apontando para onde o olhar foi.
    final target = place(at);
    const inset = 24.0;
    final c = Offset(
      target.dx.clamp(inset, size.width - inset).toDouble(),
      target.dy.clamp(inset, size.height - inset).toDouble(),
    );
    final direction = target - c;
    final unit = direction.distance == 0
        ? const Offset(0, -1)
        : direction / direction.distance;
    final normal = Offset(-unit.dy, unit.dx);
    final tip = c + unit * 15;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((c + unit * 8 + normal * 5).dx, (c + unit * 8 + normal * 5).dy)
        ..lineTo((c + unit * 8 - normal * 5).dx, (c + unit * 8 - normal * 5).dy)
        ..close(),
      Paint()..color = Palette.coral,
    );
    canvas.drawCircle(c, 9, Paint()..color = Colors.white);
    canvas.drawCircle(c, 7, Paint()..color = Palette.coral);
    _label(canvas, size, 'olhando fora da tela', Palette.coral);
  }

  static void _label(Canvas canvas, Size size, String text, Color colour) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: AppType.label.copyWith(fontSize: 12, color: colour),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    final box = Rect.fromCenter(
      center: Offset(size.width / 2, size.height - 22),
      width: painter.width + 16,
      height: painter.height + 8,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(10)),
        Paint()..color = Colors.white.withValues(alpha: 0.92));
    painter.paint(canvas, box.topLeft + const Offset(8, 4));
  }

  @override
  bool shouldRepaint(_ReplayPainter old) => old.now != now || old.path != path;
}
