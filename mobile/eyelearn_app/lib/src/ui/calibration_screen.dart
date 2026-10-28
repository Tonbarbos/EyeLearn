/// Tela de calibração: a criança olha para cada bolinha até ela mudar de lugar.
///
/// A bolinha fica parada por um tempo fixo, enquanto o rosto está no quadro:
/// meio segundo para o olho chegar até ela e depois a coleta; a medida é a
/// mediana do que foi colhido. A tela não mostra progresso nem cursor (ver
/// [_TargetDot]). A regra, e por que ela não exige o olhar parado, está em
/// `DwellCalibrator` (núcleo), testada sem tela.
///
/// Nove alvos: o centro primeiro (dá o ponto de partida do cursor) e depois a
/// volta pela tela. Mais alvos e medida mais longa por alvo são o que tira o
/// erro do mapa; o linear de `GazeCalibration` não precisa de mais termos.
library;

import 'dart:async';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

import 'positioning_screen.dart';
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

  /// Chamada junto com [onCalibrated], com a posição em que a calibração
  /// foi feita (`null` se a captura não deu para medir), para a leitura
  /// saber quando sair dela.
  final void Function(PostureReference?)? onPostureReference;

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
    this.onPostureReference,
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

  String? _message;

  /// Posições dos quadros medidos, para a referência da leitura.
  final List<Posture> _postures = [];

  /// Quadros seguidos com a posição ruim, e o problema do último.
  int _badFrames = 0;
  PositionIssue? _positionIssue;
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
    // Com o rosto fora da posição, a medida não vale: a calibração espera.
    // Alguns quadros seguidos, para um tremor no limite não travar tudo.
    final blocking = [
      for (final issue in assessPosition(frame))
        if (blockingIssues.contains(issue)) issue
    ];
    _badFrames = blocking.isEmpty ? 0 : _badFrames + 1;
    if (_badFrames >= 5 && blocking.first != PositionIssue.noFace) {
      setState(() => _positionIssue = blocking.first);
      return;
    }
    final event = _calibrator.add(frame);
    if (_calibrator.status == DwellStatus.filling) {
      final posture = Posture.of(frame);
      if (posture != null) _postures.add(posture);
    }
    setState(() {
      _positionIssue = null;
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
    setState(() => _message = message);
    _postures.clear();
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
      widget.onPostureReference?.call(PostureReference.fromPostures(_postures));
      widget.onCalibrated(calibration);
    } on CalibrationError {
      _restart('Não deu certo. Vamos tentar outra vez!');
    }
  }

  String get _hint => switch (_calibrator.status) {
        DwellStatus.filling ||
        DwellStatus.settling =>
          'Olhe para a bolinha amarela',
        DwellStatus.noFace => 'Não estou vendo seu rosto',
        DwellStatus.eyesClosed => 'Olhos bem abertos!',
      };

  @override
  Widget build(BuildContext context) {
    final done = _calibrator.done;
    final target = calibrationTargets[
        done ? calibrationTargets.length - 1 : _calibrator.index];

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
                          _message ??
                              (_positionIssue == null
                                  ? _hint
                                  : positionMessage(_positionIssue!)),
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
                              : 'Siga a bolinha com os olhos até ela mudar '
                                  'de lugar. Deixe a cabeça parada.',
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
                    child: const _TargetDot(),
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

/// O alvo: uma bolinha fixa, sem anel nem cursor.
///
/// O anel que enchia e o cursor provisório pareciam dizer "o aparelho está
/// vendo seu olho aqui", mas o anel enche com o tempo (com o rosto no
/// quadro), olhe a criança para onde olhar: a mensagem era falsa. A bolinha
/// só diz para onde olhar.
class _TargetDot extends StatelessWidget {
  const _TargetDot();

  @override
  Widget build(BuildContext context) => Container(
        width: 80,
        height: 80,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Palette.amber.withValues(alpha: 0.14),
        ),
        child: Container(
          width: 26,
          height: 26,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Palette.amber,
          ),
        ),
      );
}
