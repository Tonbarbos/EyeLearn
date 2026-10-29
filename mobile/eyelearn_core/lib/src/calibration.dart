/// Calibração do olhar: do deslocamento da íris à posição na tela.
///
/// A câmera não entrega olhar, entrega pontos do rosto. O que dá para medir é o
/// deslocamento da íris dentro da órbita, normalizado pela largura do olho --
/// uma quantidade adimensional que varia com para onde a criança olha, mas
/// também com a anatomia dela, com a distância ao aparelho e com a inclinação
/// da cabeça.
///
/// A calibração ajusta, por mínimos quadrados, um mapa do deslocamento para a
/// posição na tela, usando pontos que a criança olha a pedido. É o método
/// clássico de rastreamento por câmera comum, e é honesto quanto ao que
/// entrega: erro da ordem de 2 a 4 graus.
///
/// **Isso é pior do que o pior nível da curva de degradação do estudo**, que
/// para em 1 grau -- a faixa que Valliappan et al. (2020) relatam para
/// rastreamento por câmera de celular, obtida com uma rede neural treinada, não
/// com ajuste geométrico. O aplicativo opera, portanto, fora da faixa em que o
/// modelo foi validado. A grade de degradação foi estendida até 3 graus para
/// cobrir este ponto de operação; enquanto a curva não for medida na base real
/// até ali, o que o aplicativo produz é captura, não classificação confiável.
library;

import 'dart:math' as math;

import 'face_landmarks.dart';

/// Um ponto de calibração: onde a criança devia olhar e o que a câmera mediu.
class CalibrationSample {
  /// Alvo na tela, em graus de ângulo visual a partir do centro.
  final double targetX;
  final double targetY;

  /// Deslocamento normalizado da íris, adimensional.
  final double offsetX;
  final double offsetY;

  const CalibrationSample({
    required this.targetX,
    required this.targetY,
    required this.offsetX,
    required this.offsetY,
  });
}

/// Grau do polinômio de mapeamento.
enum CalibrationOrder {
  /// `a0 + a1*ox + a2*oy`: três coeficientes por eixo, cinco alvos bastam.
  ///
  /// É o padrão. Corrige escala e rotação, que é o que a geometria do aparelho
  /// impõe, sem gastar graus de liberdade em curvatura que cinco pontos não
  /// determinam bem.
  linear(3),

  /// Acrescenta `ox*oy`, `ox²` e `oy²`: seis coeficientes por eixo.
  ///
  /// Captura a curvatura da projeção nas bordas da tela, mas precisa de nove
  /// alvos ou mais; com menos, o ajuste passa pelos pontos e erra entre eles.
  quadratic(6);

  const CalibrationOrder(this.terms);

  /// Quantidade de coeficientes por eixo.
  final int terms;
}

/// Erro de calibração: não há dados suficientes, ou eles são degenerados.
class CalibrationError implements Exception {
  final String message;

  const CalibrationError(this.message);

  @override
  String toString() => 'CalibrationError: $message';
}

/// Mapa ajustado do deslocamento da íris para a posição na tela.
class GazeCalibration {
  final List<double> _coefficientsX;
  final List<double> _coefficientsY;
  final CalibrationOrder order;

  /// Erro médio nos próprios pontos de calibração, em graus.
  ///
  /// É otimista por construção -- mede o ajuste onde ele foi ajustado -- e
  /// serve só para rejeitar uma calibração claramente ruim, não para estimar a
  /// precisão em uso. Ver [isAcceptable].
  final double residualDegrees;

  /// Abertura do olho abaixo da qual a amostra é piscada, para esta pessoa.
  ///
  /// O padrão é o piso fixo [minimumOpenness]. A calibração por tempo de
  /// olhar troca por uma fração da abertura medida no alvo do centro: olhar
  /// para baixo baixa a pálpebra, e com o piso fixo as linhas de baixo da
  /// tela viravam "olhos fechados" em quem tem o olho mais estreito ou segura
  /// o celular mais baixo.
  final double blinkOpenness;

  const GazeCalibration._({
    required List<double> coefficientsX,
    required List<double> coefficientsY,
    required this.order,
    required this.residualDegrees,
    this.blinkOpenness = minimumOpenness,
  })  : _coefficientsX = coefficientsX,
        _coefficientsY = coefficientsY;

  /// O mesmo mapa, com outro limite de piscada.
  GazeCalibration withBlinkOpenness(double value) => GazeCalibration._(
        coefficientsX: _coefficientsX,
        coefficientsY: _coefficientsY,
        order: order,
        residualDegrees: residualDegrees,
        blinkOpenness: value,
      );

