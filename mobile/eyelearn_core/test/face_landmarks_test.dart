/// Testes do cálculo do deslocamento da íris.
///
/// É o primeiro estágio da captura no aparelho, e o único que não tem
/// contraparte em Python. O oráculo é geométrico: montando um rosto sintético
/// com a íris numa posição conhecida dentro da órbita, o deslocamento calculado
/// tem de ser aquele.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Atalho para [syntheticFaceFrame], com os nomes que estes testes usam.
///
/// Delega à função da biblioteca em vez de montar o rosto de novo: duas
/// construções do mesmo rosto poderiam divergir, e os testes passariam a
/// verificar uma geometria que o aplicativo não usa.
FaceFrame faceWith({
  required double offsetFraction,
  required double verticalFraction,
  double eyeWidth = defaultEyeWidth,
  double opennessFraction = defaultOpenness,
  double timestamp = 0.0,
}) =>
    syntheticFaceFrame(
      offsetX: offsetFraction,
      offsetY: verticalFraction,
      eyeWidth: eyeWidth,
      opennessFraction: opennessFraction,
      timestamp: timestamp,
    );

void main() {
  group('deslocamento da íris', () {
    test('íris centrada dá deslocamento nulo', () {
      final offset = irisOffset(
        faceWith(offsetFraction: 0.0, verticalFraction: 0.0),
      );
      expect(offset, isNotNull);
      expect(offset!.x, closeTo(0.0, 1e-12));
      expect(offset.y, closeTo(0.0, 1e-12));
    });

    test('recupera o deslocamento horizontal como fração da largura', () {
      final offset = irisOffset(
        faceWith(offsetFraction: 0.2, verticalFraction: 0.0),
      );
      expect(offset!.x, closeTo(0.2, 1e-12));
    });

    test('recupera o deslocamento vertical', () {
      final offset = irisOffset(
        faceWith(offsetFraction: 0.0, verticalFraction: -0.15),
      );
      expect(offset!.y, closeTo(-0.15, 1e-12));
    });

    test('o sinal segue a convenção da tela', () {
      // x positivo para a direita, y positivo para baixo -- a mesma convenção
      // de `pixelsToDegrees` e do percurso.
      final right = irisOffset(
        faceWith(offsetFraction: 0.2, verticalFraction: 0.0),
      )!;
      final down = irisOffset(
        faceWith(offsetFraction: 0.0, verticalFraction: 0.2),
      )!;
      expect(right.x, greaterThan(0));
      expect(down.y, greaterThan(0));
    });

    test('não depende da distância ao aparelho', () {
      // É a razão de normalizar pela largura do olho: afastar o celular
      // encolhe a íris e a órbita na mesma proporção. Sem isso, a criança
      // mudar de postura equivaleria a mudar de olhar.
      final near = irisOffset(
        faceWith(offsetFraction: 0.18, verticalFraction: 0.1, eyeWidth: 0.12),
      )!;
      final far = irisOffset(
        faceWith(offsetFraction: 0.18, verticalFraction: 0.1, eyeWidth: 0.04),
      )!;

      expect(near.x, closeTo(far.x, 1e-12));
      expect(near.y, closeTo(far.y, 1e-12));
    });

    test('mede a abertura dos olhos', () {
      final offset = irisOffset(
        faceWith(
          offsetFraction: 0.0,
          verticalFraction: 0.0,
          opennessFraction: 0.3,
        ),
      );
      expect(offset!.openness, closeTo(0.3, 1e-12));
    });

    test('a piscada fica abaixo do piso de abertura', () {
      // Durante a piscada o centro de íris que o modelo reporta é
      // extrapolado, e não corresponde a olhar nenhum: a amostra tem de ser
      // descartada, não usada.
      final blinking = irisOffset(
        faceWith(
          offsetFraction: 0.0,
          verticalFraction: 0.0,
          opennessFraction: 0.02,
        ),
      );
      expect(blinking!.openness, lessThan(minimumOpenness));
    });

    test('o olho aberto fica acima do piso', () {
      final open = irisOffset(
        faceWith(
          offsetFraction: 0.0,
          verticalFraction: 0.0,
          opennessFraction: 0.3,
        ),
      );
      expect(open!.openness, greaterThan(minimumOpenness));
    });

    test('devolve nulo quando a geometria é degenerada', () {
      // Rosto de perfil ou detecção falhada: a largura do olho vai a zero e a
      // divisão daria infinito, que contaminaria o percurso inteiro.
      expect(irisOffset(faceAbsentFrame()), isNull);
    });

    test('o quadro sem rosto tem a contagem de pontos do modelo', () {
      // Ele atravessa o canal como qualquer outro quadro, e seria recusado na
      // leitura se tivesse pontos a menos.
      expect(
        faceAbsentFrame().landmarks.length,
        equals(FaceMeshIndices.expectedCount),
      );
    });

    test('o gerador recusa largura de olho não positiva', () {
      expect(
        () => syntheticFaceFrame(offsetX: 0, offsetY: 0, eyeWidth: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a abertura padrão fica acima do piso de piscada', () {
      // É o que faz os quadros sintéticos passarem pelo acumulador sem serem
      // descartados como piscada.
      final offset = irisOffset(syntheticFaceFrame(offsetX: 0, offsetY: 0));
      expect(offset!.openness, greaterThan(minimumOpenness));
    });
  });

  group('leitura do canal nativo', () {
    Map<Object?, Object?> payloadWith(int count) => {
          'timestamp': 1.5,
          'landmarks': [
            for (var i = 0; i < count; i++) [0.5, 0.5, 0.0],
          ],
        };

    test('lê um quadro completo', () {
      final frame = FaceFrame.fromChannel(
        payloadWith(FaceMeshIndices.expectedCount),
      );
      expect(frame.timestamp, equals(1.5));
      expect(frame.landmarks.length, equals(FaceMeshIndices.expectedCount));
    });

    test('recusa o modelo sem refinamento de íris', () {
      // 468 pontos é o modelo sem íris. Ele detecta rosto, mas não olhar:
      // seguir adiante produziria um percurso que só reflete movimento de
      // cabeça, e nada no resultado acusaria isso.
      expect(
        () => FaceFrame.fromChannel(payloadWith(468)),
        throwsA(isA<FormatException>()),
      );
    });

    test('recusa quadro sem pontos', () {
      expect(
        () => FaceFrame.fromChannel({'timestamp': 0.0}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('integração com a calibração', () {
    test('o deslocamento medido atravessa a calibração', () {
      // Fecha o caminho: rosto sintético, deslocamento, calibração, grau de
      // ângulo visual. Com um mapa de escala conhecida, o resultado tem de ser
      // a escala vezes o deslocamento.
      final calibration = GazeCalibration.fit(const [
        CalibrationSample(
            targetX: -12.0, targetY: -5.0, offsetX: -0.3, offsetY: -0.2),
        CalibrationSample(
            targetX: 12.0, targetY: -5.0, offsetX: 0.3, offsetY: -0.2),
        CalibrationSample(
            targetX: 0.0, targetY: 0.0, offsetX: 0.0, offsetY: 0.0),
        CalibrationSample(
            targetX: -12.0, targetY: 5.0, offsetX: -0.3, offsetY: 0.2),
        CalibrationSample(
            targetX: 12.0, targetY: 5.0, offsetX: 0.3, offsetY: 0.2),
      ]);

      final offset = irisOffset(
        faceWith(offsetFraction: 0.15, verticalFraction: 0.1),
      )!;
      final gaze = calibration.apply(offset.x, offset.y);

      expect(gaze.x, closeTo(40.0 * 0.15, 1e-9));
      expect(gaze.y, closeTo(25.0 * 0.1, 1e-9));
    });
  });
}
