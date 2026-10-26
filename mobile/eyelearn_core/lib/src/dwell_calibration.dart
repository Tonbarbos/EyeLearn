/// Calibração por permanência: o alvo só enche se o olhar ficar nele.
///
/// A calibração anterior media um intervalo fixo depois de cada alvo aparecer,
/// olhasse a criança para ele ou não. Uma piscada, uma olhada para o lado ou
/// uma sacada atrasada entravam na média, e o mapa saía torto.
///
/// Aqui cada alvo funciona como o botão do Kinect, em que se segura a mão
/// parada até ele encher: o alvo enche enquanto o olhar está **parado** (a
/// íris quase não se mexe numa janela curta) e, depois que já há um mapa
/// provisório, **perto do alvo**. Se o olhar sai ou o rosto some, o alvo
/// esvazia. A medida do alvo é a média só desses quadros.
///
/// Desde o primeiro alvo confirmado já existe um mapa provisório, que
/// melhora a cada alvo. É ele que desenha o cursor na tela de calibração,
/// para a pessoa ver onde o aparelho acha que ela está olhando.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'calibration.dart';
import 'face_landmarks.dart';

/// Em que pé está o alvo atual.
enum DwellStatus {
  /// Enchendo: olhar parado e no alvo.
  filling,

  /// Olhar se mexendo.
  moving,

  /// Olhar parado, mas longe do alvo (pelo mapa provisório).
  offTarget,

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

  /// Quanto tempo o olhar precisa ficar no alvo para confirmá-lo.
  final double dwellSeconds;

  /// Janela em que se mede se o olhar está parado.
  final double stabilityWindowSeconds;

  /// Desvio padrão máximo do deslocamento da íris, na janela, para contar
  /// como parado. Adimensional; da ordem de um grau no aparelho típico.
  final double stabilityThreshold;

  /// Distância máxima ao alvo, em graus, pelo mapa provisório.
  ///
  /// Generosa de propósito: o mapa provisório, com dois ou três alvos, erra
  /// alguns graus, e uma exigência apertada travaria a calibração justo
  /// quando a pessoa está olhando certo.
  final double radiusDegrees;

  /// Depois deste tempo no mesmo alvo sem confirmar, o raio dobra e a
  /// exigência de estabilidade afrouxa: melhor uma medida um pouco pior que
  /// uma criança presa num alvo. Olhar longe do alvo continua não contando.
  final double relaxAfterSeconds;

  /// Ganho usado no mapa antes de haver dois alvos, em graus por unidade de
  /// deslocamento. Só desenha o cursor no começo; não entra em medida.
  final double defaultGainX;
  final double defaultGainY;

  DwellCalibrator({
    required this.targets,
    this.dwellSeconds = 1.5,
    this.stabilityWindowSeconds = 0.3,
    this.stabilityThreshold = 0.02,
    this.radiusDegrees = 8.0,
    this.relaxAfterSeconds = 6.0,
    this.defaultGainX = 40.0,
    this.defaultGainY = 25.0,
  }) : assert(targets.length >= 3);

  final _window = ListQueue<({double t, double x, double y})>();
  final List<CalibrationSample> _samples = [];

  int _index = 0;
  double _progress = 0;
  double _sumX = 0, _sumY = 0;
  int _count = 0;
  double? _lastTime;
  double _targetElapsed = 0;
  DwellStatus _status = DwellStatus.moving;
  ({double x, double y})? _cursor;
  _Provisional? _map;

  /// Índice do alvo atual.
  int get index => _index;

  bool get done => _index >= targets.length;

  /// Quanto o alvo atual já encheu, de 0 a 1.
  double get progress => _progress;

  DwellStatus get status => _status;

  /// Onde o mapa provisório põe o olhar, em graus; `null` antes do primeiro
  /// alvo confirmado ou sem rosto.
  ({double x, double y})? get cursor => _cursor;

  List<CalibrationSample> get samples => List.unmodifiable(_samples);

  /// Se o alvo atual já afrouxou as exigências.
  bool get relaxed => _targetElapsed > relaxAfterSeconds;