  /// Ajusta o mapa aos pontos de calibração.
  ///
  /// Throws [CalibrationError] quando há menos pontos que coeficientes, ou
  /// quando os pontos são degenerados -- todos no mesmo lugar, ou numa só
  /// linha. Uma matriz quase singular produziria coeficientes enormes e um
  /// mapa que joga o olhar para fora da tela.
  factory GazeCalibration.fit(
    List<CalibrationSample> samples, {
    CalibrationOrder order = CalibrationOrder.linear,
  }) {
    if (samples.length < order.terms) {
      throw CalibrationError(
        'a calibração ${order.name} precisa de pelo menos ${order.terms} '
        'alvos, recebidos ${samples.length}',
      );
    }

    final design = [for (final sample in samples) _basis(sample, order)];
    final coefficientsX = _solveLeastSquares(
      design,
      [for (final sample in samples) sample.targetX],
    );
    final coefficientsY = _solveLeastSquares(
      design,
      [for (final sample in samples) sample.targetY],
    );

    var total = 0.0;
    for (final sample in samples) {
      final basis = _basis(sample, order);
      final dx = _dot(basis, coefficientsX) - sample.targetX;
      final dy = _dot(basis, coefficientsY) - sample.targetY;
      total += math.sqrt(dx * dx + dy * dy);
    }

    return GazeCalibration._(
      coefficientsX: coefficientsX,
      coefficientsY: coefficientsY,
      order: order,
      residualDegrees: total / samples.length,
    );
  }

  /// Converte um deslocamento de íris em posição na tela, em graus.
  ({double x, double y}) apply(double offsetX, double offsetY) {
    final basis = _basis(
      CalibrationSample(
        targetX: 0,
        targetY: 0,
        offsetX: offsetX,
        offsetY: offsetY,
      ),
      order,
    );
    return (x: _dot(basis, _coefficientsX), y: _dot(basis, _coefficientsY));
  }

  /// Se a calibração é boa o bastante para iniciar a atividade.
  ///
  /// O piso de 3 graus não é generoso por acaso: é a ordem do erro que o método
  /// geométrico entrega. Exigir menos levaria a recalibrar sem fim com uma
  /// criança de nove anos na frente da tela; aceitar mais produziria percurso
  /// sem relação com o texto.
  bool isAcceptable({double maxResidualDegrees = 3.0}) =>
      residualDegrees.isFinite && residualDegrees <= maxResidualDegrees;

  /// Termos do polinômio para um ponto.
  static List<double> _basis(CalibrationSample sample, CalibrationOrder order) {
    final ox = sample.offsetX;
    final oy = sample.offsetY;
    return switch (order) {
      CalibrationOrder.linear => [1.0, ox, oy],
      CalibrationOrder.quadratic => [1.0, ox, oy, ox * oy, ox * ox, oy * oy],
    };
  }
}

double _dot(List<double> a, List<double> b) {
  var total = 0.0;
  for (var i = 0; i < a.length; i++) {
    total += a[i] * b[i];
  }
  return total;
}

/// Resolve `min ||A c - b||` pelas equações normais.
///
/// As equações normais são menos estáveis que uma decomposição QR, mas o
/// sistema aqui tem três ou seis incógnitas e os termos são adimensionais e da
/// ordem da unidade: o condicionamento não é o problema. O que é problema são
/// alvos degenerados, e esses a eliminação detecta pelo pivô.
List<double> _solveLeastSquares(
    List<List<double>> design, List<double> target) {
  final terms = design.first.length;

  // normal[i][j] = soma_k A[k][i] * A[k][j], com a última coluna = A^T b.
  final normal = [
    for (var i = 0; i < terms; i++) List<double>.filled(terms + 1, 0.0),
  ];

  for (var k = 0; k < design.length; k++) {
    final row = design[k];
    for (var i = 0; i < terms; i++) {
      for (var j = 0; j < terms; j++) {
        normal[i][j] += row[i] * row[j];
      }
      normal[i][terms] += row[i] * target[k];
    }
  }

  return _gaussianElimination(normal, terms);
}

/// Eliminação de Gauss com pivoteamento parcial.
List<double> _gaussianElimination(List<List<double>> system, int terms) {
  // A escala dos pivôs é a da matriz normal, cujos termos são somas de
  // produtos adimensionais: um pivô muito menor que o maior elemento indica
  // alvos colineares, não ruído numérico.
  var largest = 0.0;
  for (final row in system) {
    for (final value in row) {
      final magnitude = value.abs();
      if (magnitude > largest) largest = magnitude;
    }
  }
  if (largest == 0.0) {
    throw const CalibrationError(
      'os alvos de calibração são todos iguais; nada a ajustar',
    );
  }
  final minimumPivot = largest * 1e-12;

  for (var column = 0; column < terms; column++) {
    var pivotRow = column;
    for (var row = column + 1; row < terms; row++) {
      if (system[row][column].abs() > system[pivotRow][column].abs()) {
        pivotRow = row;
      }
    }

    if (system[pivotRow][column].abs() <= minimumPivot) {
      throw const CalibrationError(
        'os alvos de calibração são degenerados -- provavelmente colineares; '
        'use alvos espalhados pelos cantos e pelo centro da tela',
      );
    }

    final temporary = system[column];
    system[column] = system[pivotRow];
    system[pivotRow] = temporary;

    final pivot = system[column][column];
    for (var row = 0; row < terms; row++) {
      if (row == column) continue;
      final factor = system[row][column] / pivot;
      if (factor == 0.0) continue;
      for (var k = column; k <= terms; k++) {
        system[row][k] -= factor * system[column][k];
      }
    }
  }

  return [for (var i = 0; i < terms; i++) system[i][terms] / system[i][i]];
}
