/// Testar o olhar: uma bolinha mostra para onde o aparelho acha que a pessoa
/// está olhando.
///
/// Serve para conferir que o rastreamento funciona -- e para mostrá-lo
/// funcionando -- antes de uma atividade, ou numa apresentação. **Não grava
/// nada e não gera sessão.**
///
/// A bolinha não aparece na atividade de verdade, de propósito: quem vê o
/// próprio olhar na tela passa a persegui-lo, e o percurso gravado deixaria de
/// ser o da leitura.
library;

import 'dart:async';
import 'dart:collection';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import '../gaze/gaze_source.dart';
import 'calibration_screen.dart';
import 'theme.dart';

/// Posição de um olhar calibrado na tela, como fração de 0 a 1.
///
/// Inverso exato da conversão de [CalibrationScreen]: os mesmos graus por
/// meia tela, a mesma área (a tela inteira, dentro da área segura).
Offset gazeToFraction(double xDeg, double yDeg) => Offset(
      xDeg / (2 * CalibrationScreen.degreesPerHalfWidth) + 0.5,
      yDeg / (2 * CalibrationScreen.degreesPerHalfHeight) + 0.5,
    );

/// Pontos de referência numerados, para olhar um de cada vez e ver se a
/// bolinha chega perto.
const gazeReferences = [
  Offset(0.15, 0.22), Offset(0.5, 0.22), Offset(0.85, 0.22), //
  Offset(0.15, 0.5), Offset(0.5, 0.5), Offset(0.85, 0.5), //
  Offset(0.15, 0.78), Offset(0.5, 0.78), Offset(0.85, 0.78),
];

class GazeTestScreen extends StatefulWidget {
  /// Cria a origem do olhar; a tela liga e desliga.
  final GazeSource Function() gaze;

  /// Gancho da pré-visualização (olhar sintético), como na atividade.
  final void Function(GazeSource, CalibrationTarget)? onTargetShown;

  /// Gancho da pré-visualização: chamado quando a bolinha aparece, para o
  /// olhar sintético passear pelos números. Devolve como parar.
  final VoidCallback Function(GazeSource)? onViewing;

  const GazeTestScreen({
    super.key,
    required this.gaze,
    this.onTargetShown,
    this.onViewing,
  });

  @override
  State<GazeTestScreen> createState() => _GazeTestScreenState();
}

class _GazeTestScreenState extends State<GazeTestScreen> {
  late final GazeSource _source = widget.gaze();
  GazeCalibration? _calibration;

  /// Cada calibração nova recria a tela de calibração do zero.
  int _round = 0;

  @override
  void dispose() {
    _source.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calibration = _calibration;
    if (calibration == null) {
      return CalibrationScreen(
        key: ValueKey(_round),
        channel: _source,
        onTargetShown: widget.onTargetShown == null
            ? null
            : (target) => widget.onTargetShown!(_source, target),
        onCalibrated: (c) => setState(() => _calibration = c),
      );
    }
    return GazeViewer(
      source: _source,
      calibration: calibration,
      onViewing: widget.onViewing,
      onRecalibrate: () => setState(() {
        _calibration = null;
        _round++;
      }),
      onExit: () => Navigator.of(context).maybePop(),
    );
  }
}

/// A bolinha do olhar sobre a tela, com os números da captura.
class GazeViewer extends StatefulWidget {
  final GazeSource source;
  final GazeCalibration calibration;
  final VoidCallback onRecalibrate;
  final VoidCallback onExit;
  final VoidCallback Function(GazeSource)? onViewing;

  const GazeViewer({
    super.key,
    required this.source,
    required this.calibration,
    this.onViewing,
    required this.onRecalibrate,
    required this.onExit,
  });

  @override
  State<GazeViewer> createState() => _GazeViewerState();
}

class _GazeViewerState extends State<GazeViewer> {
  /// Suavização só da bolinha (média móvel exponencial). O olhar cru treme
  /// alguns graus de quadro a quadro; a bolinha crua seria ilegível. Nada
  /// aqui toca no que a atividade grava.
  static const double _smoothing = 0.35;
  static const int _trailLength = 14;

  StreamSubscription<FaceFrame>? _subscription;
  Offset? _dot;
  final _trail = ListQueue<Offset>();
  ({double x, double y})? _degrees;
  RejectionReason? _problem;

