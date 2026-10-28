/// O time-lapse do olhar como GIF animado, para baixar e mostrar fora do
/// painel (numa apresentação, num vídeo).
///
/// Desenho e codificação em Dart puro, sem pacote: o quadro é simples (o
/// fundo da tela de leitura, as linhas do texto como barras, a bolinha e o
/// rastro dela), cabe numa paleta fixa de 16 cores, e o GIF com paleta fixa
/// é só um LZW sobre os índices. Nada sai do navegador: o arquivo é montado
/// aqui e entregue como download.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eyelearn_core/eyelearn_core.dart';

/// Paleta: fundo, barras do texto, borda do texto, bolinha, borda branca,
/// quatro tons do rastro (âmbar sobre o fundo), trilho e avanço da barra de
/// progresso, e as cores dos estados: bolinha vermelha (olhar fora da tela),
/// fundo e barras escurecidos (fora da tela) e fundo cinza (rosto fora da
/// câmera). Sem transparência no GIF, os tons já vêm misturados.
const List<int> _palette = [
  0xFFFDF8, // 0 fundo (Palette.readingSurface)
  0xD5D3E3, // 1 linhas do texto
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
  0xBBBACA, // 14 linhas escurecidas
  0xBFC0CC, // 15 fundo cinza: rosto fora da câmera
];

/// Monta o GIF do percurso.
///
/// [lineFractions] é a largura de cada linha do texto em fração da mais
/// larga (as barras cinzentas); [speed] é quantas vezes mais rápido que a
/// leitura; [fps], quadros por segundo do GIF. A leitura é cortada em
/// [maxFrames] quadros, acelerando se precisar, para o arquivo não crescer
/// sem limite.
Uint8List replayGif({
  required GazePath path,
  double halfWidth = 14,
  double halfHeight = 24,
  List<double>? textArea,
  List<double> lineFractions = const [],
  int width = 200,
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

  // Fundo fixo: a tela de leitura com as linhas.
  final background = Uint8List(width * h);
  void rect(Uint8List buf, int x0, int y0, int x1, int y1, int colour) {
    for (var y = math.max(0, y0); y < math.min(h, y1); y++) {
      buf.fillRange(
          y * width + math.max(0, x0), y * width + math.min(width, x1), colour);
    }
  }

  final area = textArea;
  if (area != null && lineFractions.isNotEmpty) {
    final left = px(area[0]), top = py(area[1]);
    final right = px(area[2]), bottom = py(area[3]);
    final step = (bottom - top) / lineFractions.length;
    for (var i = 0; i < lineFractions.length; i++) {
      final cy = top + step * (i + 0.5);
      final half = math.max(1, (step * 0.18).round());
      rect(
          background,
          left,
          (cy - half).round(),
          left + ((right - left) * lineFractions[i]).round(),
          (cy + half).round(),
          1);
    }
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
  out.add([width & 255, width >> 8, h & 255, h >> 8, 0xF3, 0, 0]);
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
      final bg = noFace ? 15 : 13;
      for (var i = 0; i < width * height; i++) {
        final c = frame[i];
        if (c == 0) {
          frame[i] = bg;
        } else if (c == 1) {
          frame[i] = 14;
        }
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
    out.add([4]);
    out.add(_subBlocks(_lzw(frame, 4)));
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