  /// Recomeça do primeiro alvo.
  void reset() {
    _samples.clear();
    _index = 0;
    _map = null;
    _cursor = null;
    _startTarget();
  }

  void _startTarget() {
    _progress = 0;
    _sumX = 0;
    _sumY = 0;
    _count = 0;
    _targetElapsed = 0;
    _window.clear();
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
    _targetElapsed += dt;

    final offset = irisOffset(frame);
    if (offset == null) return _drain(dt, DwellStatus.noFace);
    if (offset.openness < minimumOpenness) {
      return _drain(dt, DwellStatus.eyesClosed);
    }

    _window.addLast((t: t, x: offset.x, y: offset.y));
    while (_window.isNotEmpty && t - _window.first.t > stabilityWindowSeconds) {
      _window.removeFirst();
    }
    _cursor = _map?.apply(offset.x, offset.y);

    final threshold = relaxed ? stabilityThreshold * 1.6 : stabilityThreshold;
    if (_window.length < 3 || _spread() > threshold) {
      return _drain(dt, DwellStatus.moving);
    }

    // Com dois alvos já há mapa nos dois eixos: a partir daí, olhar parado
    // longe do alvo não conta.
    final target = targets[_index];
    final cursor = _cursor;
    if (_samples.length >= 2 && cursor != null) {
      final distance = math.sqrt(
          math.pow(cursor.x - target.x, 2) + math.pow(cursor.y - target.y, 2));
      final radius = relaxed ? radiusDegrees * 2 : radiusDegrees;
      if (distance > radius) return _drain(dt, DwellStatus.offTarget);
    }

    _status = DwellStatus.filling;
    _sumX += offset.x;
    _sumY += offset.y;
    _count++;
    _progress = math.min(1, _progress + dt / dwellSeconds);
    if (_progress < 1) return DwellEvent.none;

    _samples.add(CalibrationSample(
      targetX: target.x,
      targetY: target.y,
      offsetX: _sumX / _count,
      offsetY: _sumY / _count,
    ));
    _map = _Provisional.fit(_samples, defaultGainX, defaultGainY);
    _index++;
    _startTarget();
    return done ? DwellEvent.finished : DwellEvent.targetConfirmed;
  }

  /// O alvo esvazia duas vezes mais rápido do que enche. Ao esvaziar de
  /// todo, a medida recomeça: o que entrou antes era de outro momento.
  DwellEvent _drain(double dt, DwellStatus status) {
    _status = status;
    if (status == DwellStatus.noFace || status == DwellStatus.eyesClosed) {
      _window.clear();
      if (status == DwellStatus.noFace) _cursor = null;
    }
    _progress = math.max(0, _progress - 2 * dt / dwellSeconds);
    if (_progress == 0) {
      _sumX = 0;
      _sumY = 0;
      _count = 0;
    }
    return DwellEvent.none;
  }

  /// Maior desvio padrão entre os dois eixos, na janela.
  double _spread() {
    var mx = 0.0, my = 0.0;
    for (final p in _window) {
      mx += p.x;
      my += p.y;
    }
    mx /= _window.length;
    my /= _window.length;
    var vx = 0.0, vy = 0.0;
    for (final p in _window) {
      vx += (p.x - mx) * (p.x - mx);
      vy += (p.y - my) * (p.y - my);
    }
    return math.sqrt(math.max(vx, vy) / _window.length);
  }

  /// O mapa final, com todos os alvos.
  ///
  /// Throws [CalibrationError] se faltarem alvos ou forem degenerados.
  GazeCalibration fit() => GazeCalibration.fit(_samples);
}

/// Mapa provisório, só para o cursor e para a exigência de distância.
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

  /// Ganho e desvio de uma reta pelos pontos; com um ponto só, ou todos no
  /// mesmo lugar, o ganho padrão.
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
    // Alvos todos na mesma coluna (ou linha) não dizem nada sobre o ganho
    // nesse eixo: a reta sairia do ruído.
    final slope = varT / n > 1.0 && varO > 1e-12 ? cov / varO : gain;
    return (slope, mt - slope * mo);
  }
}