  /// Instantes dos últimos quadros (s), para a taxa.
  final _times = ListQueue<double>();
  int _frames = 0;
  int _valid = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.source.frames().listen(_onFrame);
    _stopDriving = widget.onViewing?.call(widget.source);
  }

  VoidCallback? _stopDriving;

  @override
  void dispose() {
    _stopDriving?.call();
    _subscription?.cancel();
    super.dispose();
  }

  void _onFrame(FaceFrame frame) {
    _times.addLast(frame.timestamp);
    while (_times.length > 1 && frame.timestamp - _times.first > 2.0) {
      _times.removeFirst();
    }
    _frames++;

    final offset = irisOffset(frame);
    final gaze = offset == null || offset.openness < minimumOpenness
        ? null
        : widget.calibration.apply(offset.x, offset.y);
    final usable = gaze != null && gaze.x.isFinite && gaze.y.isFinite;

    setState(() {
      _problem = offset == null
          ? RejectionReason.noFace
          : offset.openness < minimumOpenness
              ? RejectionReason.eyesClosed
              : usable
                  ? null
                  : RejectionReason.noFace;
      if (!usable) return;
      _valid++;
      _degrees = gaze;
      final target = gazeToFraction(gaze.x, gaze.y);
      final previous = _dot;
      final next = previous == null
          ? target
          : Offset.lerp(previous, target, _smoothing)!;
      _dot = next;
      _trail.addLast(next);
      while (_trail.length > _trailLength) {
        _trail.removeFirst();
      }
    });
  }

  double get _rate {
    if (_times.length < 2) return 0;
    final span = _times.last - _times.first;
    return span > 0 ? (_times.length - 1) / span : 0;
  }

  @override
  Widget build(BuildContext context) {
    final problem = switch (_problem) {
      RejectionReason.noFace => 'Rosto não encontrado',
      RejectionReason.eyesClosed => 'Olhos fechados',
      _ => null,
    };
    final degrees = _degrees;
    final hud = [
      '${_rate.toStringAsFixed(0)} quadros/s · olhar válido '
          '${_frames == 0 ? 0 : (100 * _valid / _frames).round()}% · '
          'calibração ±${widget.calibration.residualDegrees.toStringAsFixed(1)}°',
      if (degrees != null)
        'olhar em x ${degrees.x.toStringAsFixed(1)}° · '
            'y ${degrees.y.toStringAsFixed(1)}°',
    ].join('\n');

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Palette.nightTop, Palette.nightBottom],
          ),
        ),
        // A mesma área da calibração (tela inteira na área segura), para a
        // bolinha cair onde a calibração mediu.
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              Offset place(Offset f) =>
                  Offset(f.dx * size.width, f.dy * size.height);
              return Stack(
                children: [
                  for (var i = 0; i < gazeReferences.length; i++)
                    Positioned(
                      left: place(gazeReferences[i]).dx - 16,
                      top: place(gazeReferences[i]).dy - 16,
                      child: _Reference(number: i + 1),
                    ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GazePainter(
                        dot: _dot == null ? null : place(_dot!),
                        trail: [for (final f in _trail) place(f)],
                        dimmed: _problem != null,
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            problem ?? 'Olhe para os números, um de cada vez',
                            textAlign: TextAlign.center,
                            style: AppType.title.copyWith(
                              color: problem == null
                                  ? Colors.white
                                  : Palette.amber,
                              fontSize: 19,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            hud,
                            key: const Key('gaze-hud'),
                            textAlign: TextAlign.center,
                            style: AppType.body.copyWith(
                              color: Colors.white60,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Wrap(
                        spacing: 12,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: widget.onRecalibrate,
                            icon: const Icon(Icons.center_focus_strong_rounded),
                            label: const Text('Calibrar de novo'),
                          ),
                          FilledButton.icon(
                            onPressed: widget.onExit,
                            icon: const Icon(Icons.close_rounded),
                            label: const Text('Sair'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Reference extends StatelessWidget {
  final int number;
  const _Reference({required this.number});

  @override
  Widget build(BuildContext context) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1.5),
        ),
        child: Text(
          '$number',
          style: AppType.body.copyWith(color: Colors.white54, fontSize: 14),
        ),
      );
}

class _GazePainter extends CustomPainter {
  final Offset? dot;
  final List<Offset> trail;
  final bool dimmed;

  _GazePainter({required this.dot, required this.trail, required this.dimmed});

  @override
  void paint(Canvas canvas, Size size) {
    final current = dot;
    if (current == null) return;
    for (var i = 0; i < trail.length; i++) {
      final age = (i + 1) / trail.length;
      canvas.drawCircle(
        trail[i],
        4 + 6 * age,
        Paint()..color = Palette.amber.withValues(alpha: 0.12 * age),
      );
    }
    final opacity = dimmed ? 0.35 : 1.0;
    canvas.drawCircle(
      current,
      26,
      Paint()..color = Palette.amber.withValues(alpha: 0.25 * opacity),
    );
    canvas.drawCircle(
      current,
      11,
      Paint()..color = Palette.amber.withValues(alpha: opacity),
    );
    canvas.drawCircle(
      current,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.8 * opacity),
    );
  }

  @override
  bool shouldRepaint(_GazePainter old) =>
      old.dot != dot ||
      old.dimmed != dimmed ||
      old.trail.length != trail.length;
}
