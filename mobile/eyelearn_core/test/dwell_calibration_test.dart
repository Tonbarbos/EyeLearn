import 'dart:math' as math;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

/// Mapa "verdadeiro" do olho sintético: graus por unidade de deslocamento.
const _gainX = 36.0;
const _gainY = 22.0;
const _rate = 20.0;

const _targets = [
  (x: 0.0, y: 0.0),
  (x: -10.0, y: -18.0),
  (x: 0.0, y: -18.0),
  (x: 10.0, y: -18.0),
  (x: 10.0, y: 0.0),
  (x: 10.0, y: 18.0),
  (x: 0.0, y: 18.0),
  (x: -10.0, y: 18.0),
  (x: -10.0, y: 0.0),
];

class _Eye {
  final rng = math.Random(3);
  double t = 0;

  /// Ruído do deslocamento, em unidades: 0,02 é cerca de 0,7° -- o tremor
  /// de uma câmera de celular, que a versão anterior não tolerava.
  double noise;
  _Eye({this.noise = 0.02});

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
int _dwell(DwellCalibrator c, _Eye eye,
    {int limit = 300, ({double x, double y})? lookAt}) {
  final start = c.index;
  for (var i = 1; i <= limit; i++) {
    final target = lookAt ?? c.targets[c.index];
    c.add(eye.look(target.x, target.y));
    if (c.index != start || c.done) return i;
  }
  return -1;
}

void main() {
  test('cada alvo leva cerca de 1,7 s (chegar + encher)', () {
    final c = DwellCalibrator(targets: _targets);
    final frames = _dwell(c, _Eye());
    expect(frames / _rate, inInclusiveRange(1.6, 1.9));
    expect(c.index, 1);
  });

  test('olhar tremendo como numa câmera de celular calibra bem', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.03);
    for (var i = 0; i < _targets.length; i++) {
      expect(_dwell(c, eye), greaterThan(0), reason: 'alvo $i');
    }
    final map = c.fit();
    expect(map.isAcceptable(), isTrue);
    final p = map.apply(5 / _gainX, -7 / _gainY);
    expect(p.x, closeTo(5, 1.0));
    expect(p.y, closeTo(-7, 1.0));
  });

  test('o tempo para chegar ao alvo não entra na medida', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0);
    // Primeiros 0,4 s olhando longe; depois, o alvo (o centro).
    for (var i = 0; i < 8; i++) {
      c.add(eye.look(12, 12));
    }
    _dwell(c, eye);
    expect(c.samples.single.offsetX, closeTo(0, 1e-9));
  });

  test('uma olhada para o lado no meio não desloca a medida (mediana)', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0);
    for (var i = 0; i < 18; i++) {
      c.add(eye.look(0, 0));
    }
    for (var i = 0; i < 3; i++) {
      c.add(eye.look(14, -20));
    }
    _dwell(c, eye);
    expect(c.samples.single.offsetX, closeTo(0, 1e-9));
    expect(c.samples.single.offsetY, closeTo(0, 1e-9));
  });

  test('piscar ou sumir pausa o alvo, sem esvaziar', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye();
    for (var i = 0; i < 25; i++) {
      c.add(eye.look(0, 0));
    }
    final before = c.progress;
    expect(before, greaterThan(0.3));
    for (var i = 0; i < 10; i++) {
      c.add(eye.look(0, 0, openness: 0.02));
    }
    expect(c.status, DwellStatus.eyesClosed);
    expect(c.progress, before);
    eye.t += 1 / _rate;
    c.add(faceAbsentFrame(timestamp: eye.t));
    expect(c.status, DwellStatus.noFace);
    expect(c.cursor, isNull);
    expect(c.progress, before);
  });

  test('o cursor aparece depois de dois alvos e mostra onde se olha', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.005);
    _dwell(c, eye);
    c.add(eye.look(0, 0));
    expect(c.cursor, isNull, reason: 'só com o centro o mapa não sabe o sinal');
    _dwell(c, eye);
    c.add(eye.look(-10, 18));
    expect(c.cursor!.x, closeTo(-10, 3));
    expect(c.cursor!.y, closeTo(18, 3));
  });

  test('o deslocamento do olho é medido a partir do centro', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.0);
    expect(c.eyeShift, isNull);
    _dwell(c, eye);
    for (var i = 0; i < 8; i++) {
      c.add(eye.look(-10, -18));
    }
    expect(c.eyeShift!.x, closeTo(-10 / _gainX, 0.001));
    expect(c.eyeShift!.y, closeTo(-18 / _gainY, 0.001));
    expect(c.knowsHorizontal, isFalse);
  });

  test('o alvo só enche quando o olho vai para o lado dele', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.005);
    _dwell(c, eye);
    // Alvo 1 (alto, à esquerda), olhando ainda para o centro: não enche.
    for (var i = 0; i < 100; i++) {
      c.add(eye.look(0, 0));
    }
    expect(c.index, 1);
    expect(c.status, DwellStatus.searching);
    expect(c.progress, 0);
    // Foi até a bolinha: enche.
    expect(_dwell(c, eye), greaterThan(0));
    expect(c.index, 2);
  });

  test('quem não olha para as bolinhas não passa', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.005);
    final events = <DwellEvent>[];
    // Olhando sempre para o mesmo lugar, fora do celular.
    for (var i = 0; i < 20 * 60 && !events.contains(DwellEvent.failed); i++) {
      events.add(c.add(eye.look(30, 5)));
    }
    expect(events, contains(DwellEvent.failed));
    expect(c.skipped, greaterThan(2));
  });

  test('imagem espelhada: o sinal horizontal é aprendido', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.005);
    // Olho cujo deslocamento horizontal tem o sinal trocado.
    FaceFrame mirrored(double x, double y) {
      final f = eye.look(-x, y);
      return f;
    }

    for (var target = 0; target < _targets.length; target++) {
      var frames = 0;
      final start = c.index;
      while (c.index == start && frames++ < 400) {
        final t = _targets[target];
        c.add(mirrored(t.x, t.y));
      }
    }
    expect(c.done, isTrue);
    expect(c.skipped, 0);
    expect(c.fit().isAcceptable(), isTrue);
  });

  test('um alvo errado é descartado no ajuste final', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.005);
    for (var i = 0; i < _targets.length; i++) {
      // No alvo 3 a pessoa olhou para o centro.
      _dwell(c, eye, lookAt: i == 3 ? (x: 0.0, y: 0.0) : null);
    }
    final map = c.fit();
    expect(map.isAcceptable(), isTrue);
    expect(map.apply(10 / _gainX, 0).x, closeTo(10, 1.0));
  });

  test('alvos olhados a esmo não dão calibração', () {
    final c = DwellCalibrator(targets: _targets);
    final eye = _Eye(noise: 0.005);
    final rng = math.Random(9);
    for (var i = 0; i < _targets.length; i++) {
      _dwell(c, eye, lookAt: (
        x: rng.nextDouble() * 20 - 10,
        y: rng.nextDouble() * 36 - 18
      ));
    }
    expect(c.fit, throwsA(isA<CalibrationError>()));
  });
}
