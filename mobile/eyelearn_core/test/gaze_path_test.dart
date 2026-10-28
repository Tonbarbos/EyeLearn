import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:test/test.dart';

void main() {
  final trace = GazeTrace(
    t: [for (var i = 0; i < 60; i++) 10 + i / 30],
    x: [for (var i = 0; i < 60; i++) i == 31 ? double.nan : i / 7],
    y: [for (var i = 0; i < 60; i++) -i / 3],
  );

  test('reduz a 15 amostras por segundo, arredondado, a partir de zero', () {
    final path = GazePath.fromTrace(trace);
    expect(path.t.length, 30);
    expect(path.t.first, 0);
    expect(path.duration, closeTo(1.93, 0.01));
    expect(path.x[1], 0.3); // 2/7, arredondado a 0,1
  });

  test('amostra perdida vira null e volta igual do JSON', () {
    final path = GazePath.fromTrace(trace, rateHz: 30);
    expect(path.x[31], isNull);
    final back = GazePath.fromJson(path.toJson());
    expect(back.t, path.t);
    expect(back.x, path.x);
    expect(back.y, path.y);
  });

  test('posição num instante e o rastro', () {
    final path = GazePath.fromTrace(trace, rateHz: 30);
    expect(path.at(0.5)!.x, closeTo(15 / 7, 0.06));
    // Na amostra perdida, vale a anterior, se for recente.
    expect(path.at(31 / 30 + 0.001)!.x, closeTo(30 / 7, 0.06));
    expect(path.between(0.5, 1.0).length, 16);
  });

  test('a sessão leva o percurso e o lê de volta', () {
    final session = Session(
      participantCode: 'AAA222',
      task: 'text',
      startedAt: DateTime.utc(2026, 10, 28),
      durationSeconds: 2,
      samplingRateHz: 30,
      validSampleRatio: 0.9,
      features: const {},
      score: 0,
      modelMetadata: const {},
      gazePath: GazePath.fromTrace(trace),
    );
    final back = Session.fromJsonString(session.toJsonString());
    expect(back.gazePath!.t, session.gazePath!.t);
  });
}
