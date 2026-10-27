import 'package:eyelearn_app/src/activity/passages.dart';
import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/ui/reading_screen.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a leitura começa sozinha depois da contagem', (tester) async {
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
    var started = 0;
    GazeTrace? trace;
    await tester.pumpWidget(MaterialApp(
      home: ReadingScreen(
        channel: SyntheticGazeSource(),
        calibration: calibration,
        passage: passageById('text'),
        onStarted: () => started++,
        onFinished: (t, _, __, ___) => trace = t,
      ),
    ));
    String label() => tester
        .widgetList<Text>(find.descendant(
            of: find.byKey(const Key('reading-button')),
            matching: find.byType(Text)))
        .first
        .data!;

    expect(label(), 'Começa em 3…');
    expect(started, 0);
    for (var i = 0; i < 35; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(started, 1);
    expect(label(), 'Terminei de ler');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const Key('reading-button')));
    // Desligar a origem fecha um StreamController: precisa de tempo real.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(trace, isNotNull);
    expect(trace!.duration, greaterThan(1.5));
  });
}
