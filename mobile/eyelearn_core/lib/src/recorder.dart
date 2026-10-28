/// Acumula os quadros da câmera num percurso do olhar.
///
/// É a ponte entre a captura, que chega quadro a quadro e irregular, e o
/// pipeline, que espera um percurso com tempo estritamente crescente.
///
/// A regra que mais importa aqui: **uma amostra ruim entra como `NaN`, não é
/// descartada.** Descartá-la encurtaria o vetor de tempos sem deixar vestígio,
/// e `splitOnGaps` não teria como saber que houve interrupção -- uma piscada de
/// 300 ms viraria uma sacada de vinte graus entre as duas fixações que a
/// cercam. Marcada como `NaN`, ela é removida por `dropInvalid` deixando o
/// buraco no tempo, que é o que o detector precisa ver.
library;

import 'calibration.dart';
import 'face_landmarks.dart';
import 'gaze_path.dart';
import 'trace.dart';

/// Por que uma amostra foi rejeitada.
enum RejectionReason {
  /// Nenhum rosto no quadro, ou geometria degenerada.
  noFace,

  /// Olhos fechados além do piso: piscada.
  eyesClosed,

  /// Olhar estimado fora da área do estímulo.
  outsideStimulus,
}

/// Contagem das rejeições de uma gravação.
///
/// O aplicativo mostra isso ao final, para o adulto que acompanha: "o rosto
/// saiu do quadro em metade do tempo" é informação acionável, "a captura
/// falhou" não é.
class RecordingQuality {
  final int accepted;
  final Map<RejectionReason, int> rejected;

  const RecordingQuality({required this.accepted, required this.rejected});

  int get total =>
      accepted + rejected.values.fold(0, (sum, count) => sum + count);

  double get validRatio => total == 0 ? 0.0 : accepted / total;

  /// A razão dominante das rejeições, ou `null` se não houve nenhuma.
  RejectionReason? get dominantProblem {
    RejectionReason? worst;
    var highest = 0;
    for (final entry in rejected.entries) {
      if (entry.value > highest) {
        highest = entry.value;
        worst = entry.key;
      }
    }
    return worst;
  }
}

/// Acumula quadros e produz o percurso.
class GazeRecorder {
  final GazeCalibration calibration;

  /// Limites da área de estímulo, em graus. Amostras fora entram como `NaN`.
  final ({double w, double h})? boundsDeg;

  /// Piso de abertura dos olhos abaixo do qual a amostra é piscada.
  final double minOpenness;

  final List<double> _t = [];
  final List<double> _x = [];
  final List<double> _y = [];
  final Map<RejectionReason, int> _rejected = {};
  int _accepted = 0;

  /// O olhar para o time-lapse ([path]): como o percurso, mas com o olhar
  /// fora dos limites guardado e o motivo de cada perda.
  final List<double> _pathX = [];
  final List<double> _pathY = [];
  final List<GazeSampleState> _pathState = [];

  GazeRecorder({
    required this.calibration,
    this.boundsDeg,
    this.minOpenness = minimumOpenness,
  });

  /// Quantos quadros entraram, válidos ou não.
  int get sampleCount => _t.length;

  /// Acrescenta um quadro.
  ///
  /// Quadros com instante não crescente são ignorados: a câmera pode entregar
  /// dois quadros com o mesmo carimbo quando o aparelho engasga, e um tempo
  /// repetido quebraria a invariante do percurso.
  ///
  /// Devolve o motivo da rejeição, ou `null` se a amostra foi aceita.
  RejectionReason? add(FaceFrame frame) {
    if (_t.isNotEmpty && frame.timestamp <= _t.last) return null;

    final offset = irisOffset(frame);
    if (offset == null) {
      _reject(frame.timestamp, RejectionReason.noFace);
      return RejectionReason.noFace;
    }
    if (offset.openness < minOpenness) {
      _reject(frame.timestamp, RejectionReason.eyesClosed);
      return RejectionReason.eyesClosed;
    }

    final gaze = calibration.apply(offset.x, offset.y);
    if (!gaze.x.isFinite || !gaze.y.isFinite) {
      _reject(frame.timestamp, RejectionReason.noFace);
      return RejectionReason.noFace;
    }
    if (boundsDeg != null &&
        (gaze.x.abs() > boundsDeg!.w || gaze.y.abs() > boundsDeg!.h)) {
      _reject(frame.timestamp, RejectionReason.outsideStimulus,
          gaze: (x: gaze.x, y: gaze.y));
      return RejectionReason.outsideStimulus;
    }

    _pathX.add(gaze.x);
    _pathY.add(gaze.y);
    _pathState.add(GazeSampleState.gaze);

    _t.add(frame.timestamp);
    _x.add(gaze.x);
    _y.add(gaze.y);
    _accepted++;
    return null;
  }

  void _reject(double timestamp, RejectionReason reason,
      {({double x, double y})? gaze}) {
    _t.add(timestamp);
    _x.add(double.nan);
    _y.add(double.nan);
    _pathX.add(gaze?.x ?? double.nan);
    _pathY.add(gaze?.y ?? double.nan);
    _pathState.add(switch (reason) {
      RejectionReason.outsideStimulus => GazeSampleState.gaze,
      RejectionReason.eyesClosed => GazeSampleState.eyesClosed,
      RejectionReason.noFace => GazeSampleState.noFace,
    });
    _rejected.update(reason, (count) => count + 1, ifAbsent: () => 1);
  }

  /// O percurso acumulado até agora.
  GazeTrace build() => GazeTrace(
        t: List<double>.unmodifiable(_t),
        x: List<double>.unmodifiable(_x),
        y: List<double>.unmodifiable(_y),
      );

  /// O percurso reduzido para o time-lapse do painel, com o olhar fora da
  /// tela e o motivo das perdas.
  GazePath path({double rateHz = GazePath.maxRateHz}) => GazePath.sample(
        t: _t,
        x: _pathX,
        y: _pathY,
        state: _pathState,
        rateHz: rateHz,
      );

  /// Indicadores de qualidade da gravação.
  RecordingQuality quality() => RecordingQuality(
        accepted: _accepted,
        rejected: Map<RejectionReason, int>.unmodifiable(_rejected),
      );

  /// Esvazia o acumulador, para uma nova gravação.
  void reset() {
    _t.clear();
    _x.clear();
    _y.clear();
    _rejected.clear();
    _accepted = 0;
    _pathX.clear();
    _pathY.clear();
    _pathState.clear();
  }
}
