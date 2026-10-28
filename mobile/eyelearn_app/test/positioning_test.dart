import 'package:eyelearn_app/src/activity/passages.dart';
import 'package:eyelearn_app/src/gaze/gaze_source.dart';
import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/ui/calibration_screen.dart';
import 'package:eyelearn_app/src/ui/positioning_screen.dart';
import 'package:eyelearn_app/src/ui/reading_screen.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Condições de um rosto bem posicionado, como a captura do navegador mede.
/// Os olhos do rosto sintético têm 0,08 da imagem: 38 px a 480.
FrameConditions conditions({double pitch = 0, double width = 480}) =>
    FrameConditions(
      imageWidth: width,
      imageHeight: width * 0.75,
      headYaw: 0,
      headPitch: pitch,
      headRoll: 0,
      eyeLuma: 120,
      glare: 0,
      deviceTilt: 70,
    );

/// A captura do navegador sem rosto: não manda quadro nenhum.
class _SilentSource implements GazeSource {
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<FaceFrame> frames() => const Stream.empty();
}

Future<void> _advance(WidgetTester tester, Duration total) async {
  for (var i = 0; i < total.inMilliseconds ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('com tudo certo, segue sozinha', (tester) async {
    final gaze = SyntheticGazeSource()..conditions = conditions();
    var ready = 0;
    await tester.pumpWidget(MaterialApp(
      home: PositioningScreen(channel: gaze, onReady: () => ready++),
    ));
    await _advance(tester, const Duration(milliseconds: 600));
    expect(_text(tester, 'positioning-message'), 'Isso! Fique assim…');
    expect(ready, 0, reason: 'espera a posição se manter');
    await _advance(tester, const Duration(seconds: 2));
    expect(ready, 1);
    await gaze.stop();
  });

  testWidgets('longe demais: pede para chegar perto e deixa seguir depois',
      (tester) async {
    // A 200 px de largura, o olho tem 16 px: longe.
    final gaze = SyntheticGazeSource()..conditions = conditions(width: 200);
    var ready = 0;
    await tester.pumpWidget(MaterialApp(
      home: PositioningScreen(channel: gaze, onReady: () => ready++),
    ));
    await _advance(tester, const Duration(seconds: 3));
    expect(_text(tester, 'positioning-message'), 'Chegue um pouco mais perto');
    expect(ready, 0);
    expect(find.byKey(const Key('positioning-skip')), findsNothing);

    // Corrigiu: segue.
    gaze.conditions = conditions();
    await _advance(tester, const Duration(seconds: 3));
    expect(ready, 1);
    await gaze.stop();
  });

  testWidgets('sem rosto: avisa e, depois de um tempo, oferece seguir',
      (tester) async {
    var ready = 0;
    await tester.pumpWidget(MaterialApp(
      home: PositioningScreen(
        channel: _SilentSource(),
        onReady: () => ready++,
        giveUpAfter: const Duration(seconds: 5),
      ),
    ));
    await _advance(tester, const Duration(seconds: 1));
    expect(_text(tester, 'positioning-message'), 'Não estou vendo seu rosto');
    await _advance(tester, const Duration(seconds: 5));
    await tester.ensureVisible(find.byKey(const Key('positioning-skip')));
    await tester.tap(find.byKey(const Key('positioning-skip')));
    await tester.pump();
    expect(ready, 1);
  });

  testWidgets('a calibração espera o rosto voltar para a posição',
      (tester) async {
    final gaze = SyntheticGazeSource()..conditions = conditions(pitch: 35);
    await tester.pumpWidget(MaterialApp(
      home: CalibrationScreen(channel: gaze, onCalibrated: (_) {}),
    ));
    await _advance(tester, const Duration(seconds: 1));
    expect(_text(tester, 'calibration-hint'),
        'Segure o celular na altura do rosto');
    gaze.conditions = conditions();
    await _advance(tester, const Duration(milliseconds: 300));
    expect(_text(tester, 'calibration-hint'),
        isNot('Segure o celular na altura do rosto'));
    await gaze.stop();
  });

  testWidgets('na leitura, sair da posição da calibração acende o aviso',
      (tester) async {
    final calibration = GazeCalibration.fit([
      for (final (x, y) in [
        (0.0, 0.0),
        (-10.0, -10.0),
        (10.0, -10.0),
        (10.0, 10.0),
        (-10.0, 10.0)
      ])
        CalibrationSample(
            targetX: x,
            targetY: y,
            offsetX: x / trueScaleX,
            offsetY: y / trueScaleY),
    ]);
    final reference = PostureReference.fromPostures([
      Posture.of(FaceFrame(
        timestamp: 0,
        landmarks: syntheticFaceFrame(offsetX: 0, offsetY: 0).landmarks,
        conditions: conditions(),
      ))!,
    ]);
    final gaze = SyntheticGazeSource()..conditions = conditions();
    double? outOfPosition;
    await tester.pumpWidget(MaterialApp(
      home: ReadingScreen(
        channel: gaze,
        calibration: calibration,
        passage: passageById('text'),
        postureReference: reference,
        onFinished: (r) => outOfPosition = r.outOfPosition,
      ),
    ));
    await _advance(tester, const Duration(seconds: 5));
    expect(find.byKey(const Key('out-of-position')), findsNothing);

    gaze.conditions = conditions(pitch: 30);
    await _advance(tester, const Duration(seconds: 2));
    expect(find.byKey(const Key('out-of-position')), findsOneWidget);

    gaze.conditions = conditions();
    await _advance(tester, const Duration(milliseconds: 300));
    expect(find.byKey(const Key('out-of-position')), findsNothing);

    await tester.ensureVisible(find.text('Terminei de ler'));
    await tester.tap(find.text('Terminei de ler'));
    // Desligar a origem fecha um StreamController: precisa de tempo real.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _advance(tester, const Duration(milliseconds: 300));
    expect(outOfPosition, greaterThan(0.1));
    expect(outOfPosition, lessThan(0.5));
  });
}
