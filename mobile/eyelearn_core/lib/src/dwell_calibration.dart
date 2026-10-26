/// Calibração por tempo de olhar: cada alvo enche enquanto a pessoa olha.
///
/// Primeira versão (outubro de 2026) exigia o olhar *parado* no alvo e, a
/// partir do segundo alvo, *perto* dele pelo mapa provisório. No celular
/// real nenhuma das duas funcionou: a íris medida pela câmera treme mais do
/// que o limiar aceitava, e o mapa provisório, feito com dois ou três alvos,
/// errava o bastante para obrigar a pessoa a olhar *ao lado* da bolinha.
///
/// Agora o alvo enche com o tempo, só enquanto o rosto e os olhos abertos
/// estão no quadro:
///
/// 1. Ao aparecer o alvo, os primeiros [settleSeconds] são descartados: é o
///    tempo de o olho chegar até ele.
/// 2. Depois, cada quadro com rosto e olho aberto enche o alvo; sem rosto ou
///    com o olho fechado, o alvo para (não esvazia).
/// 3. A medida do alvo é a **mediana** dos quadros colhidos, não a média: uma
///    olhada rápida para o lado ou um quadro ruim não a desloca.
///
/// No fim, [fit] descarta até dois alvos que destoam do resto (quem piscou
/// ou olhou para outro lugar justo num alvo) antes de desistir da
/// calibração.
///
/// O cursor provisório continua, só para a pessoa ver onde o aparelho acha
/// que ela olha. Ele não decide mais nada.
library;

import 'dart:math' as math;

import 'calibration.dart';
import 'face_landmarks.dart';

/// Em que pé está o alvo atual.
enum DwellStatus {
  /// Esperando o olho chegar ao alvo novo.
  settling,

  /// Enchendo.
  filling,

  /// Rosto fora do quadro.
  noFace,

  /// Olhos fechados ou piscando.
  eyesClosed,
}

/// O que aconteceu com o quadro.
enum DwellEvent { none, targetConfirmed, finished }

class DwellCalibrator {
  /// Alvos em graus, a partir do centro da tela, na ordem de apresentação.
  final List<({double x, double y})> targets;

  /// Tempo descartado depois que o alvo aparece.
  final double settleSeconds;

  /// Tempo de olhar com rosto visível que enche o alvo.
  final double collectSeconds;

  /// Ganho usado no cursor antes de haver dois alvos, em graus por unidade
  /// de deslocamento. Só desenha o cursor no começo.
  final double defaultGainX;
  final double defaultGainY;

  /// Quantos alvos [fit] pode descartar.
  final int maxDiscarded;

  DwellCalibrator({
    required this.targets,
    this.settleSeconds = 0.5,
    this.collectSeconds = 1.2,
    this.defaultGainX = 40.0,
    this.defaultGainY = 25.0,
    this.maxDiscarded = 2,
  }) : assert(targets.length >= 3);

  final List<CalibrationSample> _samples = [];
  final List<double> _xs = [], _ys = [];

  int _index = 0;
  double _collected = 0;
  double _sinceShown = 0;
  double? _lastTime;
  DwellStatus _status = DwellStatus.settling;
  ({double x, double y})? _cursor;
  _Provisional? _map;

  /// Índice do alvo atual.
  int get index => _index;

  bool get done => _index >= targets.length;

  /// Quanto o alvo atual já encheu, de 0 a 1.
  double get progress => math.min(1, _collected / collectSeconds);

  DwellStatus get status => _status;

  /// Onde o mapa provisório põe o olhar, em graus; `null` antes do primeiro
  /// alvo confirmado ou sem rosto.
  ({double x, double y})? get cursor => _cursor;

  List<CalibrationSample> get samples => List.unmodifiable(_samples);

  /// Recomeça do primeiro alvo.
  void reset() {
    _samples.clear();
    _index = 0;
    _map = null;
    _cursor = null;
    _startTarget();
  }

  void _startTarget() {
    _collected = 0;
    _sinceShown = 0;
    _xs.clear();
    _ys.clear();
    _status = DwellStatus.settling;
  }

