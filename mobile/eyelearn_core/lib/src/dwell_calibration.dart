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
/// **Terceira versão (outubro de 2026): o olho tem de ir até a bolinha.** Só
/// tempo deixava passar quem nem olhava para o celular. A regra nova confere
/// a *direção* do movimento do olho, e não a posição: a partir do segundo
/// alvo, a íris tem de ter saído de onde estava no alvo do centro, para o
/// lado em que a bolinha está (para cima, para baixo, para um lado ou para o
/// outro), por pelo menos [minShift] da largura do olho. Direção é o que dá
/// para saber sem mapa; a distância exata é o que a calibração vai medir.
///
/// - Para cima e para baixo, o sinal é conhecido: olhar para baixo desce a
///   íris na imagem.
/// - Para os lados, depende de a imagem estar espelhada ou não. O primeiro
///   alvo de lado ensina o sinal, e os seguintes têm de concordar com ele.
/// - Só os quadros com o olho na direção certa enchem o alvo; os outros
///   apenas não contam (o alvo não esvazia). É a parte "Kinect", sem a
///   rigidez da primeira versão.
/// - Um alvo que não enche em [giveUpSeconds] é pulado, sem medida. Mais de
///   [maxSkipped] pulados e a calibração recomeça ([DwellEvent.failed]):
///   quem não olha para as bolinhas não passa.
///
/// O cursor provisório volta a existir, mas só depois de três alvos (com
/// menos, o mapa não sabe nem o sinal de cada eixo e o cursor andaria para o
/// lado errado). Ele não decide nada; a tela o mostra só no teste do olhar.
library;

import 'dart:math' as math;

import 'calibration.dart';
import 'face_landmarks.dart';

/// Em que pé está o alvo atual.
enum DwellStatus {
  /// Esperando o olho chegar ao alvo novo.
  settling,

  /// O olho ainda não foi para o lado do alvo.
  searching,

  /// Enchendo.
  filling,

  /// Rosto fora do quadro.
  noFace,

  /// Olhos fechados ou piscando.
  eyesClosed,
}

/// O que aconteceu com o quadro.
enum DwellEvent {
  none,
  targetConfirmed,
  finished,

  /// Alvos demais pulados: o olho não foi até as bolinhas.
  failed,
}

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

  /// Deslocamento mínimo da íris, em fração da largura do olho, para contar
  /// como "foi para o lado da bolinha". Olhar uns 10 graus para o lado move
  /// a íris por volta de 0,07; 0,02 fica acima do tremor da medida (a
  /// mediana dos últimos quadros) e bem abaixo do movimento real.
  final double minShift;

  /// Tempo procurando (rosto visível, olho na direção errada) até pular o
  /// alvo.
  final double giveUpSeconds;

  /// Alvos que podem ser pulados antes de recomeçar.
  final int maxSkipped;

  DwellCalibrator({
    required this.targets,
    this.settleSeconds = 0.5,
    this.collectSeconds = 1.2,
    this.defaultGainX = 40.0,
    this.defaultGainY = 25.0,
    this.maxDiscarded = 2,
    this.minShift = 0.02,
    this.giveUpSeconds = 10,
    this.maxSkipped = 2,
  }) : assert(targets.length >= 3);

  final List<CalibrationSample> _samples = [];
  final List<double> _xs = [], _ys = [];

  /// Últimos deslocamentos, para a mediana que decide a direção.
  final List<double> _recentX = [], _recentY = [];

  /// Deslocamento medido no alvo do centro: o ponto de partida.
  ({double x, double y})? _origin;

  /// Sinal do deslocamento horizontal da íris quando o olhar vai para a
  /// direita da tela; aprendido no primeiro alvo de lado.
  double? _signX;
  double _searching = 0;
  int _skipped = 0;

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

  /// Onde o mapa provisório põe o olhar, em graus; `null` antes de três
  /// alvos confirmados ou sem rosto.
  ({double x, double y})? get cursor => _samples.length >= 3 ? _cursor : null;

  /// Há quanto tempo o alvo atual espera o olho ir para o lado dele.
  double get searchingSeconds => _searching;

  /// Alvos pulados até aqui.
  int get skipped => _skipped;

  List<CalibrationSample> get samples => List.unmodifiable(_samples);

  /// Recomeça do primeiro alvo.
  void reset() {
    _samples.clear();
    _index = 0;
    _map = null;
    _cursor = null;
    _origin = null;
    _signX = null;
    _skipped = 0;
    _startTarget();
  }

  void _startTarget() {
    _collected = 0;
    _sinceShown = 0;
    _xs.clear();
    _ys.clear();
    _recentX.clear();
    _recentY.clear();
    _searching = 0;
    _status = DwellStatus.settling;
  }

  /// Se a mediana dos últimos quadros mostra o olho para o lado do alvo,
  /// em relação ao alvo do centro.
  bool _towardTarget() {
    final origin = _origin;
    if (origin == null || _recentX.length < 3) return origin == null;
    final vx = _median(_recentX) - origin.x;
    final vy = _median(_recentY) - origin.y;
    final first = targets.first;
    final target = targets[_index];
    final dx = target.x - first.x;
    final dy = target.y - first.y;
    if (dy.abs() > 2 && vy * dy.sign < minShift) return false;
    if (dx.abs() > 2) {
      if (vx.abs() < minShift) return false;
      final sign = _signX;
      if (sign != null && vx.sign != sign * dx.sign) return false;
    }
    return true;
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
    _recentX.add(offset.x);
    _recentY.add(offset.y);
    if (_recentX.length > 8) {
      _recentX.removeAt(0);
      _recentY.removeAt(0);
    }

    if (_sinceShown < settleSeconds) {
      _status = DwellStatus.settling;
      return DwellEvent.none;
    }

    if (!_towardTarget()) {
      _status = DwellStatus.searching;
      _searching += dt;
      if (_searching < giveUpSeconds) return DwellEvent.none;
      // Não veio: pula o alvo, sem medida.
      _skipped++;
      _index++;
      _startTarget();
      if (_skipped > maxSkipped) return DwellEvent.failed;
      return done ? DwellEvent.finished : DwellEvent.targetConfirmed;
    }

    _status = DwellStatus.filling;
    _xs.add(offset.x);
    _ys.add(offset.y);
    _collected += dt;
    if (_collected < collectSeconds || _xs.length < 3) return DwellEvent.none;

    final target = targets[_index];
    final sample = CalibrationSample(
      targetX: target.x,
      targetY: target.y,
      offsetX: _median(_xs),
      offsetY: _median(_ys),
    );
    _samples.add(sample);
    final origin = _origin;
    if (origin == null) {
      _origin = (x: sample.offsetX, y: sample.offsetY);
    } else if (_signX == null && (target.x - targets.first.x).abs() > 2) {
      _signX =
          (sample.offsetX - origin.x).sign * (target.x - targets.first.x).sign;
    }
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
