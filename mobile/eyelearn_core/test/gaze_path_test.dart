import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

void main() {
  final trace = GazeTrace(
    t: [for (var i = 0; i < 60; i++) 10 + i / 30],
    x: [for (var i = 0; i < 60; i++) i == 31 ? double.nan : i / 7],
    y: [for (var i = 0; i < 60; i++) -i / 3],
  );

  test('reduz a 15 amostras por segundo, arredondado, a partir de zero', () {
    final path = GazePath.fromTrace(trace);
    expect(path.t.length, 30);
    expect(path.t.first, 0);
    expect(path.duration, closeTo(1.93, 0.01));
    expect(path.x[1], 0.3); // 2/7, arredondado a 0,1
  });

  test('amostra perdida vira null e volta igual do JSON', () {
    final path = GazePath.fromTrace(trace, rateHz: 30);
    expect(path.x[31], isNull);
    final back = GazePath.fromJson(path.toJson());
    expect(back.t, path.t);
    expect(back.x, path.x);
    expect(back.y, path.y);
  });

  test('posição num instante e o rastro', () {
    final path = GazePath.fromTrace(trace, rateHz: 30);
    expect(path.at(0.5)!.x, closeTo(15 / 7, 0.06));
    // Na amostra perdida não há bolinha, e o motivo fica registrado.
    expect(path.at(31 / 30 + 0.001), isNull);
    expect(path.sampleAt(31 / 30 + 0.001)!.state, GazeSampleState.eyesClosed);
    expect(path.between(0.5, 1.0).length, 16);
  });

  test('a sessão leva o percurso e o lê de volta', () {
    final session = Session(
      participantCode: 'AAA222',
      task: 'text',
      startedAt: DateTime.utc(2026, 10, 28),
      durationSeconds: 2,
      samplingRateHz: 30,
      validSampleRatio: 0.9,
      features: const {},
      score: 0,
      modelMetadata: const {},
      gazePath: GazePath.fromTrace(trace),
      calibrationErrorDegrees: 3.6,
    );
    final back = Session.fromJsonString(session.toJsonString());
    expect(back.gazePath!.t, session.gazePath!.t);
    expect(back.calibrationErrorDegrees, 3.6);
    expect(back.approximateCalibration, isTrue);
  });

  group('olhar fora da tela', () {
    // Mapa simples: deslocamento x 40 = graus.
    final calibration = GazeCalibration.fit([
      for (final (x, y) in [
        (0.0, 0.0),
        (-10.0, -10.0),
        (10.0, -10.0),
        (10.0, 10.0),
        (-10.0, 10.0)
      ])
        CalibrationSample(
            targetX: x, targetY: y, offsetX: x / 40, offsetY: y / 40),
    ]);
    FaceFrame look(double t, double x, double y, {bool closed = false}) =>
        syntheticFaceFrame(
          offsetX: x / 40,
          offsetY: y / 40,
          timestamp: t,
          opennessFraction: closed ? 0.02 : defaultOpenness,
        );

    test('o gravador guarda o olhar fora dos limites e o motivo das perdas',
        () {
      final recorder =
          GazeRecorder(calibration: calibration, boundsDeg: (w: 20.0, h: 30.0));
      var t = 0.0;
      for (var i = 0; i < 30; i++, t += 1 / 15) {
        recorder.add(look(t, 0, 0));
      }
      for (var i = 0; i < 15; i++, t += 1 / 15) {
        recorder.add(look(t, 35, 0)); // olhou para o lado, fora do celular
      }
      for (var i = 0; i < 5; i++, t += 1 / 15) {
        recorder.add(look(t, 0, 0, closed: true));
      }
      for (var i = 0; i < 5; i++, t += 1 / 15) {
        recorder.add(faceAbsentFrame(timestamp: t));
      }
      recorder.add(look(t, 0, 0));

      // Na análise, o olhar fora dos limites é perdido...
      expect(recorder.build().x.where((v) => v.isNaN).length, 25);
      // ...no time-lapse, fica com a posição.
      final path = recorder.path();
      expect(path.x[35], closeTo(35, 0.2));
      expect(path.state[35], GazeSampleState.gaze);
      expect(path.state[47], GazeSampleState.eyesClosed);
      expect(path.state[52], GazeSampleState.noFace);
      // 1 s fora em 3,33 s com o rosto na câmera (sem contar o rosto fora).
      expect(path.offScreenFraction(14, 24), closeTo(1 / 3.33, 0.03));

      final back = GazePath.fromJson(path.toJson());
      expect(back.state, path.state);
    });

    test('percurso sem motivos (sessão anterior) lê perdas como piscada', () {
      final old = GazePath.fromJson({
        't': [0, 0.1, 0.2],
        'x': [1.0, null, 2.0],
        'y': [0.0, null, 0.0],
      });
      expect(old.state[1], GazeSampleState.eyesClosed);
      expect(old.state[2], GazeSampleState.gaze);
    });
  });
}
