/// Posição do rosto diante da câmera: se dá para medir o olhar daqui.
///
/// O olhar é medido pela posição da íris dentro do olho, calibrada com o
/// rosto onde estava na calibração. Duas coisas estragam a medida, e nenhuma
/// delas aparece no deslocamento da íris:
///
/// - **Começar mal posicionado.** Rosto longe (o olho ocupa poucos pixels),
///   visto de baixo (celular baixo demais: as pálpebras cobrem a íris), virado,
///   no escuro ou com reflexo nos óculos. [assessPosition] diz o que está
///   errado, para a tela pedir a correção antes de calibrar.
/// - **Sair da posição depois de calibrar.** A calibração vale para a posição
///   em que foi feita; inclinar o celular ou aproximar o rosto muda a relação
///   entre a íris e a tela. [PostureReference] guarda a posição da calibração
///   e diz quando a leitura saiu dela.
///
/// Os limites são estimativas para celulares comuns com a câmera frontal a
/// 480x360 ou 360x480 (ver [PositionLimits]); a tela "Testar o olhar" mostra
/// os números ao vivo, para ajustá-los num aparelho de verdade.
library;

import 'dart:math' as math;

import 'face_landmarks.dart';

/// O que há de errado com a posição, na ordem em que vale a pena corrigir.
enum PositionIssue {
  /// Nenhum rosto no quadro.
  noFace,

  /// Rosto perto da borda da imagem: um movimento pequeno o tira do quadro.
  offCentre,

  /// Longe demais: o olho ocupa poucos pixels e a íris anda menos que o ruído.
  tooFar,

  /// Perto demais: o rosto sai do quadro ao menor movimento.
  tooClose,

  /// Celular deitado: a câmera vê o rosto de baixo.
  phoneFlat,

  /// Rosto visto de cima ou de baixo (celular alto ou baixo demais).
  tiltedUpDown,

  /// Rosto virado para o lado.
  turned,

  /// Cabeça inclinada de lado.
  leaning,

  /// Pouca luz nos olhos.
  dark,

  /// Reflexo sobre os olhos, quase sempre nos óculos.
  glare,

  /// Olhos fechados ou quase.
  eyesClosed,
}

/// Limites da posição aceitável. Os padrões são estimativas (ver o
/// cabeçalho); ficam aqui, juntos, para serem ajustados num lugar só.
class PositionLimits {
  /// Centro dos olhos, em fração da imagem, longe das bordas.
  final double edgeMargin;

  /// Largura do olho (canto a canto), em pixels da câmera. Um olho de uns
  /// 3 cm ocupa por volta de 1100/d pixels a d centímetros, nas duas
  /// orientações: 20 px é uns 55 cm; 60 px, uns 18 cm.
  final double minEyeWidthPx;
  final double maxEyeWidthPx;

  /// Rotação da cabeça em relação à câmera, em graus.
  final double maxYaw;
  final double maxPitch;
  final double maxRoll;

  /// Brilho médio mínimo da região dos olhos (0 a 255).
  final double minEyeLuma;

  /// Fração máxima da região dos olhos estourada de branco.
  final double maxGlare;

  /// Inclinação mínima do aparelho: abaixo disso ele está quase deitado.
  final double minDeviceTilt;

  const PositionLimits({
    this.edgeMargin = 0.15,
    this.minEyeWidthPx = 20,
    this.maxEyeWidthPx = 60,
    this.maxYaw = 20,
    this.maxPitch = 25,
    this.maxRoll = 15,
    this.minEyeLuma = 50,
    this.maxGlare = 0.04,
    this.minDeviceTilt = 20,
  });
}

/// A posição do rosto num quadro, no que interessa à medida do olhar.
class Posture {
  /// Centro entre os dois olhos, em fração da imagem.
  final double centreX;
  final double centreY;

  /// Largura média dos olhos em pixels da câmera; `null` sem o tamanho da
  /// imagem.
  final double? eyeWidthPx;

  /// Rotação da cabeça em graus (ver [FrameConditions]). A inclinação de
  /// lado sai dos pontos quando a captura não a mede.
  final double? yaw;
  final double? pitch;
  final double? roll;

  final double openness;
  final double? eyeLuma;
  final double? glare;
  final double? deviceTilt;

