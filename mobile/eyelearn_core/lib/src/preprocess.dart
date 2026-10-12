/// Pré-processamento do sinal do olhar: porta de `eyelearn/signal/preprocess.py`.
///
/// Cada função aqui tem de concordar numericamente com a versão Python. A
/// verificação está em `test/golden_test.dart`, que compara os dois lados
/// contra o mesmo arquivo de vetores de ouro.
library;

import 'dart:math' as math;

import 'trace.dart';

/// Converte coordenadas de tela em graus de ângulo visual.
///
/// No celular, `screenWidthCm` é a largura física da tela e
/// `viewingDistanceCm` a distância estimada entre o olho e o aparelho. A
/// distância é estimada, não medida -- ver `GazeCapture` no aplicativo -- e é a
/// principal fonte de erro de escala da captura em aparelho de mão.
({List<double> x, List<double> y}) pixelsToDegrees({
  required List<double> xPx,
  required List<double> yPx,
  required int screenWidthPx,
  required int screenHeightPx,
  required double screenWidthCm,
  required double viewingDistanceCm,
}) {
  if (screenWidthPx <= 0 || screenHeightPx <= 0) {
    throw ArgumentError('as dimensões da tela em pixels devem ser positivas');
  }
  if (screenWidthCm <= 0) {
    throw ArgumentError('a largura física da tela deve ser positiva');
  }
  if (viewingDistanceCm <= 0) {
    throw ArgumentError('a distância de visualização deve ser positiva');
  }

  final cmPerPx = screenWidthCm / screenWidthPx;
  final degrees = 180.0 / math.pi;

  final outX = <double>[];
  final outY = <double>[];
  for (var i = 0; i < xPx.length; i++) {
    final dxCm = (xPx[i] - screenWidthPx / 2.0) * cmPerPx;
    final dyCm = (yPx[i] - screenHeightPx / 2.0) * cmPerPx;
    outX.add(math.atan2(dxCm, viewingDistanceCm) * degrees);
    outY.add(math.atan2(dyCm, viewingDistanceCm) * degrees);
  }
  return (x: outX, y: outY);
}

/// Remove as amostras que não representam olhar válido.
///
/// São inválidas as amostras não finitas -- a captura marca piscada e falha de
/// rastreamento com `double.nan` -- e, quando `boundsDeg` é informado, as que
/// caem fora da área de estímulo.
///
/// As amostras são removidas, não interpoladas: interpolar sobre uma piscada
/// inteira inventa uma trajetória que o olho não percorreu e cria sacadas
/// falsas. O buraco sobrevive no vetor de tempos, e [splitOnGaps] o trata.
GazeTrace dropInvalid(GazeTrace trace, {({double w, double h})? boundsDeg}) {
  if (boundsDeg != null && (boundsDeg.w <= 0 || boundsDeg.h <= 0)) {
    throw ArgumentError('os limites da área de estímulo devem ser positivos');
  }

  final t = <double>[];
  final x = <double>[];
  final y = <double>[];

  for (var i = 0; i < trace.length; i++) {
    final xi = trace.x[i];
    final yi = trace.y[i];
    if (!xi.isFinite || !yi.isFinite) continue;
    if (boundsDeg != null &&
        (xi.abs() > boundsDeg.w || yi.abs() > boundsDeg.h)) {
      continue;
    }
    t.add(trace.t[i]);
    x.add(xi);
    y.add(yi);
  }

  return GazeTrace(t: t, x: x, y: y);
}

/// Proporção de amostras válidas, usada como indicador de qualidade.
///
/// O aplicativo descarta a sessão abaixo de um piso: uma gravação com muita
/// amostra perdida não produz características confiáveis, e apresentá-la ao
/// professor como resultado seria pior do que não apresentar nada.
double validSampleRatio(GazeTrace trace, {({double w, double h})? boundsDeg}) {
  if (trace.isEmpty) return 0.0;
  return dropInvalid(trace, boundsDeg: boundsDeg).length / trace.length;
}

/// Parte o percurso nos buracos deixados pelas amostras descartadas.
///
/// Um intervalo longo entre duas amostras consecutivas não é movimento do
/// olho, e calcular velocidade sobre ele geraria uma sacada inexistente.
///
/// Segmentos com menos de duas amostras são descartados, por não admitirem
/// cálculo de velocidade.
List<GazeTrace> splitOnGaps(GazeTrace trace, {double maxGap = 0.075}) {
  if (maxGap <= 0) throw ArgumentError('maxGap deve ser positivo');
  if (trace.length < 2) return trace.isEmpty ? const [] : [trace];

  final edges = <int>[0];
  for (var i = 1; i < trace.length; i++) {
    if (trace.t[i] - trace.t[i - 1] > maxGap) edges.add(i);
  }
  edges.add(trace.length);

  final segments = <GazeTrace>[];
  for (var i = 0; i < edges.length - 1; i++) {
    final start = edges[i];
    final stop = edges[i + 1];
    if (stop - start >= 2) segments.add(trace.slice(start, stop));
  }
  return segments;
}

