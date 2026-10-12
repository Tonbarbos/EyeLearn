/// Testes do acumulador de quadros.
///
/// A afirmação central é a que o resto do pipeline depende: uma amostra ruim
/// entra como `NaN` e deixa o buraco no tempo, em vez de desaparecer. Sem isso,
/// uma piscada de 300 ms viraria uma sacada de vinte graus entre as duas
/// fixações que a cercam, e nada no resultado acusaria o problema.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

import 'face_landmarks_test.dart' show faceWith;

/// Calibração de escala conhecida: 40 graus na horizontal, 25 na vertical.
GazeCalibration buildCalibration() => GazeCalibration.fit(const [
      CalibrationSample(
          targetX: -12.0, targetY: -5.0, offsetX: -0.3, offsetY: -0.2),
      CalibrationSample(
          targetX: 12.0, targetY: -5.0, offsetX: 0.3, offsetY: -0.2),
      CalibrationSample(targetX: 0.0, targetY: 0.0, offsetX: 0.0, offsetY: 0.0),
      CalibrationSample(
          targetX: -12.0, targetY: 5.0, offsetX: -0.3, offsetY: 0.2),
      CalibrationSample(
          targetX: 12.0, targetY: 5.0, offsetX: 0.3, offsetY: 0.2),
    ]);

