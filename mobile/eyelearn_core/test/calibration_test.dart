/// Testes da calibração do olhar.
///
/// A calibração é a única parte do aparelho que não tem contraparte em Python,
/// e portanto não tem vetores de ouro: nasce aqui. Em troca, tem oráculo
/// próprio -- dado um mapa conhecido, o ajuste tem de recuperá-lo.
library;

import 'dart:math' as math;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Gera pontos de calibração a partir de um mapa conhecido.
///
/// Inverter um mapa afim é o oráculo: se o ajuste recupera os coeficientes que
/// geraram os dados, ele está correto.
List<CalibrationSample> samplesFrom({
  required double scaleX,
  required double scaleY,
  double offsetConstantX = 0.0,
  double offsetConstantY = 0.0,
  double shear = 0.0,
  List<({double x, double y})>? offsets,
}) {
  final grid = offsets ??
      const [
        (x: -0.3, y: -0.2),
        (x: 0.3, y: -0.2),
        (x: 0.0, y: 0.0),
        (x: -0.3, y: 0.2),
        (x: 0.3, y: 0.2),
      ];

  return [
    for (final offset in grid)
      CalibrationSample(
        targetX: offsetConstantX + scaleX * offset.x + shear * offset.y,
        targetY: offsetConstantY + scaleY * offset.y,
        offsetX: offset.x,
        offsetY: offset.y,
      ),
  ];
}