  const Posture({
    required this.centreX,
    required this.centreY,
    required this.openness,
    this.eyeWidthPx,
    this.yaw,
    this.pitch,
    this.roll,
    this.eyeLuma,
    this.glare,
    this.deviceTilt,
  });

  /// A posição no quadro, ou `null` se não há rosto.
  static Posture? of(FaceFrame frame) {
    final offset = irisOffset(frame);
    if (offset == null) return null;
    final p = frame.landmarks;
    final c = frame.conditions;
    final w = c?.imageWidth;
    final h = c?.imageHeight;

    final leftCentre =
        _mid(p[FaceMeshIndices.leftEyeOuter], p[FaceMeshIndices.leftEyeInner]);
    final rightCentre = _mid(
        p[FaceMeshIndices.rightEyeOuter], p[FaceMeshIndices.rightEyeInner]);

    double? eyeWidthPx;
    double? roll = c?.headRoll;
    if (w != null && h != null && w > 0 && h > 0) {
      double px(Landmark a, Landmark b) => math
          .sqrt(math.pow((a.x - b.x) * w, 2) + math.pow((a.y - b.y) * h, 2));
      eyeWidthPx = (px(p[FaceMeshIndices.leftEyeOuter],
                  p[FaceMeshIndices.leftEyeInner]) +
              px(p[FaceMeshIndices.rightEyeOuter],
                  p[FaceMeshIndices.rightEyeInner])) /
          2;
      // Sem a pose da captura, a inclinação de lado é o ângulo da linha
      // entre os olhos.
      roll ??= math.atan2(
            (rightCentre.$2 - leftCentre.$2) * h,
            ((rightCentre.$1 - leftCentre.$1) * w).abs(),
          ) *
          180 /
          math.pi;
    }

    return Posture(
      centreX: (leftCentre.$1 + rightCentre.$1) / 2,
      centreY: (leftCentre.$2 + rightCentre.$2) / 2,
      openness: offset.openness,
      eyeWidthPx: eyeWidthPx,
      yaw: c?.headYaw,
      pitch: c?.headPitch,
      roll: roll,
      eyeLuma: c?.eyeLuma,
      glare: c?.glare,
      deviceTilt: c?.deviceTilt,
    );
  }

  static (double, double) _mid(Landmark a, Landmark b) =>
      ((a.x + b.x) / 2, (a.y + b.y) / 2);
}

/// O que há de errado com a posição neste quadro, do mais para o menos
/// importante. Vazia quando está tudo bem. O que a captura não mede não é
/// cobrado.
List<PositionIssue> assessPosition(
  FaceFrame? frame, {
  PositionLimits limits = const PositionLimits(),
}) {
  final posture = frame == null ? null : Posture.of(frame);
  if (posture == null) return const [PositionIssue.noFace];
  return postureIssues(posture, limits: limits);
}

List<PositionIssue> postureIssues(
  Posture p, {
  PositionLimits limits = const PositionLimits(),
}) {
  final m = limits.edgeMargin;
  bool over(double? value, double limit) =>
      value != null && value.abs() > limit;
  final eye = p.eyeWidthPx;
  return [
    if (p.centreX < m ||
        p.centreX > 1 - m ||
        p.centreY < m ||
        p.centreY > 1 - m)
      PositionIssue.offCentre,
    if (eye != null && eye < limits.minEyeWidthPx) PositionIssue.tooFar,
    if (eye != null && eye > limits.maxEyeWidthPx) PositionIssue.tooClose,
    if (p.deviceTilt != null && p.deviceTilt!.abs() < limits.minDeviceTilt)
      PositionIssue.phoneFlat,
    if (over(p.pitch, limits.maxPitch)) PositionIssue.tiltedUpDown,
    if (over(p.yaw, limits.maxYaw)) PositionIssue.turned,
    if (over(p.roll, limits.maxRoll)) PositionIssue.leaning,
    if (p.eyeLuma != null && p.eyeLuma! < limits.minEyeLuma) PositionIssue.dark,
    if (p.glare != null && p.glare! > limits.maxGlare) PositionIssue.glare,
    if (p.openness < minimumOpenness) PositionIssue.eyesClosed,
  ];
}

