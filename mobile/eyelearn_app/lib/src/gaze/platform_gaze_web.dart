/// Navegador: câmera do navegador e MediaPipe para web, via `web/gaze.js`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:eyelearn_core/eyelearn_core.dart';

import 'gaze_source.dart';

GazeSource createPlatformGazeSource() => WebGazeSource();

/// O navegador pergunta pela câmera no `getUserMedia`; o aplicativo não pede.
const bool platformAsksCameraPermission = true;

@JS('eyelearnGaze')
external _EyelearnGaze? get _bridge;

extension type _EyelearnGaze._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> start();
  external void stop();
  external set onFrame(JSFunction? callback);
}

class WebGazeSource implements GazeSource {
  final _frames = StreamController<FaceFrame>.broadcast();

  @override
  Future<void> start() async {
    final bridge = _bridge;
    if (bridge == null) {
      throw const GazeCaptureError(
        'a captura do olhar não carregou nesta página (gaze.js ausente)',
      );
    }
    bridge.onFrame = _onFrame.toJS;
    try {
      await bridge.start().toDart;
    } catch (error) {
      bridge.onFrame = null;
      throw GazeCaptureError(_message(error), error);
    }
  }

  void _onFrame(
      JSNumber seconds, JSFloat32Array points, JSFloat32Array? conditions) {
    final flat = points.toDart;
    if (flat.length < FaceMeshIndices.expectedCount * 3) return;
    _frames.add(
      FaceFrame(
        timestamp: seconds.toDartDouble,
        landmarks: _landmarks(flat),
        conditions: conditions == null ? null : _conditions(conditions.toDart),
      ),
    );
  }

  /// Na ordem de `CONDITIONS` em `web/gaze.js`; NaN é "não medido".
  static FrameConditions? _conditions(Float32List c) {
    if (c.length < 8) return null;
    double? at(int i) => c[i].isFinite ? c[i].toDouble() : null;
    return FrameConditions(
      imageWidth: at(0),
      imageHeight: at(1),
      headYaw: at(2),
      headPitch: at(3),
      headRoll: at(4),
      eyeLuma: at(5),
      glare: at(6),
      deviceTilt: at(7),
    );
  }

  static List<Landmark> _landmarks(Float32List flat) => [
        for (var i = 0; i < flat.length ~/ 3; i++)
          Landmark(flat[3 * i], flat[3 * i + 1], flat[3 * i + 2]),
      ];

  /// A mensagem do `Error` do JavaScript, sem o prefixo que o compilador põe.
  static String _message(Object error) {
    final text = error.toString();
    for (final prefix in ['Error: ', 'JavaScriptError: ']) {
      if (text.startsWith(prefix)) return text.substring(prefix.length);
    }
    return text;
  }

  @override
  Future<void> stop() async {
    final bridge = _bridge;
    if (bridge == null) return;
    bridge.onFrame = null;
    bridge.stop();
  }

  @override
  Stream<FaceFrame> frames() => _frames.stream;
}