/// Suaviza as coordenadas por média móvel centrada.
///
/// Reduz o tremor de alta frequência do rastreador, que de outro modo
/// atravessa o limiar de velocidade do I-VT e fragmenta uma fixação única em
/// várias.
///
/// A janela precisa ser ímpar para que a média fique centrada na amostra, sem
/// deslocar o sinal no tempo. Nas bordas a janela encurta em vez de recorrer a
/// preenchimento: repetir a primeira amostra puxaria a trajetória para ela e
/// achataria a primeira sacada.
///
/// A janela é escolhida em tempo, por `PipelineConfig.smoothingWindow`, e não
/// em amostras -- a 30 Hz da câmera do celular, cinco amostras durariam 167 ms
/// e apagariam a sacada inteira.
GazeTrace smooth(GazeTrace trace, int window) {
  if (window < 1 || window.isEven) {
    throw ArgumentError('window deve ser ímpar e positivo, recebido $window');
  }
  if (window == 1 || trace.isEmpty) return trace;

  return trace.withCoordinates(
    _movingAverage(trace.x, window),
    _movingAverage(trace.y, window),
  );
}

/// Média móvel centrada com janela encurtada nas bordas.
///
/// A soma acumulada com zero à esquerda reproduz a mesma ordem de operações do
/// `numpy.cumsum` usado no lado Python, para que o resultado coincida até o
/// último bit.
List<double> _movingAverage(List<double> values, int window) {
  final half = window ~/ 2;
  final n = values.length;

  final cumulative = List<double>.filled(n + 1, 0.0);
  for (var i = 0; i < n; i++) {
    cumulative[i + 1] = cumulative[i] + values[i];
  }

  final out = List<double>.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    final start = (i - half).clamp(0, n);
    final stop = (i + half + 1).clamp(0, n);
    out[i] = (cumulative[stop] - cumulative[start]) / (stop - start);
  }
  return out;
}

/// Velocidade angular instantânea, em graus por segundo.
///
/// Usa diferenças centradas no interior e laterais nas extremidades, o que
/// reduz o atraso de fase em relação à diferença simples para frente.
///
/// A forma de coeficientes de [_gradient] é a mesma do `numpy.gradient`, e foi
/// escolhida por reproduzi-lo bit a bit: a fórmula fechada equivalente difere
/// na ordem das operações e deixa um resíduo da ordem de 1e-13, suficiente
/// para virar uma comparação contra o limiar de velocidade exatamente na
/// fronteira.
List<double> velocity(GazeTrace trace) {
  final n = trace.length;
  if (n < 2) return List<double>.filled(n, 0.0);

  final dx = _gradient(trace.x, trace.t);
  final dy = _gradient(trace.y, trace.t);

  final out = List<double>.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    out[i] = _hypot(dx[i], dy[i]);
  }
  return out;
}

/// Derivada de `f` em relação a `t`, na mesma forma do `numpy.gradient`.
List<double> _gradient(List<double> f, List<double> t) {
  final n = f.length;
  final out = List<double>.filled(n, 0.0);

  if (n == 2) {
    final slope = (f[1] - f[0]) / (t[1] - t[0]);
    out[0] = slope;
    out[1] = slope;
    return out;
  }

  for (var i = 1; i < n - 1; i++) {
    final dx1 = t[i] - t[i - 1];
    final dx2 = t[i + 1] - t[i];
    final a = -dx2 / (dx1 * (dx1 + dx2));
    final b = (dx2 - dx1) / (dx1 * dx2);
    final c = dx1 / (dx2 * (dx1 + dx2));
    out[i] = a * f[i - 1] + b * f[i] + c * f[i + 1];
  }

  out[0] = (f[1] - f[0]) / (t[1] - t[0]);
  out[n - 1] = (f[n - 1] - f[n - 2]) / (t[n - 1] - t[n - 2]);
  return out;
}

/// Hipotenusa.
///
/// O lado Python usa `numpy.hypot`, que é mais robusto contra estouro de
/// expoente e, por isso, não é a raiz da soma dos quadrados: as duas formas
/// divergem no último bit em cerca de 17% dos casos, com diferença relativa de
/// 2,2e-16. Reproduzir o `hypot` da biblioteca C em Dart não é viável, e para
/// graus de ângulo visual -- limitados a algumas dezenas -- a robustez contra
/// estouro não compra nada.
///
/// É por isso que o teste de vetores de ouro compara com tolerância relativa
/// de 1e-9 em vez de igualdade exata. A tolerância continua sete ordens de
/// grandeza mais apertada do que qualquer defeito real produziria: um limiar
/// trocado, um limite de laço errado ou uma ordem de características
/// embaralhada deslocam o resultado em 1e-2 ou mais.
double _hypot(double a, double b) => math.sqrt(a * a + b * b);
