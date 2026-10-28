/// O time-lapse do olhar como GIF animado, para baixar e mostrar fora do
/// painel (numa apresentação, num vídeo).
///
/// O fundo (a tela de leitura com o texto da tarefa) é desenhado uma vez
/// pelo próprio Flutter, com as mesmas funções do painel, e convertido para
/// a paleta; os quadros (a bolinha e o rastro) são desenhados por cima, em
/// Dart puro, e codificados num GIF de paleta fixa (um LZW sobre os
/// índices). Nada sai do navegador: o arquivo é montado aqui e entregue
/// como download.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/painting.dart';

import '../activity/passages.dart';
import 'heatmap_view.dart';

/// Paleta: fundo, borda do texto, bolinha, borda branca, quatro tons do
/// rastro (âmbar sobre o fundo), trilho e avanço da barra de progresso, os
/// estados (bolinha vermelha do olhar fora da tela, fundo escurecido, fundo
/// cinza do rosto fora da câmera) e a tinta do texto, cheia e meio-tom, nas
/// três versões. Sem transparência no GIF, os tons já vêm misturados.
const List<int> _palette = [
  0xFFFDF8, // 0 fundo (Palette.readingSurface)
  0xD5D3E3, // 1 (sem uso)
  0x9AA0BF, // 2 borda do texto
  0xFFB23F, // 3 bolinha (Palette.amber)
  0xFFFFFF, // 4 borda da bolinha
  0xFFF1DC, // 5 rastro, mais fraco
  0xFFE4BA,
  0xFFD58F,
  0xFFC566, // 8 rastro, mais forte
  0xE6E5F2, // 9 trilho do progresso (Palette.line)
  0x5B4BE8, // 10 avanço (Palette.brand)
  0x1C2033, // 11 tinta
  0xF2594B, // 12 bolinha fora da tela (Palette.coral)
  0xDFDEDC, // 13 fundo escurecido: olhar fora da tela
  0xBBBACA, // 14 (sem uso)
  0xBFC0CC, // 15 fundo cinza: rosto fora da câmera
  0x4A4F6A, // 16 texto
  0x44485F, // 17 texto escurecido
  0x6D728C, // 18 texto no cinza
  0xA4A6B1, // 19 meio-tom do texto
  0x91939F, // 20 meio-tom escurecido
  0x969AAC, // 21 meio-tom no cinza
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
];

/// Fundo, texto e meio-tom em cada estado: normal, olhar fora da tela e
/// rosto fora da câmera.
const _dimmed = {0: 13, 16: 17, 19: 20};
const _greyed = {0: 15, 16: 18, 19: 21};

/// Cor do texto no fundo do GIF.
const textInk = Color(0xFF4A4F6A);

/// Converte a tela desenhada (RGBA) para os índices da paleta: cada pixel
/// vira o mais próximo entre fundo, borda, texto e meio-tom do texto.
Uint8List indexScreen(Uint8List rgba) {
  const candidates = [0, 2, 16, 19];
  final out = Uint8List(rgba.length ~/ 4);
  for (var i = 0; i < out.length; i++) {
    final r = rgba[4 * i], g = rgba[4 * i + 1], b = rgba[4 * i + 2];
    var best = 0, bestDistance = 1 << 30;
    for (final c in candidates) {
      final p = _palette[c];
      final dr = r - ((p >> 16) & 255);
      final dg = g - ((p >> 8) & 255);
      final db = b - (p & 255);
      final d = dr * dr + dg * dg + db * db;
      if (d < bestDistance) {
        bestDistance = d;
        best = c;
      }
    }
    out[i] = best;
  }
  return out;
}

/// Desenha a tela de leitura com o texto e devolve os índices da paleta.
Future<Uint8List> renderScreenIndices({
  required int width,
  required int height,
  required double halfWidth,
  required double halfHeight,
  required List<double>? textArea,
  required Passage? passage,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width.toDouble(), height.toDouble());
  paintScreenBackground(canvas, size, halfWidth, halfHeight, textArea);
  paintPassageText(canvas, size, halfWidth, halfHeight, textArea, passage,
      colour: textInk);
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return indexScreen(data!.buffer.asUint8List());
}

