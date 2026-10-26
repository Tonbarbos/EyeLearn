import 'dart:math' as math;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Mapa "verdadeiro" do olho sintético: graus por unidade de deslocamento.
const _gainX = 36.0;
const _gainY = 22.0;
const _rate = 30.0;

const _targets = [
  (x: 0.0, y: 0.0),
  (x: -10.0, y: -18.0),
  (x: 10.0, y: -18.0),
  (x: 10.0, y: 18.0),
  (x: -10.0, y: 18.0),
];

class _Eye {
  final rng = math.Random(3);
  double t = 0;
  double noise;
  _Eye({this.noise = 0.002});

  FaceFrame look(double xDeg, double yDeg,
      {double openness = defaultOpenness}) {
    t += 1 / _rate;
    return syntheticFaceFrame(
      offsetX: xDeg / _gainX + (rng.nextDouble() - 0.5) * 2 * noise,
      offsetY: yDeg / _gainY + (rng.nextDouble() - 0.5) * 2 * noise,
      timestamp: t,
      opennessFraction: openness,
    );
  }
}

/// Olha para o alvo atual até ele ser confirmado; devolve quantos quadros.
int _dwell(DwellCalibrator c, _Eye eye, {int limit = 300}) {
  final start = c.index;
  for (var i = 1; i <= limit; i++) {
    final target = c.targets[c.index];
    c.add(eye.look(target.x, target.y));
    if (c.index != start || c.done) return i;
  }
  return -1;
}

void main() {
  test('olhar parado no alvo confirma em cerca de 1,5 s', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye();
    final frames = _dwell(c, eye);
    expect(frames / _rate, inInclusiveRange(1.4, 1.8));
    expect(c.index, 1);
    expect(c.samples.single.offsetX, closeTo(0, 0.002));
  });

  test('cinco alvos dão um mapa que acerta o olhar', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye();
    for (var i = 0; i < _targets.length; i++) {
      expect(_dwell(c, eye), greaterThan(0), reason: 'alvo $i');
    }
    expect(c.done, isTrue);
    final map = c.fit();
    expect(map.isAcceptable(), isTrue);
    final p = map.apply(5 / _gainX, -7 / _gainY);
    expect(p.x, closeTo(5, 0.3));
    expect(p.y, closeTo(-7, 0.3));
  });

  test('olhar se mexendo não enche', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye();
    for (var i = 0; i < 120; i++) {
      // Varre a tela: nunca fica parado.
      c.add(eye.look(15 * math.sin(i / 3), 10 * math.cos(i / 4)));
    }
    expect(c.index, 0);
    expect(c.status, DwellStatus.moving);
    expect(c.progress, lessThan(0.2));
  });

  test('depois de dois alvos, olhar parado longe do alvo não enche', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye();
    _dwell(c, eye);
    _dwell(c, eye);
    expect(c.index, 2);
    // O alvo 2 é (10, -18); a pessoa fica olhando o canto oposto.
    for (var i = 0; i < 90; i++) {
      c.add(eye.look(-10, 18));
    }
    expect(c.index, 2);
    expect(c.status, DwellStatus.offTarget);
    // Nem depois do tempo de afrouxar.
    for (var i = 0; i < 300; i++) {
      c.add(eye.look(-10, 18));
    }
    expect(c.index, 2);
    // O cursor provisório mostra onde ela está olhando.
    expect(c.cursor!.x, closeTo(-10, 2));
    expect(c.cursor!.y, closeTo(18, 2));
  });

  test('piscar esvazia o alvo, e a medida recomeça', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye();
    for (var i = 0; i < 30; i++) {
      c.add(eye.look(0, 0));
    }
    final before = c.progress;
    expect(before, greaterThan(0.4));
    for (var i = 0; i < 10; i++) {
      c.add(eye.look(0, 0, openness: 0.02));
    }
    expect(c.status, DwellStatus.eyesClosed);
    expect(c.progress, lessThan(before));
  });

  test('preso num alvo, afrouxa depois de alguns segundos', () {
    // Ruído alto demais para o limiar normal, mas não para o afrouxado.
    final c = DwellCalibrator(targets: _targets, stabilityThreshold: 0.004);
    final eye = _Eye(noise: 0.0085);
    final frames = _dwell(c, eye, limit: 600);
    expect(frames, greaterThan(0));
    expect(frames / _rate, greaterThan(6));
  });

  test('sem rosto, sem cursor', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye();
    _dwell(c, eye);
    c.add(eye.look(0, 0));
    expect(c.cursor, isNotNull);
    eye.t += 1 / _rate;
    c.add(faceAbsentFrame(timestamp: eye.t));
    expect(c.cursor, isNull);
    expect(c.status, DwellStatus.noFace);
  });
}