  /// Processa um quadro.
  DwellEvent add(FaceFrame frame) {
    if (done) return DwellEvent.none;
    final t = frame.timestamp;
    final last = _lastTime;
    _lastTime = t;
    if (last != null && t <= last) return DwellEvent.none;
    // Um engasgo da câmera não pode encher meio alvo de uma vez.
    final dt = last == null ? 0.0 : math.min(t - last, 0.2);
    _sinceShown += dt;

    final offset = irisOffset(frame);
    if (offset == null) {
      _status = DwellStatus.noFace;
      _cursor = null;
      return DwellEvent.none;
    }
    if (offset.openness < minimumOpenness) {
      _status = DwellStatus.eyesClosed;
      return DwellEvent.none;
    }
    _cursor = _map?.apply(offset.x, offset.y);

    if (_sinceShown < settleSeconds) {
      _status = DwellStatus.settling;
      return DwellEvent.none;
    }

    _status = DwellStatus.filling;
    _xs.add(offset.x);
    _ys.add(offset.y);
    _collected += dt;
    if (_collected < collectSeconds || _xs.length < 3) return DwellEvent.none;

    final target = targets[_index];
    _samples.add(CalibrationSample(
      targetX: target.x,
      targetY: target.y,
      offsetX: _median(_xs),
      offsetY: _median(_ys),
    ));
    _map = _Provisional.fit(_samples, defaultGainX, defaultGainY);
    _index++;
    _startTarget();
    return done ? DwellEvent.finished : DwellEvent.targetConfirmed;
  }

  /// O mapa final.
  ///
  /// Se o ajuste com todos os alvos não for aceitável, tenta sem o alvo que
  /// mais destoa, e de novo, até [maxDiscarded] alvos, enquanto sobrarem
  /// pelo menos seis.
  ///
  /// Throws [CalibrationError] se nem assim houver mapa aceitável, ou se os
  /// alvos forem degenerados.
  GazeCalibration fit() {
    var kept = List.of(_samples);
    var calibration = GazeCalibration.fit(kept);
    for (var discarded = 0;
        !calibration.isAcceptable() &&
            discarded < maxDiscarded &&
            kept.length > 6;
        discarded++) {
      final worst = _worst(calibration, kept);
      kept = [...kept]..removeAt(worst);
      calibration = GazeCalibration.fit(kept);
    }
    if (!calibration.isAcceptable()) {
      throw CalibrationError(
          'erro de ${calibration.residualDegrees.toStringAsFixed(1)}° '
          'mesmo descartando os alvos que destoavam');
    }
    return calibration;
  }

  static int _worst(GazeCalibration c, List<CalibrationSample> samples) {
    var worst = 0;
    var largest = -1.0;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final p = c.apply(s.offsetX, s.offsetY);
      final error = math
          .sqrt(math.pow(p.x - s.targetX, 2) + math.pow(p.y - s.targetY, 2));
      if (error > largest) {
        largest = error;
        worst = i;
      }
    }
    return worst;
  }
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Mapa provisório, só para o cursor.
///
/// Um alvo: só o desvio, com ganho padrão. Dois: ganho e desvio por eixo.
/// Três ou mais: o mapa linear completo, o mesmo da calibração final.
class _Provisional {
  final ({double x, double y}) Function(double ox, double oy) apply;
  _Provisional(this.apply);

  static _Provisional fit(
    List<CalibrationSample> samples,
    double gainX,
    double gainY,
  ) {
    if (samples.length >= 3) {
      try {
        final full = GazeCalibration.fit(samples);
        return _Provisional(full.apply);
      } on CalibrationError {
        // Alvos ainda colineares: cai para o mapa por eixo.
      }
    }
    final ax = _axis([for (final s in samples) (s.offsetX, s.targetX)], gainX);
    final ay = _axis([for (final s in samples) (s.offsetY, s.targetY)], gainY);
    return _Provisional(
        (ox, oy) => (x: ax.$1 * ox + ax.$2, y: ay.$1 * oy + ay.$2));
  }

  /// Ganho e desvio de uma reta pelos pontos; com um ponto só, ou todos na
  /// mesma coluna, o ganho padrão.
  static (double, double) _axis(List<(double, double)> points, double gain) {
    final n = points.length;
    final mo = points.fold(0.0, (s, p) => s + p.$1) / n;
    final mt = points.fold(0.0, (s, p) => s + p.$2) / n;
    var cov = 0.0, varO = 0.0, varT = 0.0;
    for (final (o, t) in points) {
      cov += (o - mo) * (t - mt);
      varO += (o - mo) * (o - mo);
      varT += (t - mt) * (t - mt);
    }
    final slope = varT / n > 1.0 && varO > 1e-12 ? cov / varO : gain;
    return (slope, mt - slope * mo);
  }
}