/// O GIF com o texto da tarefa no fundo.
Future<Uint8List> replayGifWithText({
  required GazePath path,
  double halfWidth = 14,
  double halfHeight = 24,
  List<double>? textArea,
  Passage? passage,
  int width = gifWidth,
  double speed = 4,
}) async {
  final height = (width * halfHeight / halfWidth).round();
  final screen = await renderScreenIndices(
    width: width,
    height: height,
    halfWidth: halfWidth,
    halfHeight: halfHeight,
    textArea: textArea,
    passage: passage,
  );
  return replayGif(
    path: path,
    halfWidth: halfWidth,
    halfHeight: halfHeight,
    textArea: textArea,
    screen: screen,
    width: width,
    speed: speed,
  );
}

/// Largura padrão do GIF: o bastante para o texto ser lido.
const int gifWidth = 300;

/// Monta o GIF do percurso.
///
/// [screen] é o fundo já em índices da paleta (`renderScreenIndices`), com
/// `width * altura` pixels; sem ele, só o fundo e a moldura do texto.
/// [speed] é quantas vezes mais rápido que a leitura; [fps], quadros por
/// segundo do GIF. A leitura é cortada em [maxFrames] quadros, acelerando se
/// precisar, para o arquivo não crescer sem limite.
Uint8List replayGif({
  required GazePath path,
  double halfWidth = 14,
  double halfHeight = 24,
  List<double>? textArea,
  Uint8List? screen,
  int width = gifWidth,
  double speed = 4,
  int fps = 10,
  int maxFrames = 300,
}) {
  final height = (width * halfHeight / halfWidth).round();
  const progressHeight = 4;
  final h = height + progressHeight;
  int px(double deg) => ((deg + halfWidth) / (2 * halfWidth) * width).round();
  int py(double deg) =>
      ((deg + halfHeight) / (2 * halfHeight) * height).round();

  final background = Uint8List(width * h);
  void rect(Uint8List buf, int x0, int y0, int x1, int y1, int colour) {
    for (var y = math.max(0, y0); y < math.min(h, y1); y++) {
      buf.fillRange(
          y * width + math.max(0, x0), y * width + math.min(width, x1), colour);
    }
  }

  final area = textArea;
  if (screen != null && screen.length == width * height) {
    background.setAll(0, screen);
  } else if (area != null) {
    final left = px(area[0]), top = py(area[1]);
    final right = px(area[2]), bottom = py(area[3]);
    rect(background, left, top, right, top + 1, 2);
    rect(background, left, bottom - 1, right, bottom, 2);
    rect(background, left, top, left + 1, bottom, 2);
    rect(background, right - 1, top, right, bottom, 2);
  }
  rect(background, 0, height, width, h, 9);

  bool inside(({double x, double y}) p) =>
      p.x.abs() <= halfWidth && p.y.abs() <= halfHeight;

  void disc(Uint8List buf, int cx, int cy, double r, int colour) {
    final ri = r.ceil();
    for (var y = cy - ri; y <= cy + ri; y++) {
      if (y < 0 || y >= height) continue;
      for (var x = cx - ri; x <= cx + ri; x++) {
        if (x < 0 || x >= width) continue;
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) {
          buf[y * width + x] = colour;
        }
      }
    }
  }

  final duration = path.duration;
  var step = speed / fps; // segundos de leitura por quadro
  if (duration / step > maxFrames) step = duration / maxFrames;
  final count = math.max(1, (duration / step).ceil() + 1);
  final delay = (100 / fps).round();

  final out = BytesBuilder();
  out.add('GIF89a'.codeUnits);
  // Paleta global de 32 cores.
  out.add([width & 255, width >> 8, h & 255, h >> 8, 0xF4, 0, 0]);
  for (final c in _palette) {
    out.add([(c >> 16) & 255, (c >> 8) & 255, c & 255]);
  }
  // Repetir para sempre.
  out.add([0x21, 0xFF, 11, ...'NETSCAPE2.0'.codeUnits, 3, 1, 0, 0, 0]);

  final frame = Uint8List(width * h);
  for (var f = 0; f < count; f++) {
    final now = math.min(duration, f * step);
    frame.setAll(0, background);
    final sample = path.sampleAt(now);
    final at = path.at(now);
    final noFace = sample?.state == GazeSampleState.noFace;
    final away = at != null && !inside(at);
    if (noFace || away) {
      // Rosto fora da câmera: fundo cinza. Olhar fora da tela: escurecido.
      final map = noFace ? _greyed : _dimmed;
      for (var i = 0; i < width * height; i++) {
        final to = map[frame[i]];
        if (to != null) frame[i] = to;
      }
    }
    if (!noFace) {
      // Rastro: o último segundo de leitura, mais forte perto do agora. Só
      // o que caiu na tela.
      final trail = path.between(now - 1.0, now).where(inside).toList();
      for (var i = 0; i < trail.length; i++) {
        final age = (i + 1) / trail.length;
        disc(frame, px(trail[i].x), py(trail[i].y), 2 + 3 * age,
            5 + (age * 3.99).floor());
      }
    }
    if (at != null && !away) {
      disc(frame, px(at.x), py(at.y), 8, 4);
      disc(frame, px(at.x), py(at.y), 6.5, 3);
    } else if (away) {
      // Presa na borda, com uma seta de bolinhas para onde o olhar foi.
      const inset = 24;
      final tx = px(at.x), ty = py(at.y);
      final cx = tx.clamp(inset, width - inset);
      final cy = ty.clamp(inset, height - inset);
      final dx = (tx - cx).toDouble(), dy = (ty - cy).toDouble();
      final len = math.sqrt(dx * dx + dy * dy);
      final ux = len == 0 ? 0.0 : dx / len, uy = len == 0 ? -1.0 : dy / len;
      for (var k = 1; k <= 3; k++) {
        disc(frame, (cx + ux * (8 + 4 * k)).round(),
            (cy + uy * (8 + 4 * k)).round(), 4.2 - k, 12);
      }
      disc(frame, cx, cy, 8, 4);
      disc(frame, cx, cy, 6.5, 12);
    }
    final done = duration == 0 ? width : (now / duration * width).round();
    rect(frame, 0, height, done, h, 10);

    final last = f == count - 1;
    out.add([0x21, 0xF9, 4, 0x04, ...(_le16(last ? 200 : delay)), 0, 0]);
    out.add([0x2C, 0, 0, 0, 0, width & 255, width >> 8, h & 255, h >> 8, 0]);
    out.add([5]);
    out.add(_subBlocks(_lzw(frame, 5)));
  }
  out.add([0x3B]);
  return out.toBytes();
}

