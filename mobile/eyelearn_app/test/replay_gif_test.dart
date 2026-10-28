import 'dart:io';
import 'dart:math' as math;

import 'package:eyelearn_app/src/activity/passages.dart';
import 'package:eyelearn_app/src/teacher/replay_gif.dart';
import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Leitura sintética: o olhar varre seis linhas, com uma piscada, uma
/// olhada para fora do celular (à direita, de 6 a 7,5 s) e o rosto fora da
/// câmera (de 9 a 10 s).
GazePath _reading() {
  final t = <double>[], x = <double>[], y = <double>[];
  final state = <GazeSampleState>[];
  for (var i = 0; i < 30 * 12; i++) {
    final s = i / 30;
    final line = (s / 2).floor();
    t.add(s);
    final blink = s > 5 && s < 5.2;
    final away = s >= 6 && s < 7.5;
    final noFace = s >= 9 && s < 10;
    x.add(away ? 32 : -9 + 9 * (s % 2));
    y.add(away ? -4 : -8 + 2.4 * line + 0.3 * math.sin(s * 9));
    state.add(blink
        ? GazeSampleState.eyesClosed
        : noFace
            ? GazeSampleState.noFace
            : GazeSampleState.gaze);
  }
  return GazePath.sample(t: t, x: x, y: y, state: state);
}

void main() {
  test('o GIF tem cabeçalho, paleta, os quadros e o fim', () {
    final gif = replayGif(
      path: _reading(),
      textArea: [-10, -9, 10, 6],
    );
    expect(String.fromCharCodes(gif.sublist(0, 6)), 'GIF89a');
    expect(gif.last, 0x3B);
    // 12 s a 4x e 10 quadros por segundo: 30 quadros, mais o último.
    final frames = [
      for (var i = 0; i < gif.length - 1; i++)
        if (gif[i] == 0x21 && gif[i + 1] == 0xF9) i
    ];
    expect(frames.length, 31);
    final out = Platform.environment['EYELEARN_GIF_OUT'];
    if (out != null) File(out).writeAsBytesSync(gif);
  });

  test('leitura longa fica limitada em quadros', () {
    final t = [for (var i = 0; i < 15 * 600; i++) i / 15];
    final path = GazePath.fromTrace(GazeTrace(
        t: t, x: [for (final _ in t) 0.0], y: [for (final _ in t) 0.0]));
    final gif = replayGif(path: path, maxFrames: 100);
    final frames = [
      for (var i = 0; i < gif.length - 1; i++)
        if (gif[i] == 0x21 && gif[i + 1] == 0xF9) i
    ];
    expect(frames.length, lessThanOrEqualTo(101));
  });

  testWidgets('com o texto da tarefa desenhado no fundo', (tester) async {
    final gif = (await tester.runAsync(() => replayGifWithText(
          path: _reading(),
          textArea: [-12, -8, 12, 6],
          passage: passageById('text'),
        )))!;
    expect(String.fromCharCodes(gif.sublist(0, 6)), 'GIF89a');
    // Paleta de 32 cores.
    expect(gif[10], 0xF4);
    final out = Platform.environment['EYELEARN_GIF_TEXT_OUT'];
    if (out != null) File(out).writeAsBytesSync(gif);
  });
}