/// Problemas que estragam a calibração: com eles, a calibração espera em vez
/// de medir. Luz e reflexo só pioram a medida, e já foram cobrados antes.
const Set<PositionIssue> blockingIssues = {
  PositionIssue.noFace,
  PositionIssue.offCentre,
  PositionIssue.tooFar,
  PositionIssue.tooClose,
  PositionIssue.phoneFlat,
  PositionIssue.tiltedUpDown,
  PositionIssue.turned,
  PositionIssue.leaning,
};

/// A posição em que a calibração foi feita, para saber quando a leitura
/// saiu dela.
class PostureReference {
  final double centreX;
  final double centreY;
  final double? eyeWidthPx;
  final double? yaw;
  final double? pitch;
  final double? roll;
  final double? deviceTilt;

  /// Quanto cada medida pode mudar antes de a calibração deixar de valer.
  /// Estimativas: uns 10 graus de cabeça já movem o olhar estimado em alguns
  /// graus, e 20% na largura do olho é aproximar ou afastar uns 7 cm a 35 cm.
  static const double maxCentreShift = 0.15;
  static const double maxScaleChange = 0.2;
  static const double maxAngleChange = 12;
  static const double maxTiltChange = 15;

  const PostureReference({
    required this.centreX,
    required this.centreY,
    this.eyeWidthPx,
    this.yaw,
    this.pitch,
    this.roll,
    this.deviceTilt,
  });

  /// A mediana de cada medida, ou `null` sem posições.
  static PostureReference? fromPostures(List<Posture> postures) {
    if (postures.isEmpty) return null;
    double? median(double? Function(Posture) pick) {
      final values = [
        for (final p in postures)
          if (pick(p) case final v?) v
      ]..sort();
      if (values.isEmpty) return null;
      final mid = values.length ~/ 2;
      return values.length.isOdd
          ? values[mid]
          : (values[mid - 1] + values[mid]) / 2;
    }

    return PostureReference(
      centreX: median((p) => p.centreX)!,
      centreY: median((p) => p.centreY)!,
      eyeWidthPx: median((p) => p.eyeWidthPx),
      yaw: median((p) => p.yaw),
      pitch: median((p) => p.pitch),
      roll: median((p) => p.roll),
      deviceTilt: median((p) => p.deviceTilt),
    );
  }

  /// Se [p] saiu da posição da calibração.
  bool isOutOf(Posture p) {
    bool moved(double? now, double? then, double limit) =>
        now != null && then != null && (now - then).abs() > limit;
    final eye = p.eyeWidthPx;
    final refEye = eyeWidthPx;
    return (p.centreX - centreX).abs() > maxCentreShift ||
        (p.centreY - centreY).abs() > maxCentreShift ||
        (eye != null &&
            refEye != null &&
            refEye > 0 &&
            (eye / refEye - 1).abs() > maxScaleChange) ||
        moved(p.yaw, yaw, maxAngleChange) ||
        moved(p.pitch, pitch, maxAngleChange) ||
        moved(p.roll, roll, maxAngleChange) ||
        moved(p.deviceTilt, deviceTilt, maxTiltChange);
  }
}

/// Acompanha a leitura: quanto tempo ela passou fora da posição da
/// calibração, e se está fora agora (por mais de [grace] segundos, para um
/// movimento rápido não acender aviso).
class PostureMonitor {
  final PostureReference reference;
  final double grace;

  PostureMonitor(this.reference, {this.grace = 1.0});

  double? _last;
  double _outSince = -1;
  double _outSeconds = 0;
  double _totalSeconds = 0;
  bool _out = false;

  /// Fora da posição há mais de [grace] segundos.
  bool get isOut => _out;

  /// Fração do tempo fora da posição (contando só o que passou de [grace]).
  double get outRatio => _totalSeconds == 0 ? 0 : _outSeconds / _totalSeconds;

  /// Processa um quadro. Quadro sem rosto não conta para nenhum lado: a
  /// falta de rosto já é medida pela qualidade da gravação.
  void add(FaceFrame frame) {
    final t = frame.timestamp;
    final last = _last;
    _last = t;
    final dt = last == null ? 0.0 : math.min(math.max(t - last, 0.0), 0.2);
    final posture = Posture.of(frame);
    if (posture == null) return;
    _totalSeconds += dt;
    if (reference.isOutOf(posture)) {
      if (_outSince < 0) _outSince = t;
      _out = t - _outSince >= grace;
      if (_out) _outSeconds += dt;
    } else {
      _outSince = -1;
      _out = false;
    }
  }
}
