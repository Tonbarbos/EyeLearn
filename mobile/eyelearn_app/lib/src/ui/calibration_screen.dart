/// Tela de calibração: a criança segue um alvo pela tela.
///
/// Cinco alvos, nos quatro cantos úteis e no centro, que é o mínimo para o mapa
/// linear de `GazeCalibration`. Apresentados como um jogo -- um ponto que pula
/// e precisa ser "pego" com o olhar -- porque uma criança de nove anos não
/// mantém atenção numa tarefa chamada calibração.
library;

import 'dart:async';

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

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

/// Os cinco alvos. Centro por último: é o mais fácil de acertar, e terminar
/// nele deixa a criança com a sensação de ter conseguido.
const List<CalibrationTarget> calibrationTargets = [
  CalibrationTarget(0.12, 0.15),
  CalibrationTarget(0.88, 0.15),
  CalibrationTarget(0.12, 0.85),
  CalibrationTarget(0.88, 0.85),
  CalibrationTarget(0.5, 0.5),
];

/// Quanto tempo o alvo fica parado antes de a medida ser colhida.
///
/// Os primeiros 600 ms são descartados: é o tempo de a criança encontrar o alvo
/// e a sacada acabar. A medida sai da média dos 400 ms seguintes, com o olhar
/// já estabilizado.
const Duration targetSettleTime = Duration(milliseconds: 600);
const Duration targetMeasureTime = Duration(milliseconds: 400);

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
  Timer? _timer;

  int _targetIndex = 0;
  bool _measuring = false;
  final List<IrisOffset> _measurements = [];
  final List<CalibrationSample> _samples = [];
  String? _message;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      await widget.channel.start();
    } on GazeCaptureError catch (error) {
      if (mounted) setState(() => _message = error.message);
      return;
    }

    _subscription = widget.channel.frames().listen(_onFrame);
    _scheduleTarget();
  }

  void _scheduleTarget() {
    _measurements.clear();
    setState(() => _measuring = false);
    widget.onTargetShown?.call(calibrationTargets[_targetIndex]);

    _timer = Timer(targetSettleTime, () {
      setState(() => _measuring = true);
      _timer = Timer(targetMeasureTime, _collectTarget);
    });
  }

  void _onFrame(FaceFrame frame) {
    if (!_measuring) return;

    final offset = irisOffset(frame);
    // Durante a piscada o centro de íris é extrapolado e não corresponde a
    // olhar nenhum: deixar entrar na média deslocaria o alvo inteiro.
    if (offset == null || offset.openness < minimumOpenness) return;
    _measurements.add(offset);
  }

  void _collectTarget() {
    setState(() => _measuring = false);

    // Um alvo sem medida suficiente é repetido, não descartado: perder um alvo
    // dos cinco deixaria o mapa linear sem folga nenhuma.
    if (_measurements.length < 5) {
      setState(
        () => _message = 'Não consegui ver bem. Vamos tentar esse de novo!',
      );
      _scheduleTarget();
      return;
    }

    var sumX = 0.0;
    var sumY = 0.0;
    for (final measurement in _measurements) {
      sumX += measurement.x;
      sumY += measurement.y;
    }

    final target = calibrationTargets[_targetIndex];
    _samples.add(
      CalibrationSample(
        // Fração da tela para graus, com a origem no centro.
        targetX: (target.fractionX - 0.5) *
            2 *
            CalibrationScreen.degreesPerHalfWidth,
        targetY: (target.fractionY - 0.5) *
            2 *
            CalibrationScreen.degreesPerHalfHeight,
        offsetX: sumX / _measurements.length,
        offsetY: sumY / _measurements.length,
      ),
    );

    if (_targetIndex + 1 < calibrationTargets.length) {
      setState(() {
        _targetIndex++;
        _message = null;
      });
      _scheduleTarget();
      return;
    }

    _finish();
  }

  void _finish() {
    _subscription?.cancel();
    _subscription = null;

    try {
      final calibration = GazeCalibration.fit(_samples);
      if (!calibration.isAcceptable()) {
        setState(() {
          _message = 'Ficou meio torto. Vamos fazer de novo, bem devagar.';
          _targetIndex = 0;
          _samples.clear();
        });
        _begin();
        return;
      }
      widget.onCalibrated(calibration);
    } on CalibrationError {
      setState(() {
        _message = 'Não deu certo. Vamos tentar outra vez!';
        _targetIndex = 0;
        _samples.clear();
      });
      _begin();
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = calibrationTargets[_targetIndex];

    return Scaffold(
      backgroundColor: const Color(0xFF102A43),
      // O LayoutBuilder envolve o Stack, e não o contrário: um Positioned
      // devolvido de dentro do builder teria o LayoutBuilder como pai, não o
      // Stack, e o Flutter lançaria "Incorrect use of ParentDataWidget" a cada
      // quadro -- o alvo não aparecia e a calibração seguia com o percurso
      // errado.
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _message ?? 'Siga a bolinha com os olhos!',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Positioned(
                // Centra o ponto no alvo: metade do diâmetro maior do círculo.
                left: target.fractionX * constraints.maxWidth - 28,
                top: target.fractionY * constraints.maxHeight - 28,
                child: _TargetDot(active: _measuring),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    '${_targetIndex + 1} de ${calibrationTargets.length}',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bolinha do alvo. Cresce quando está medindo, para dar à criança o sinal
/// de que é agora que ela precisa olhar firme.
class _TargetDot extends StatelessWidget {
  final bool active;

  const _TargetDot({required this.active});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: active ? 56 : 36,
        height: active ? 56 : 36,
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFFC857) : const Color(0xFF7FB2D9),
          shape: BoxShape.circle,
          boxShadow: [
            if (active)
              const BoxShadow(
                color: Color(0x55FFC857),
                blurRadius: 24,
                spreadRadius: 6,
              ),
          ],
        ),
      );
}
