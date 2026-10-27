/// Tela de calibração: a criança olha para cada bolinha até ela encher.
///
/// A bolinha enche com o tempo, enquanto o rosto está no quadro, depois de
/// meio segundo para o olho chegar até ela; a medida é a mediana do que foi
/// colhido. Desde a primeira bolinha aparece um cursor onde o aparelho acha
/// que a criança está olhando. A regra, e por que ela não exige mais o olhar
/// parado, está em `DwellCalibrator` (núcleo), testada sem tela.
///
/// Nove alvos: o centro primeiro (dá o ponto de partida do cursor) e depois a
/// volta pela tela. Mais alvos e medida mais longa por alvo são o que tira o
/// erro do mapa; o linear de `GazeCalibration` não precisa de mais termos.
library;

import 'dart:async';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

import '../gaze/gaze_source.dart';

/// Alvos em coordenadas de fração da tela, e em graus de ângulo visual.
///
/// Os graus assumem a geometria de [CalibrationScreen.degreesPerHalfWidth] e
/// [degreesPerHalfHeight], estimadas da tela do aparelho e de uma distância de
/// leitura típica. A estimativa entra como escala do mapa; o que a calibração
/// corrige é o resto.
class CalibrationTarget {
  /// Posição na tela, de 0 a 1 em cada eixo.
  final double fractionX;
  final double fractionY;

  const CalibrationTarget(this.fractionX, this.fractionY);
}

/// Os nove alvos, na ordem: centro e depois a volta pela tela.
const List<CalibrationTarget> calibrationTargets = [
  CalibrationTarget(0.5, 0.5),
  CalibrationTarget(0.12, 0.15),
  CalibrationTarget(0.5, 0.15),
  CalibrationTarget(0.88, 0.15),
  CalibrationTarget(0.88, 0.5),
  CalibrationTarget(0.88, 0.85),
  CalibrationTarget(0.5, 0.85),
  CalibrationTarget(0.12, 0.85),
  CalibrationTarget(0.12, 0.5),
];

class CalibrationScreen extends StatefulWidget {
  /// Meia-largura da tela em graus de ângulo visual.
  static const double degreesPerHalfWidth = 14.0;

  /// Meia-altura da tela em graus.
  static const double degreesPerHalfHeight = 24.0;

  final GazeSource channel;

  /// Chamada com a calibração ajustada, quando ela é aceitável.
  final void Function(GazeCalibration) onCalibrated;

  /// Chamada a cada alvo apresentado.
  ///
  /// Existe para que uma origem de olhar que não seja a câmera saiba para onde
  /// a criança deveria estar olhando: é o que fecha o laço na
  /// pré-visualização de `main_demo.dart`. No aplicativo instalado fica nula --
  /// a criança olha para o alvo porque o vê, não porque alguém avisou.
  final void Function(CalibrationTarget)? onTargetShown;

  const CalibrationScreen({
    super.key,
    required this.channel,
    required this.onCalibrated,
    this.onTargetShown,
  });

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  StreamSubscription<FaceFrame>? _subscription;
  late final DwellCalibrator _calibrator = DwellCalibrator(
    targets: [
      for (final t in calibrationTargets)
        (x: _degreesX(t.fractionX), y: _degreesY(t.fractionY)),
    ],
  );

  /// Cursor suavizado, em fração da tela; só para desenhar.
  Offset? _cursor;
  String? _message;
  bool _failed = false;

