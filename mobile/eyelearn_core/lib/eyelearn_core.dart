/// Núcleo do EyeLearn em Dart puro: processamento do olhar e inferência.
///
/// É a porta do pipeline Python para o aparelho. Sem dependência de Flutter, de
/// propósito: a suíte roda com `dart test` em qualquer máquina, e a verificação
/// contra os vetores de ouro do Python não precisa de emulador.
///
/// O caminho normal de uso é:
///
/// ```dart
/// final artifact = ModelArtifact.fromJsonString(await carregarArtefato());
/// final result = analyse(trace, artifact.preprocessing);
/// final score = artifact.scoreFeatures(result.features);
/// ```
///
/// Os parâmetros de extração vêm do artefato, não de constantes locais: é o que
/// garante que o aparelho extraia as características do mesmo jeito que o
/// treino as extraiu.
library;

export 'src/calibration.dart';
export 'src/class_comparison.dart';
export 'src/delivery.dart';
export 'src/dwell_calibration.dart';
export 'src/events.dart';
export 'src/face_landmarks.dart';
export 'src/features.dart';
export 'src/gaze_heatmap.dart';
export 'src/kdf.dart';
export 'src/model.dart';
export 'src/pipeline.dart';
export 'src/recorder.dart';
export 'src/roster.dart';
export 'src/preprocess.dart'
    show
        dropInvalid,
        pixelsToDegrees,
        smooth,
        splitOnGaps,
        validSampleRatio,
        velocity;
export 'src/sealing.dart';
export 'src/session.dart';
export 'src/synthetic_face.dart';
export 'src/teacher_vault.dart';
export 'src/trace.dart';
