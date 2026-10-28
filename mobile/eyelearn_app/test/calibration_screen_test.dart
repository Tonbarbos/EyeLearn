import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/ui/calibration_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _advance(WidgetTester tester, Duration total) async {
  for (var i = 0; i < total.inMilliseconds ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _hint(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('calibration-hint'))).data!;

void main() {
  testWidgets('olhando as bolinhas, calibra; o cursor aparece no teste',
      (tester) async {
    final gaze = SyntheticGazeSource();
    var calibrated = 0;
    var cursorSeen = false;
    await tester.pumpWidget(MaterialApp(
      home: CalibrationScreen(
        channel: gaze,
        showGazeCursor: true,
        onTargetShown: (t) => gaze.lookAtFraction(
          fractionX: t.fractionX,
          fractionY: t.fractionY,
          degreesPerHalfWidth: CalibrationScreen.degreesPerHalfWidth,
          degreesPerHalfHeight: CalibrationScreen.degreesPerHalfHeight,
        ),
        onCalibrated: (_) => calibrated++,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    // O medidor do olho aparece desde a primeira bolinha.
    expect(find.byKey(const Key('eye-meter')), findsOneWidget);
    for (var i = 0; i < 400 && calibrated == 0; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      cursorSeen |=
          find.byKey(const Key('calibration-cursor')).evaluate().isNotEmpty;
    }
    expect(calibrated, 1);
    expect(cursorSeen, isTrue);
    await gaze.stop();
  });

  testWidgets('sem olhar para as bolinhas, não passa e recomeça',
      (tester) async {
    // Olhar parado num ponto só, como quem olha para outro lugar.
    final gaze = SyntheticGazeSource()..lookAtDegrees(0, 0);
    var calibrated = 0;
    await tester.pumpWidget(MaterialApp(
      home: CalibrationScreen(channel: gaze, onCalibrated: (_) => calibrated++),
    ));
    await _advance(tester, const Duration(seconds: 6));
    expect(_hint(tester), 'Mexa os olhos até a bolinha, sem virar a cabeça');
    expect(find.byKey(const Key('calibration-cursor')), findsNothing);
    // Na atividade o medidor fica, sem os números.
    expect(find.byKey(const Key('eye-meter')), findsOneWidget);
    expect(find.textContaining('movimento do olho:'), findsNothing);
    await _advance(tester, const Duration(seconds: 30));
    expect(calibrated, 0);
    expect(_hint(tester), startsWith('Seus olhos não foram até as bolinhas'));
    await gaze.stop();
  });
}
