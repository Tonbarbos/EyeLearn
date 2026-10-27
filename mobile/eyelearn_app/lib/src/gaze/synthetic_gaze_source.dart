/// Fonte de olhar sintética, para a pré-visualização em navegador.
///
/// Faz o papel da câmera: emite quadros com a estrutura de 478 pontos que o
/// MediaPipe entrega, a 30 Hz, com a íris onde se pedir. As telas recebem
/// quadros de verdade e percorrem o caminho de verdade -- descarte de piscada,
/// detecção de eventos, extração, inferência. Só a origem dos quadros é que é
/// sintética.
///
/// **Não entra no aplicativo instalado.** Só `main_demo.dart` a usa.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:eyelearn_core/eyelearn_core.dart';

import 'gaze_source.dart';

/// Escala do mapa verdadeiro entre deslocamento da íris e graus de ângulo
/// visual.
///
/// É a escala que a calibração vai descobrir. Mantê-la explícita aqui é o que
/// permite pedir "olhe para tantos graus" e obter o deslocamento
/// correspondente: a calibração ajustada sobre estes quadros reconstrói
/// exatamente este mapa, e o percurso gravado cai onde se pediu.
const double trueScaleX = 40.0;
const double trueScaleY = 25.0;

/// Taxa de emissão, igual à de uma câmera frontal comum.
const double syntheticSamplingRate = 30.0;

class SyntheticGazeSource implements GazeSource {
  final math.Random _random;

  /// Tremor do deslocamento, em fração da largura do olho.
  ///
  /// Fica baixo o bastante para não atravessar o limiar de velocidade do I-VT e
  /// fragmentar uma fixação.
  final double jitter;

  StreamController<FaceFrame>? _controller;
  Timer? _timer;
  double _clock = 0.0;

  double _offsetX = 0.0;
  double _offsetY = 0.0;
  bool _blinking = false;
  bool _faceVisible = true;

  SyntheticGazeSource({int seed = 7, this.jitter = 0.004})
      : _random = math.Random(seed);

  /// Pede que o olhar vá para um ponto, em graus de ângulo visual.
  void lookAtDegrees(double x, double y) {
    _offsetX = x / trueScaleX;
    _offsetY = y / trueScaleY;
  }

  /// Pede que o olhar vá para um ponto, em fração da tela.
  ///
  /// Usa a mesma conversão da tela de calibração, para que o alvo que a criança
  /// vê e o alvo que a fonte "olha" sejam o mesmo ponto.
  void lookAtFraction({
    required double fractionX,
    required double fractionY,
    required double degreesPerHalfWidth,
    required double degreesPerHalfHeight,
  }) =>
      lookAtDegrees(
        (fractionX - 0.5) * 2 * degreesPerHalfWidth,
        (fractionY - 0.5) * 2 * degreesPerHalfHeight,
      );

  /// Simula uma piscada pela duração informada.
  void blink({Duration duration = const Duration(milliseconds: 250)}) {
    _blinking = true;
    Timer(duration, () => _blinking = false);
  }

  /// Condições anexadas a cada quadro (pose, luz...), como as da captura do
  /// navegador; `null` para quadros só com pontos.
  FrameConditions? conditions;

  /// Simula o rosto saindo do enquadramento.
  // ignore: avoid_setters_without_getters
  set faceVisible(bool visible) => _faceVisible = visible;

  @override
  Future<void> start() async {
    if (_controller != null) return;

    final controller = StreamController<FaceFrame>.broadcast();
    _controller = controller;
    _clock = 0.0;

    final period = Duration(
      microseconds: (1000000 / syntheticSamplingRate).round(),
    );
    _timer = Timer.periodic(period, (_) {
      if (controller.isClosed) return;
      controller.add(_nextFrame());
      _clock += 1 / syntheticSamplingRate;
    });
  }

  FaceFrame _nextFrame() {
    if (!_faceVisible) return faceAbsentFrame(timestamp: _clock);

    final frame = syntheticFaceFrame(
      offsetX: _offsetX + _noise(),
      offsetY: _offsetY + _noise(),
      timestamp: _clock,
      // Durante a piscada a abertura cai abaixo do piso, e o acumulador marca
      // a amostra como perdida em vez de usá-la.
      opennessFraction: _blinking ? 0.02 : defaultOpenness,
    );
    return conditions == null
        ? frame
        : FaceFrame(
            timestamp: frame.timestamp,
            landmarks: frame.landmarks,
            conditions: conditions,
          );
  }

  double _noise() => (_random.nextDouble() - 0.5) * 2 * jitter;

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _controller?.close();
    _controller = null;
  }

  @override
  Stream<FaceFrame> frames() =>
      _controller?.stream ?? const Stream<FaceFrame>.empty();
}
