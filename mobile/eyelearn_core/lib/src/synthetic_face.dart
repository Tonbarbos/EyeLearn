/// Quadros de rosto sintéticos, com a íris numa posição conhecida.
///
/// Servem a duas coisas. Nos testes, dão oráculo geométrico ao cálculo do
/// deslocamento da íris: montando um rosto com a íris a uma fração conhecida
/// da largura do olho, o deslocamento calculado tem de ser aquela fração.
///
/// Na pré-visualização em navegador (`main_demo.dart` do aplicativo), fazem o
/// papel da câmera: as telas recebem quadros de verdade, com a estrutura de 478
/// pontos que o MediaPipe entrega, sem precisar de câmera, de Android nem do
/// modelo. O que se vê ali são os widgets reais percorrendo o caminho real --
/// só a origem dos quadros é que é sintética.
library;

import 'face_landmarks.dart';

/// Largura padrão do olho, em fração da imagem.
const double defaultEyeWidth = 0.08;

/// Abertura padrão dos olhos, em fração da largura do olho.
///
/// Fica em torno de 0,3 num olho aberto, bem acima do piso de [minimumOpenness].
const double defaultOpenness = 0.3;

/// Monta um quadro com a íris deslocada de uma fração conhecida da largura do
/// olho.
///
/// Os dois olhos recebem o mesmo deslocamento, que é o caso de alguém olhando
/// para um ponto distante o bastante para que a convergência seja desprezível.
///
/// [opennessFraction] abaixo de [minimumOpenness] produz um quadro de piscada:
/// o deslocamento continua lá, mas o consumidor deve descartá-lo, porque
/// durante a piscada o centro de íris que o modelo reporta é extrapolado.
FaceFrame syntheticFaceFrame({
  required double offsetX,
  required double offsetY,
  double timestamp = 0.0,
  double eyeWidth = defaultEyeWidth,
  double opennessFraction = defaultOpenness,
}) {
  if (eyeWidth <= 0) {
    throw ArgumentError('eyeWidth deve ser positiva, recebido $eyeWidth');
  }

  final points = List<Landmark>.filled(
    FaceMeshIndices.expectedCount,
    const Landmark(0.5, 0.5, 0.0),
  );

  void placeEye({
    required int iris,
    required int outer,
    required int inner,
    required int top,
    required int bottom,
    required double centreX,
  }) {
    const centreY = 0.45;
    points[outer] = Landmark(centreX - eyeWidth / 2, centreY, 0.0);
    points[inner] = Landmark(centreX + eyeWidth / 2, centreY, 0.0);
    points[iris] = Landmark(
      centreX + offsetX * eyeWidth,
      centreY + offsetY * eyeWidth,
      0.0,
    );
    final halfOpen = opennessFraction * eyeWidth / 2;
    points[top] = Landmark(centreX, centreY - halfOpen, 0.0);
    points[bottom] = Landmark(centreX, centreY + halfOpen, 0.0);
  }

  placeEye(
    iris: FaceMeshIndices.leftIrisCentre,
    outer: FaceMeshIndices.leftEyeOuter,
    inner: FaceMeshIndices.leftEyeInner,
    top: FaceMeshIndices.leftEyeTop,
    bottom: FaceMeshIndices.leftEyeBottom,
    centreX: 0.4,
  );
  placeEye(
    iris: FaceMeshIndices.rightIrisCentre,
    outer: FaceMeshIndices.rightEyeOuter,
    inner: FaceMeshIndices.rightEyeInner,
    top: FaceMeshIndices.rightEyeTop,
    bottom: FaceMeshIndices.rightEyeBottom,
    centreX: 0.6,
  );

  return FaceFrame(timestamp: timestamp, landmarks: points);
}

/// Quadro sem rosto detectável.
///
/// Todos os pontos coincidem, de modo que a largura do olho é nula e
/// [irisOffset] devolve `null` -- o mesmo que acontece quando a criança sai do
/// enquadramento ou vira o rosto de perfil.
FaceFrame faceAbsentFrame({double timestamp = 0.0}) => FaceFrame(
      timestamp: timestamp,
      landmarks: List<Landmark>.filled(
        FaceMeshIndices.expectedCount,
        const Landmark(0.5, 0.5, 0.0),
      ),
    );
