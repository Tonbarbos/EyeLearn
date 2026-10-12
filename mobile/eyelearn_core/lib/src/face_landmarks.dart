/// Pontos do rosto vindos do canal nativo, e o deslocamento da íris.
///
/// O MediaPipe Face Landmarker entrega 478 pontos por quadro, dos quais os 10
/// últimos descrevem as duas íris. O lado nativo não faz conta: entrega os
/// pontos que interessam e deixa o cálculo aqui, em Dart, onde ele pode ser
/// testado sem emulador.
library;

import 'dart:math' as math;

/// Índices do MediaPipe Face Landmarker usados na estimativa.
///
/// Os números são do modelo com refinamento de íris (478 pontos). Sem esse
/// refinamento o modelo entrega 468 pontos e não há centro de íris -- só pose
/// de cabeça, que não basta para estimar olhar.
class FaceMeshIndices {
  /// Centro da íris esquerda (do ponto de vista da imagem).
  static const int leftIrisCentre = 468;

  /// Centro da íris direita.
  static const int rightIrisCentre = 473;

  /// Canto externo e interno do olho esquerdo.
  static const int leftEyeOuter = 33;
  static const int leftEyeInner = 133;

  /// Canto externo e interno do olho direito.
  static const int rightEyeOuter = 263;
  static const int rightEyeInner = 362;

  /// Pálpebras do olho esquerdo, para medir a abertura.
  static const int leftEyeTop = 159;
  static const int leftEyeBottom = 145;

  /// Pálpebras do olho direito.
  static const int rightEyeTop = 386;
  static const int rightEyeBottom = 374;

  /// Quantidade de pontos que o modelo com íris entrega.
  static const int expectedCount = 478;
}

/// Um ponto do rosto, em coordenadas normalizadas da imagem.
class Landmark {
  /// Horizontal, de 0 a 1 da esquerda para a direita da imagem.
  final double x;

  /// Vertical, de 0 a 1 de cima para baixo.
  final double y;

  /// Profundidade relativa, na escala do próprio modelo.
  final double z;

  const Landmark(this.x, this.y, this.z);
}

/// Um quadro de pontos do rosto.
class FaceFrame {
  /// Instante do quadro, em segundos desde o início da gravação.
  final double timestamp;

  final List<Landmark> landmarks;

  const FaceFrame({required this.timestamp, required this.landmarks});

  /// Monta o quadro a partir do mapa que o canal nativo envia.
  ///
  /// Throws [FormatException] quando a quantidade de pontos não é a do modelo
  /// com refinamento de íris: sem íris não há como estimar olhar, e seguir
  /// adiante produziria um percurso que só reflete movimento de cabeça.
  factory FaceFrame.fromChannel(Map<Object?, Object?> payload) {
    final points = payload['landmarks'] as List<Object?>?;
    if (points == null) {
      throw const FormatException('quadro sem pontos do rosto');
    }
    if (points.length < FaceMeshIndices.expectedCount) {
      throw FormatException(
        'o modelo entregou ${points.length} pontos; são necessários '
        '${FaceMeshIndices.expectedCount}. O refinamento de íris está '
        'desligado no lado nativo?',
      );
    }

    return FaceFrame(
      timestamp: (payload['timestamp'] as num).toDouble(),
      landmarks: [
        for (final point in points)
          Landmark(
            ((point as List<Object?>)[0] as num).toDouble(),
            (point[1] as num).toDouble(),
            (point[2] as num).toDouble(),
          ),
      ],
    );
  }
}

/// Deslocamento normalizado da íris, e a qualidade da medida.
class IrisOffset {
  /// Deslocamento horizontal, adimensional. Positivo para a direita da tela.
  final double x;

  /// Deslocamento vertical, adimensional. Positivo para baixo.
  final double y;

  /// Abertura média dos olhos, relativa à largura do olho.
  ///
  /// Serve para detectar piscada: durante uma piscada o centro da íris que o
  /// modelo reporta é extrapolado, e a posição não corresponde a olhar nenhum.
  final double openness;

  const IrisOffset({
    required this.x,
    required this.y,
    required this.openness,
  });
}

/// Abertura mínima para considerar o olho aberto.
///
/// A razão entre a abertura vertical e a largura do olho fica em torno de 0,3
/// com o olho aberto e cai a quase zero na piscada. O piso de 0,12 fica abaixo
/// de um olho semiaberto e acima de uma piscada completa.
const double minimumOpenness = 0.12;

/// Calcula o deslocamento da íris a partir dos pontos do rosto.
///
/// O deslocamento é a posição da íris dentro da órbita, normalizada pela
/// largura do olho. Normalizar pela largura do olho é o que remove, em primeira
/// ordem, a distância ao aparelho: afastar o celular encolhe a íris e a órbita
/// na mesma proporção, e a razão entre as duas não muda.
///
/// O que a normalização **não** remove é a inclinação da cabeça nem a anatomia
/// individual. Disso cuida a calibração, em `GazeCalibration`.
///
/// As medidas dos dois olhos são promediadas. Um olho só daria metade do sinal
/// e ficaria à mercê de oclusão parcial, que acontece sempre que a criança vira
/// um pouco a cabeça.
IrisOffset? irisOffset(FaceFrame frame) {
  final points = frame.landmarks;

  final left = _eyeOffset(
    points,
    irisIndex: FaceMeshIndices.leftIrisCentre,
    outerIndex: FaceMeshIndices.leftEyeOuter,
    innerIndex: FaceMeshIndices.leftEyeInner,
    topIndex: FaceMeshIndices.leftEyeTop,
    bottomIndex: FaceMeshIndices.leftEyeBottom,
  );
  final right = _eyeOffset(
    points,
    irisIndex: FaceMeshIndices.rightIrisCentre,
    outerIndex: FaceMeshIndices.rightEyeOuter,
    innerIndex: FaceMeshIndices.rightEyeInner,
    topIndex: FaceMeshIndices.rightEyeTop,
    bottomIndex: FaceMeshIndices.rightEyeBottom,
  );

  if (left == null && right == null) return null;

  final available = [
    if (left != null) left,
    if (right != null) right,
  ];

  var sumX = 0.0;
  var sumY = 0.0;
  var sumOpenness = 0.0;
  for (final eye in available) {
    sumX += eye.x;
    sumY += eye.y;
    sumOpenness += eye.openness;
  }

  return IrisOffset(
    x: sumX / available.length,
    y: sumY / available.length,
    openness: sumOpenness / available.length,
  );
}

/// Deslocamento de um olho, ou `null` se a geometria for degenerada.
IrisOffset? _eyeOffset(
  List<Landmark> points, {
  required int irisIndex,
  required int outerIndex,
  required int innerIndex,
  required int topIndex,
  required int bottomIndex,
}) {
  final iris = points[irisIndex];
  final outer = points[outerIndex];
  final inner = points[innerIndex];
  final top = points[topIndex];
  final bottom = points[bottomIndex];

  final width = _distance(outer, inner);
  // Olho de largura nula significa rosto de perfil ou detecção falhada: a
  // divisão daria infinito e contaminaria o percurso.
  if (width <= 1e-6) return null;

  final centreX = (outer.x + inner.x) / 2.0;
  final centreY = (outer.y + inner.y) / 2.0;

  return IrisOffset(
    x: (iris.x - centreX) / width,
    y: (iris.y - centreY) / width,
    openness: _distance(top, bottom) / width,
  );
}

double _distance(Landmark a, Landmark b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}
