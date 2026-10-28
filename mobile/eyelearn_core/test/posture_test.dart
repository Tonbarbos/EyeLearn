import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Rosto sintético com as condições que a captura do navegador mede. Os
/// olhos do rosto sintético têm 0,08 da largura da imagem: 38 px a 480.
FaceFrame frame({
  double t = 0,
  double eyeWidth = defaultEyeWidth,
  double imageWidth = 480,
  double imageHeight = 360,
  double? yaw = 0,
  double? pitch = 0,
  double? roll = 0,
  double? luma = 120,
  double? glare = 0,
  double? tilt = 70,
  double openness = defaultOpenness,
}) {
  final f = syntheticFaceFrame(
    offsetX: 0,
    offsetY: 0,
    timestamp: t,
    eyeWidth: eyeWidth,
    opennessFraction: openness,
  );
  return FaceFrame(
    timestamp: f.timestamp,
    landmarks: f.landmarks,
    conditions: FrameConditions(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      headYaw: yaw,
      headPitch: pitch,
      headRoll: roll,
      eyeLuma: luma,
      glare: glare,
      deviceTilt: tilt,
    ),
  );
}

void main() {
  group('posição', () {
    test('rosto bem posicionado não tem problema', () {
      expect(assessPosition(frame()), isEmpty);
    });

    test('sem rosto', () {
      expect(assessPosition(null), [PositionIssue.noFace]);
      expect(assessPosition(faceAbsentFrame()), [PositionIssue.noFace]);
    });

    test('a largura do olho em pixels diz longe e perto', () {
      final posture = Posture.of(frame())!;
      expect(posture.eyeWidthPx, closeTo(38.4, 0.01));
      expect(assessPosition(frame(eyeWidth: 0.03)),
          contains(PositionIssue.tooFar));
      expect(assessPosition(frame(eyeWidth: 0.14)),
          contains(PositionIssue.tooClose));
    });

    test('cabeça virada, vista de baixo ou inclinada de lado', () {
      expect(assessPosition(frame(yaw: -30)), [PositionIssue.turned]);
      expect(assessPosition(frame(pitch: 30)), [PositionIssue.tiltedUpDown]);
      expect(assessPosition(frame(roll: 25)), [PositionIssue.leaning]);
    });

    test('celular deitado, escuro, reflexo e olhos fechados', () {
      expect(assessPosition(frame(tilt: 8)), [PositionIssue.phoneFlat]);
      expect(assessPosition(frame(luma: 20)), [PositionIssue.dark]);
      expect(assessPosition(frame(glare: 0.2)), [PositionIssue.glare]);
      expect(assessPosition(frame(openness: 0.02)), [PositionIssue.eyesClosed]);
    });

    test('o que a captura não mede não é cobrado', () {
      final bare = syntheticFaceFrame(offsetX: 0, offsetY: 0, eyeWidth: 0.01);
      expect(assessPosition(bare), isEmpty);
    });

    test('sem a pose da captura, a inclinação de lado vem dos olhos', () {
      final f = frame(roll: null);
      final points = List.of(f.landmarks);
      // Desce o olho direito: a linha entre os olhos fica inclinada.
      for (final i in [
        FaceMeshIndices.rightEyeOuter,
        FaceMeshIndices.rightEyeInner,
      ]) {
        points[i] = Landmark(points[i].x, points[i].y + 0.1, 0);
      }
      final tilted =
          FaceFrame(timestamp: 0, landmarks: points, conditions: f.conditions);
      expect(Posture.of(tilted)!.roll!.abs(), greaterThan(15));
      expect(assessPosition(tilted), contains(PositionIssue.leaning));
    });

    test('as condições chegam pelo canal', () {
      final c = FrameConditions.fromMap({
        'image_width': 360,
        'image_height': 480,
        'head_yaw': 3.5,
        'glare': double.nan,
      });
      expect(c.imageWidth, 360);
      expect(c.headYaw, 3.5);
      expect(c.glare, isNull);
      expect(c.deviceTilt, isNull);
    });
  });

  group('sair da posição da calibração', () {
    final reference = PostureReference.fromPostures(
        [for (var i = 0; i < 5; i++) Posture.of(frame(pitch: 5.0 + i))!])!;

    test('a referência é a mediana', () {
      expect(reference.pitch, 7);
      expect(reference.eyeWidthPx, closeTo(38.4, 0.01));
    });

    test('mexer pouco não conta; inclinar ou aproximar conta', () {
      expect(reference.isOutOf(Posture.of(frame(pitch: 12))!), isFalse);
      expect(reference.isOutOf(Posture.of(frame(pitch: 25))!), isTrue);
      expect(reference.isOutOf(Posture.of(frame(eyeWidth: 0.11))!), isTrue);
      expect(reference.isOutOf(Posture.of(frame(tilt: 40))!), isTrue);
    });

    test('o monitor só acusa depois do tempo de tolerância', () {
      final monitor = PostureMonitor(reference);
      var t = 0.0;
      for (var i = 0; i < 30; i++, t += 0.1) {
        monitor.add(frame(t: t));
      }
      expect(monitor.isOut, isFalse);
      for (var i = 0; i < 5; i++, t += 0.1) {
        monitor.add(frame(t: t, pitch: 40));
      }
      expect(monitor.isOut, isFalse, reason: 'meio segundo é tolerado');
      for (var i = 0; i < 25; i++, t += 0.1) {
        monitor.add(frame(t: t, pitch: 40));
      }
      expect(monitor.isOut, isTrue);
      expect(monitor.outRatio, closeTo(1.9 / 5.9, 0.02));
      monitor.add(frame(t: t));
      expect(monitor.isOut, isFalse);
    });
  });
}
