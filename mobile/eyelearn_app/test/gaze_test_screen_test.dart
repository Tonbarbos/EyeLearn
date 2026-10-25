import 'package:eyelearn_app/src/gaze/synthetic_gaze_source.dart';
import 'package:eyelearn_app/src/homework_app.dart';
import 'package:eyelearn_app/src/session/class_storage.dart';
import 'package:eyelearn_app/src/ui/calibration_screen.dart';
import 'package:eyelearn_app/src/ui/gaze_test_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Olhar sintético que olha para onde a calibração manda.
void _follow(SyntheticGazeSource gaze, CalibrationTarget target) =>
    gaze.lookAtFraction(
      fractionX: target.fractionX,
      fractionY: target.fractionY,
      degreesPerHalfWidth: CalibrationScreen.degreesPerHalfWidth,
      degreesPerHalfHeight: CalibrationScreen.degreesPerHalfHeight,
    );

Future<void> _advance(WidgetTester tester, Duration total) async {
  final steps = total.inMilliseconds ~/ 50;
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _hud(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('gaze-hud'))).data!;

void main() {
  test('a fração da tela é o inverso da conversão da calibração', () {
    final f = gazeToFraction(
      (0.85 - 0.5) * 2 * CalibrationScreen.degreesPerHalfWidth,
      (0.22 - 0.5) * 2 * CalibrationScreen.degreesPerHalfHeight,
    );
    expect(f.dx, closeTo(0.85, 1e-9));
    expect(f.dy, closeTo(0.22, 1e-9));
  });

  testWidgets('calibra e a bolinha segue o olhar', (tester) async {
    late SyntheticGazeSource gaze;
    await tester.pumpWidget(MaterialApp(
      home: GazeTestScreen(
        gaze: () => gaze = SyntheticGazeSource(),
        onTargetShown: (source, target) =>
            _follow(source as SyntheticGazeSource, target),
      ),
    ));
    await _advance(tester, const Duration(seconds: 8));
    expect(find.text('Olhe para os números, um de cada vez'), findsOneWidget);

    // Olha para o número 3 (alto, à direita).
    gaze.lookAtDegrees(9.8, -13.4);
    await _advance(tester, const Duration(milliseconds: 500));
    final hud = _hud(tester);
    expect(hud, contains('quadros/s'));
    final x = double.parse(RegExp(r'x (-?[\d.]+)°').firstMatch(hud)!.group(1)!);
    final y = double.parse(RegExp(r'y (-?[\d.]+)°').firstMatch(hud)!.group(1)!);
    expect(x, closeTo(9.8, 1.0));
    expect(y, closeTo(-13.4, 1.0));

    // Rosto some: avisa, sem quebrar.
    gaze.faceVisible = false;
    await _advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Rosto não encontrado'), findsOneWidget);
    gaze.faceVisible = true;

    // Calibrar de novo volta à bolinha de calibração.
    await tester.tap(find.text('Calibrar de novo'));
    await _advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Siga a bolinha com os olhos'), findsOneWidget);
    await _advance(tester, const Duration(seconds: 8));
    expect(find.byKey(const Key('gaze-hud')), findsOneWidget);

    // Sair desliga a câmera (o widget é descartado).
    await tester.pumpWidget(const SizedBox());
    await _advance(tester, const Duration(milliseconds: 200));
  });

  testWidgets('a tela de entrada oferece o teste, e #olhar abre direto',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    HomeworkEnvironment env({String? link}) => HomeworkEnvironment(
          models: const {},
          gaze: SyntheticGazeSource.new,
          storage: MemoryClassStorage(),
          clock: DateTime.now,
          initialLink: link,
        );

    await tester.pumpWidget(HomeworkApp(environment: env()));
    await _advance(tester, const Duration(seconds: 1));
    await tester.ensureVisible(find.text('Testar o olhar'));
    await tester.tap(find.text('Testar o olhar'));
    await _advance(tester, const Duration(seconds: 1));
    expect(find.byType(GazeTestScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        HomeworkApp(environment: env(link: 'https://x.org/EyeLearn/#olhar')));
    await _advance(tester, const Duration(seconds: 1));
    expect(find.byType(GazeTestScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _advance(tester, const Duration(milliseconds: 200));
  });
}