void main() {
  group('amostras aceitas', () {
    test('acumula o percurso em graus', () {
      final recorder = GazeRecorder(calibration: buildCalibration());
      recorder.add(
        faceWith(offsetFraction: 0.1, verticalFraction: 0.0, timestamp: 0.0),
      );
      recorder.add(
        faceWith(offsetFraction: 0.2, verticalFraction: 0.0, timestamp: 0.033),
      );

      final trace = recorder.build();
      expect(trace.length, equals(2));
      expect(trace.x[0], closeTo(4.0, 1e-9));
      expect(trace.x[1], closeTo(8.0, 1e-9));
    });

    test('o tempo sai estritamente crescente', () {
      final recorder = GazeRecorder(calibration: buildCalibration());
      for (var i = 0; i < 10; i++) {
        recorder.add(
          faceWith(
            offsetFraction: 0.1,
            verticalFraction: 0.0,
            timestamp: i * 0.033,
          ),
        );
      }
      // O construtor de GazeTrace recusaria tempo não crescente; chegar aqui
      // já é parte da afirmação.
      final trace = recorder.build();
      for (var i = 1; i < trace.length; i++) {
        expect(trace.t[i], greaterThan(trace.t[i - 1]));
      }
    });

    test('ignora quadro com instante repetido', () {
      // A câmera entrega dois quadros com o mesmo carimbo quando o aparelho
      // engasga; um tempo repetido quebraria a invariante do percurso.
      final recorder = GazeRecorder(calibration: buildCalibration());
      recorder.add(
          faceWith(offsetFraction: 0.1, verticalFraction: 0.0, timestamp: 1.0));
      recorder.add(
          faceWith(offsetFraction: 0.2, verticalFraction: 0.0, timestamp: 1.0));
      recorder.add(
          faceWith(offsetFraction: 0.3, verticalFraction: 0.0, timestamp: 0.5));

      expect(recorder.sampleCount, equals(1));
    });
  });

  group('amostras rejeitadas', () {
    test('a piscada entra como NaN e preserva o buraco no tempo', () {
      final recorder = GazeRecorder(calibration: buildCalibration());
      recorder.add(
          faceWith(offsetFraction: 0.1, verticalFraction: 0.0, timestamp: 0.0));
      final reason = recorder.add(
        faceWith(
          offsetFraction: 0.1,
          verticalFraction: 0.0,
          opennessFraction: 0.01,
          timestamp: 0.033,
        ),
      );
      recorder.add(faceWith(
          offsetFraction: 0.1, verticalFraction: 0.0, timestamp: 0.066));

      expect(reason, equals(RejectionReason.eyesClosed));

      final trace = recorder.build();
      expect(trace.length, equals(3));
      expect(trace.x[1].isNaN, isTrue);
      // O instante da amostra perdida continua no vetor: é o que permite a
      // dropInvalid e splitOnGaps enxergarem a interrupção.
      expect(trace.t[1], closeTo(0.033, 1e-12));
    });

    test('rosto ausente entra como NaN', () {
      final recorder = GazeRecorder(calibration: buildCalibration());
      final collapsed = FaceFrame(
        timestamp: 0.0,
        landmarks: List<Landmark>.filled(
          FaceMeshIndices.expectedCount,
          const Landmark(0.5, 0.5, 0.0),
        ),
      );
      expect(recorder.add(collapsed), equals(RejectionReason.noFace));
      expect(recorder.build().x[0].isNaN, isTrue);
    });

    test('olhar fora do estímulo entra como NaN', () {
      final recorder = GazeRecorder(
        calibration: buildCalibration(),
        boundsDeg: (w: 5.0, h: 5.0),
      );
      // Deslocamento de 0,3 dá 12 graus, fora do limite de 5.
      expect(
        recorder.add(
          faceWith(offsetFraction: 0.3, verticalFraction: 0.0, timestamp: 0.0),
        ),
        equals(RejectionReason.outsideStimulus),
      );
      expect(recorder.build().x[0].isNaN, isTrue);
    });

    test('sem limites informados nada é rejeitado por posição', () {
      final recorder = GazeRecorder(calibration: buildCalibration());
      expect(
        recorder.add(
          faceWith(offsetFraction: 0.3, verticalFraction: 0.0, timestamp: 0.0),
        ),
        isNull,
      );
    });
  });

  group('indicadores de qualidade', () {
    GazeRecorder recorderWithBlinks(int good, int blinks) {
      final recorder = GazeRecorder(calibration: buildCalibration());
      var clock = 0.0;
      for (var i = 0; i < good; i++) {
        recorder.add(
          faceWith(
              offsetFraction: 0.1, verticalFraction: 0.0, timestamp: clock),
        );
        clock += 0.033;
      }
      for (var i = 0; i < blinks; i++) {
        recorder.add(
          faceWith(
            offsetFraction: 0.1,
            verticalFraction: 0.0,
            opennessFraction: 0.01,
            timestamp: clock,
          ),
        );
        clock += 0.033;
      }
      return recorder;
    }

    test('conta aceitas e rejeitadas', () {
      final quality = recorderWithBlinks(8, 2).quality();
      expect(quality.accepted, equals(8));
      expect(quality.total, equals(10));
      expect(quality.validRatio, closeTo(0.8, 1e-12));
    });

    test('aponta o problema dominante', () {
      // "O rosto saiu do quadro em metade do tempo" é informação acionável
      // para o adulto que acompanha; "a captura falhou" não é.
      final quality = recorderWithBlinks(2, 8).quality();
      expect(quality.dominantProblem, equals(RejectionReason.eyesClosed));
    });

    test('sem rejeição não há problema dominante', () {
      expect(recorderWithBlinks(5, 0).quality().dominantProblem, isNull);
    });

    test('gravação vazia tem proporção nula e não divide por zero', () {
      final quality = GazeRecorder(calibration: buildCalibration()).quality();
      expect(quality.total, equals(0));
      expect(quality.validRatio, equals(0.0));
    });
  });

  group('reinício', () {
    test('esvazia o acumulado', () {
      final recorder = GazeRecorder(calibration: buildCalibration());
      recorder.add(
          faceWith(offsetFraction: 0.1, verticalFraction: 0.0, timestamp: 0.0));
      recorder.reset();

      expect(recorder.sampleCount, equals(0));
      expect(recorder.build().isEmpty, isTrue);
      expect(recorder.quality().total, equals(0));
    });

    test('aceita instantes anteriores depois do reinício', () {
      // Uma nova gravação recomeça o relógio do zero.
      final recorder = GazeRecorder(calibration: buildCalibration());
      recorder.add(
          faceWith(offsetFraction: 0.1, verticalFraction: 0.0, timestamp: 9.0));
      recorder.reset();
      expect(
        recorder.add(
          faceWith(offsetFraction: 0.1, verticalFraction: 0.0, timestamp: 0.0),
        ),
        isNull,
      );
      expect(recorder.sampleCount, equals(1));
    });
  });

  group('caminho completo até a predição', () {
    test('uma gravação com piscada atravessa o pipeline inteiro', () {
      // Fecha o circuito: quadros sintéticos, acumulador, pipeline, modelo.
      // Não afirma nada sobre o valor da predição -- só que o caminho não
      // quebra e que a piscada não inventou sacada.
      final recorder = GazeRecorder(calibration: buildCalibration());
      var clock = 0.0;

      void fixate(double offset, int frames) {
        for (var i = 0; i < frames; i++) {
          recorder.add(
            faceWith(
              offsetFraction: offset,
              verticalFraction: 0.0,
              timestamp: clock,
            ),
          );
          clock += 1 / 30.0;
        }
      }

      fixate(0.05, 10);
      // Piscada longa no meio.
      for (var i = 0; i < 9; i++) {
        recorder.add(
          faceWith(
            offsetFraction: 0.05,
            verticalFraction: 0.0,
            opennessFraction: 0.01,
            timestamp: clock,
          ),
        );
        clock += 1 / 30.0;
      }
      fixate(0.25, 10);

      final trace = recorder.build();
      expect(trace.length, equals(29));

      // O buraco de 300 ms separa os dois blocos, então nenhuma sacada
      // atravessa a piscada.
      final cleaned = dropInvalid(trace);
      final segments = splitOnGaps(cleaned);
      expect(segments.length, equals(2));

      final detected = detectEvents(cleaned);
      expect(detected.saccades, isEmpty);
      expect(detected.fixations.length, equals(2));
    });
  });
}
