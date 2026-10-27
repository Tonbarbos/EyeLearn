import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

GazeTrace _trace(List<(double, double)> points, {double rate = 20}) =>
    GazeTrace(
      t: [for (var i = 0; i < points.length; i++) i / rate],
      x: [for (final p in points) p.$1],
      y: [for (final p in points) p.$2],
    );

void main() {
  test('o tempo cai na célula onde o olhar estava', () {
    // 2 s no centro-esquerda do topo, 1 s no canto de baixo à direita.
    final trace = _trace([
      for (var i = 0; i < 40; i++) (-10.0, -20.0),
      for (var i = 0; i < 21; i++) (13.0, 23.0),
    ]);
    final map = GazeHeatmap.fromTrace(trace);
    expect(map.seconds, hasLength(12 * 16));
    expect(map.seconds[1 * 12 + 1], closeTo(2.0, 0.06));
    expect(map.seconds[15 * 12 + 11], closeTo(1.0, 0.06));
    expect(map.total, closeTo(3.0, 0.06));
  });

  test('amostra perdida ou fora da tela não conta', () {
    final trace = _trace([
      (0.0, 0.0),
      (double.nan, double.nan),
      (40.0, 0.0),
      (0.0, 0.0),
    ]);
    expect(GazeHeatmap.fromTrace(trace).total, closeTo(0.05, 1e-9));
  });

  test('um buraco na captura não pinta uma célula inteira', () {
    final map = GazeHeatmap.fromTrace(
        GazeTrace(t: [0, 5, 5.05], x: [0, 0, 0], y: [0, 0, 0]));
    expect(map.total, closeTo(0.25, 1e-9));
  });

  test('fração do tempo no texto', () {
    final trace = _trace([
      for (var i = 0; i < 31; i++) (0.0, -5.0),
      for (var i = 0; i < 10; i++) (0.0, 20.0),
    ]);
    final map =
        GazeHeatmap.fromTrace(trace, textArea: [-12.0, -10.0, 12.0, 0.0]);
    expect(map.onTextFraction, closeTo(0.75, 0.03));
  });

  test('vai e volta pelo JSON da sessão', () {
    final map = GazeHeatmap.fromTrace(_trace([(1.0, 1.0), (1.0, 1.0)]),
        textArea: [-1.0, -2.0, 3.0, 4.0]);
    final again = GazeHeatmap.fromJson(map.toJson());
    expect(again.seconds, map.seconds);
    expect(again.textArea, [-1.0, -2.0, 3.0, 4.0]);
  });
}