void main() {
  group('ajuste linear', () {
    test('recupera um mapa afim conhecido', () {
      final calibration = GazeCalibration.fit(
        samplesFrom(scaleX: 40.0, scaleY: 25.0),
      );

      final predicted = calibration.apply(0.15, -0.1);
      expect(predicted.x, closeTo(40.0 * 0.15, 1e-9));
      expect(predicted.y, closeTo(25.0 * -0.1, 1e-9));
    });

    test('recupera o termo constante', () {
      // O termo constante absorve o desalinhamento entre a câmera e o centro
      // da tela, que muda de aparelho para aparelho.
      final calibration = GazeCalibration.fit(
        samplesFrom(
          scaleX: 30.0,
          scaleY: 20.0,
          offsetConstantX: 4.0,
          offsetConstantY: -3.0,
        ),
      );

      final centre = calibration.apply(0.0, 0.0);
      expect(centre.x, closeTo(4.0, 1e-9));
      expect(centre.y, closeTo(-3.0, 1e-9));
    });

    test('recupera a inclinação cruzada', () {
      // Cabeça inclinada mistura os eixos; o termo cruzado é o que corrige.
      final calibration = GazeCalibration.fit(
        samplesFrom(scaleX: 30.0, scaleY: 20.0, shear: 6.0),
      );

      final predicted = calibration.apply(0.1, 0.2);
      expect(predicted.x, closeTo(30.0 * 0.1 + 6.0 * 0.2, 1e-9));
    });

    test('o resíduo de um ajuste exato é zero', () {
      final calibration = GazeCalibration.fit(
        samplesFrom(scaleX: 40.0, scaleY: 25.0),
      );
      expect(calibration.residualDegrees, closeTo(0.0, 1e-9));
      expect(calibration.isAcceptable(), isTrue);
    });

    test('usa três coeficientes por eixo', () {
      expect(CalibrationOrder.linear.terms, equals(3));
    });
  });

  group('ajuste quadrático', () {
    test('recupera um mapa afim quando há alvos suficientes', () {
      // Nove alvos para seis coeficientes: o termo quadrático tem de sair
      // zero, e o mapa afim tem de ser recuperado.
      final grid = <({double x, double y})>[
        for (final ox in [-0.3, 0.0, 0.3])
          for (final oy in [-0.2, 0.0, 0.2]) (x: ox, y: oy),
      ];
      final calibration = GazeCalibration.fit(
        samplesFrom(scaleX: 35.0, scaleY: 22.0, offsets: grid),
        order: CalibrationOrder.quadratic,
      );

      final predicted = calibration.apply(0.2, -0.15);
      expect(predicted.x, closeTo(35.0 * 0.2, 1e-6));
      expect(predicted.y, closeTo(22.0 * -0.15, 1e-6));
    });

    test('recusa alvos em quantidade insuficiente', () {
      // Com cinco alvos e seis coeficientes o ajuste passaria pelos pontos e
      // erraria entre eles -- pior que o modelo linear.
      expect(
        () => GazeCalibration.fit(
          samplesFrom(scaleX: 30.0, scaleY: 20.0),
          order: CalibrationOrder.quadratic,
        ),
        throwsA(isA<CalibrationError>()),
      );
    });
  });

  group('entradas degeneradas', () {
    test('recusa alvos em quantidade insuficiente', () {
      expect(
        () => GazeCalibration.fit(const [
          CalibrationSample(targetX: 0, targetY: 0, offsetX: 0, offsetY: 0),
        ]),
        throwsA(isA<CalibrationError>()),
      );
    });

    test('recusa todos os alvos no mesmo ponto', () {
      // Acontece de verdade: a criança não olha para os alvos e fica fixada no
      // centro da tela durante a calibração inteira.
      final samples = [
        for (var i = 0; i < 6; i++)
          const CalibrationSample(
            targetX: 1.0,
            targetY: 1.0,
            offsetX: 0.1,
            offsetY: 0.1,
          ),
      ];
      expect(
        () => GazeCalibration.fit(samples),
        throwsA(isA<CalibrationError>()),
      );
    });

    test('recusa alvos colineares', () {
      // Cinco alvos numa linha horizontal não determinam o eixo vertical.
      final samples = [
        for (final ox in [-0.3, -0.15, 0.0, 0.15, 0.3])
          CalibrationSample(
            targetX: 30.0 * ox,
            targetY: 0.0,
            offsetX: ox,
            offsetY: 0.0,
          ),
      ];
      expect(
        () => GazeCalibration.fit(samples),
        throwsA(isA<CalibrationError>()),
      );
    });
  });

  group('rejeição de calibração ruim', () {
    test('resíduo grande não é aceitável', () {
      // Pontos incompatíveis com qualquer mapa afim: a criança olhou para
      // onde quis.
      final samples = [
        const CalibrationSample(
            targetX: -20, targetY: -12, offsetX: 0.1, offsetY: 0.1),
        const CalibrationSample(
            targetX: 20, targetY: -12, offsetX: 0.1, offsetY: -0.1),
        const CalibrationSample(
            targetX: 0, targetY: 0, offsetX: -0.1, offsetY: 0.0),
        const CalibrationSample(
            targetX: -20, targetY: 12, offsetX: -0.1, offsetY: -0.1),
        const CalibrationSample(
            targetX: 20, targetY: 12, offsetX: 0.0, offsetY: 0.1),
      ];
      final calibration = GazeCalibration.fit(samples);

      expect(calibration.residualDegrees, greaterThan(3.0));
      expect(calibration.isAcceptable(), isFalse);
    });

    test('o piso é ajustável', () {
      final calibration = GazeCalibration.fit(
        samplesFrom(scaleX: 40.0, scaleY: 25.0),
      );
      expect(calibration.isAcceptable(maxResidualDegrees: 0.0), isTrue);
    });
  });

  group('precisão esperada do método', () {
    test('ruído de medida da ordem relatada sobrevive ao ajuste', () {
      // Simula o que a câmera entrega: deslocamentos com ruído. O ajuste não
      // pode amplificá-lo -- se amplificasse, o percurso sairia pior que a
      // medida bruta.
      final random = math.Random(7);
      final samples = <CalibrationSample>[];
      for (final offset in const [
        (x: -0.3, y: -0.2),
        (x: 0.3, y: -0.2),
        (x: 0.0, y: 0.0),
        (x: -0.3, y: 0.2),
        (x: 0.3, y: 0.2),
        (x: -0.15, y: 0.1),
        (x: 0.15, y: -0.1),
      ]) {
        final noise = () => (random.nextDouble() - 0.5) * 0.01;
        samples.add(
          CalibrationSample(
            targetX: 40.0 * offset.x,
            targetY: 25.0 * offset.y,
            offsetX: offset.x + noise(),
            offsetY: offset.y + noise(),
          ),
        );
      }

      final calibration = GazeCalibration.fit(samples);
      // Ruído de 0,01 no deslocamento, com escala de 40 graus, dá cerca de
      // 0,4 grau de erro. O ajuste tem de ficar nessa ordem.
      expect(calibration.residualDegrees, lessThan(1.0));
      expect(calibration.isAcceptable(), isTrue);
    });
  });
}