  static double _degreesX(double f) =>
      (f - 0.5) * 2 * CalibrationScreen.degreesPerHalfWidth;
  static double _degreesY(double f) =>
      (f - 0.5) * 2 * CalibrationScreen.degreesPerHalfHeight;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      await widget.channel.start();
    } on GazeCaptureError catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
      return;
    }
    if (!mounted) return;
    _calibrator.reset();
    widget.onTargetShown?.call(calibrationTargets[0]);
    _subscription = widget.channel.frames().listen(_onFrame);
  }

  void _onFrame(FaceFrame frame) {
    final event = _calibrator.add(frame);
    final cursor = _calibrator.cursor;
    setState(() {
      if (cursor == null) {
        _cursor = null;
      } else {
        final target = Offset(
          cursor.x / (2 * CalibrationScreen.degreesPerHalfWidth) + 0.5,
          cursor.y / (2 * CalibrationScreen.degreesPerHalfHeight) + 0.5,
        );
        _cursor = _cursor == null ? target : Offset.lerp(_cursor, target, 0.35);
      }
      if (event == DwellEvent.targetConfirmed) _message = null;
    });
    switch (event) {
      case DwellEvent.targetConfirmed:
        widget.onTargetShown?.call(calibrationTargets[_calibrator.index]);
      case DwellEvent.finished:
        _finish();
      case DwellEvent.none:
        break;
    }
  }

  void _restart(String message) {
    setState(() {
      _message = message;
      _cursor = null;
    });
    _calibrator.reset();
    widget.onTargetShown?.call(calibrationTargets[0]);
  }

  void _finish() {
    try {
      final calibration = _calibrator.fit();
      if (!calibration.isAcceptable()) {
        _restart('Ficou meio torto. Vamos fazer de novo, bem devagar.');
        return;
      }
      _subscription?.cancel();
      _subscription = null;
      widget.onCalibrated(calibration);
    } on CalibrationError {
      _restart('Não deu certo. Vamos tentar outra vez!');
    }
  }

  String get _hint => switch (_calibrator.status) {
        DwellStatus.filling => 'Isso! Continue olhando…',
        DwellStatus.settling => 'Olhe para a bolinha amarela',
        DwellStatus.noFace => 'Não estou vendo seu rosto',
        DwellStatus.eyesClosed => 'Olhos bem abertos!',
      };

  @override
  Widget build(BuildContext context) {
    final done = _calibrator.done;
    final target = calibrationTargets[
        done ? calibrationTargets.length - 1 : _calibrator.index];
    final cursor = _cursor;

    return Scaffold(
      // Fundo escuro em gradiente: o alvo precisa de contraste máximo.
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Palette.nightTop, Palette.nightBottom],
          ),
        ),
        child: SafeArea(
          // O LayoutBuilder envolve o Stack, e não o contrário: um Positioned
          // devolvido de dentro do builder teria o LayoutBuilder como pai, não
          // o Stack, e o Flutter lançaria "Incorrect use of ParentDataWidget".
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
                    child: Column(
                      children: [
                        Text(
                          _message ?? _hint,
                          key: const Key('calibration-hint'),
                          textAlign: TextAlign.center,
                          style: AppType.title.copyWith(
                            color: Colors.white,
                            fontSize: 21,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _failed
                              ? ''
                              : 'Olhe para a bolinha até ela encher. '
                                  'Deixe a cabeça parada.',
                          textAlign: TextAlign.center,
                          style: AppType.body.copyWith(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!_failed)
                  Positioned(
                    left: target.fractionX * constraints.maxWidth - 40,
                    top: target.fractionY * constraints.maxHeight - 40,
                    child: _TargetDot(
                      progress: _calibrator.progress,
                      filling: _calibrator.status == DwellStatus.filling,
                    ),
                  ),
                if (cursor != null && !_failed)
                  Positioned(
                    left: cursor.dx * constraints.maxWidth - 9,
                    top: cursor.dy * constraints.maxHeight - 9,
                    child: const IgnorePointer(child: _Cursor()),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 28),
                    child: StepDots(
                      count: calibrationTargets.length,
                      current: done
                          ? calibrationTargets.length - 1
                          : _calibrator.index,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// O alvo: um anel que enche conforme o olhar fica nele.
class _TargetDot extends StatelessWidget {
  final double progress;
  final bool filling;

  const _TargetDot({required this.progress, required this.filling});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 80,
        height: 80,
        child: CustomPaint(
          painter: _RingPainter(progress: progress, filling: filling),
        ),
      );
}

class _RingPainter extends CustomPainter {
  final double progress;
  final bool filling;

  _RingPainter({required this.progress, required this.filling});

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    // Halo, mais forte enquanto enche.
    canvas.drawCircle(
      centre,
      34,
      Paint()..color = Palette.amber.withValues(alpha: filling ? 0.22 : 0.12),
    );
    // Trilho do anel.
    canvas.drawCircle(
      centre,
      26,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = Colors.white.withValues(alpha: 0.18),
    );
    // O quanto já encheu.
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: 26),
      -1.5708,
      progress * 6.2832,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..color = Palette.amber,
    );
    // Miolo, que cresce junto: é para onde o olho deve ir.
    canvas.drawCircle(
      centre,
      7 + 12 * progress,
      Paint()..color = Palette.amber,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.filling != filling;
}

/// Onde o aparelho acha que a criança está olhando, pelo mapa provisório.
class _Cursor extends StatelessWidget {
  const _Cursor();

  @override
  Widget build(BuildContext context) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.35),
          border: Border.all(color: Colors.white, width: 2),
        ),
      );
}
