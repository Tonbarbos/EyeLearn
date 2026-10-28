/// Tela de calibração: a criança olha para cada bolinha até ela mudar de lugar.
///
/// A bolinha só anda quando o olho foi para o lado dela e ficou lá um
/// pouco; quem não olha para as bolinhas não passa. A regra, e por que ela
/// confere a direção do olho e não a posição exata, está em
/// `DwellCalibrator` (núcleo), testada sem tela.
///
/// No teste do olhar ([showGazeCursor]), uma bolinha branca mostra onde o
/// aparelho acha que a pessoa olha, a partir do quarto alvo (antes disso o
/// mapa ainda não sabe nem para que lado cada eixo anda). Na atividade ela
/// fica escondida: a criança passaria a perseguir o cursor.
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

  /// Mostra o cursor do olhar (teste do olhar e vídeos de demonstração).
  final bool showGazeCursor;

  const CalibrationScreen({
    super.key,
    required this.channel,
    required this.onCalibrated,
    this.onPostureReference,
    this.onTargetShown,
    this.showGazeCursor = false,
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

  /// Cursor suavizado, em fração da tela; só para desenhar.
  Offset? _cursor;

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
    final cursor = _calibrator.cursor;
    if (cursor == null) {
      _cursor = null;
    } else {
      final at = Offset(
        cursor.x / (2 * CalibrationScreen.degreesPerHalfWidth) + 0.5,
        cursor.y / (2 * CalibrationScreen.degreesPerHalfHeight) + 0.5,
      );
      _cursor = _cursor == null ? at : Offset.lerp(_cursor, at, 0.35);
    }
    if (_calibrator.status == DwellStatus.filling) {
      final posture = Posture.of(frame);
      if (posture != null) _postures.add(posture);
    }
    setState(() {
      _positionIssue = null;
      // O aviso de recomeço fica até o olho acertar uma bolinha de verdade
      // (a do centro passa sem conferência).
      if (event == DwellEvent.targetConfirmed && _calibrator.index > 1) {
        _message = null;
      }
    });
    switch (event) {
      case DwellEvent.targetConfirmed:
        widget.onTargetShown?.call(calibrationTargets[_calibrator.index]);
      case DwellEvent.finished:
        _finish();
      case DwellEvent.failed:
        _restart('Seus olhos não foram até as bolinhas. Vamos de novo, '
            'olhando para cada uma!');
      case DwellEvent.none:
        break;
    }
  }

  void _restart(String message) {
    setState(() {
      _message = message;
      _cursor = null;
    });
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
        DwellStatus.filling => 'Isso! Continue olhando…',
        DwellStatus.settling => 'Olhe para a bolinha amarela',
        DwellStatus.searching => _calibrator.searchingSeconds < 3
            ? 'Olhe para a bolinha amarela'
            : 'Mexa os olhos até a bolinha, sem virar a cabeça',
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
                  // Na faixa livre entre a linha de alvos de cima (15% da
                  // altura) e a do meio (50%), para nenhuma bolinha cobrir o
                  // texto.
                  alignment: const Alignment(0, -0.36),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
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
                              : widget.showGazeCursor && _cursor != null
                                  ? 'A bolinha branca é onde o celular acha '
                                      'que você olha.'
                                  : 'Siga a bolinha com os olhos até ela '
                                      'mudar de lugar. Deixe a cabeça parada.',
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
                      looking: _calibrator.status == DwellStatus.filling,
                    ),
                  ),
                if (widget.showGazeCursor && _cursor != null && !_failed)
                  Positioned(
                    left: _cursor!.dx * constraints.maxWidth - 11,
                    top: _cursor!.dy * constraints.maxHeight - 11,
                    child: const IgnorePointer(child: _GazeCursor()),
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

/// O alvo. O halo acende quando o olho está nele (o alvo está enchendo):
/// agora isso depende do olhar, e não só do tempo, então a resposta é
/// verdadeira.
class _TargetDot extends StatelessWidget {
  final bool looking;

  const _TargetDot({required this.looking});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 80,
        height: 80,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Palette.amber.withValues(alpha: looking ? 0.38 : 0.14),
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

/// Onde o aparelho acha que a pessoa está olhando, pelo mapa provisório.
class _GazeCursor extends StatelessWidget {
  const _GazeCursor();

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('calibration-cursor'),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.3),
          border: Border.all(color: Colors.white, width: 2),
        ),
      );
}