List<int> _le16(int v) => [v & 255, (v >> 8) & 255];

/// Compressão LZW do GIF, com códigos de largura variável até 12 bits.
Uint8List _lzw(Uint8List pixels, int minCodeSize) {
  final clear = 1 << minCodeSize;
  final end = clear + 1;
  final out = BytesBuilder();
  var bitBuffer = 0, bitCount = 0;
  var codeSize = minCodeSize + 1;

  void emit(int code) {
    bitBuffer |= code << bitCount;
    bitCount += codeSize;
    while (bitCount >= 8) {
      out.addByte(bitBuffer & 255);
      bitBuffer >>= 8;
      bitCount -= 8;
    }
  }

  var table = <int, int>{};
  var next = end + 1;
  emit(clear);
  var prefix = pixels[0];
  for (var i = 1; i < pixels.length; i++) {
    final k = pixels[i];
    final key = (prefix << 8) | k;
    final found = table[key];
    if (found != null) {
      prefix = found;
      continue;
    }
    emit(prefix);
    if (next < 4096) {
      table[key] = next++;
      if (next > (1 << codeSize) && codeSize < 12) codeSize++;
    } else {
      emit(clear);
      table = <int, int>{};
      next = end + 1;
      codeSize = minCodeSize + 1;
    }
    prefix = k;
  }
  emit(prefix);
  emit(end);
  if (bitCount > 0) out.addByte(bitBuffer & 255);
  return out.toBytes();
}

Uint8List _subBlocks(Uint8List data) {
  final out = BytesBuilder();
  for (var i = 0; i < data.length; i += 255) {
    final n = math.min(255, data.length - i);
    out.addByte(n);
    out.add(Uint8List.sublistView(data, i, i + n));
  }
  out.addByte(0);
  return out.toBytes();
}
