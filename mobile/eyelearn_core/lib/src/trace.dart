/// Percurso do olhar: a mesma estrutura de `eyelearn/trace.py`.
///
/// As coordenadas circulam em graus de ângulo visual e o tempo em segundos,
/// como no lado Python. Os limiares dos detectores de evento são definidos
/// nessa unidade na literatura, e manter uma unidade só dos dois lados da
/// fronteira de linguagem evita que uma conversão apareça em um lado e não no
/// outro.
library;

/// Rótulos de classe, iguais aos de `eyelearn/trace.py`.
const int typical = 0;
const int dyslexic = 1;

/// Percurso do olhar de um participante em uma tarefa.
class GazeTrace {
  /// Instantes de amostragem, em segundos, estritamente crescentes.
  final List<double> t;

  /// Coordenada horizontal, em graus de ângulo visual.
  final List<double> x;

  /// Coordenada vertical, em graus de ângulo visual.
  final List<double> y;

  GazeTrace({
    required this.t,
    required this.x,
    required this.y,
  }) {
    if (t.length != x.length || t.length != y.length) {
      throw ArgumentError(
        't, x e y devem ter o mesmo tamanho: '
        '${t.length}, ${x.length}, ${y.length}',
      );
    }
    for (var i = 0; i < t.length; i++) {
      if (!t[i].isFinite) {
        throw ArgumentError('t não pode conter NaN ou infinito (índice $i)');
      }
      if (i > 0 && t[i] <= t[i - 1]) {
        throw ArgumentError('t deve ser estritamente crescente (índice $i)');
      }
    }
  }

  /// Percurso vazio, para o caso em que a captura não produziu amostra.
  GazeTrace.empty()
      : t = const [],
        x = const [],
        y = const [];

  int get length => t.length;

  bool get isEmpty => t.isEmpty;

  /// Intervalo coberto pelo percurso, em segundos.
  double get duration => t.length < 2 ? 0.0 : t.last - t.first;

  /// Taxa de amostragem mediana, em Hz.
  ///
  /// Usa a mediana dos intervalos, e não a média, porque amostras perdidas por
  /// piscada deixam buracos longos que distorceriam a média.
  double get samplingRate {
    if (t.length < 2) return 0.0;

    final gaps = <double>[];
    for (var i = 1; i < t.length; i++) {
      gaps.add(t[i] - t[i - 1]);
    }
    gaps.sort();

    final middle = gaps.length ~/ 2;
    final median = gaps.length.isOdd
        ? gaps[middle]
        : (gaps[middle - 1] + gaps[middle]) / 2.0;

    return median <= 0 ? 0.0 : 1.0 / median;
  }

  /// Cópia com outras coordenadas e os mesmos instantes.
  GazeTrace withCoordinates(List<double> newX, List<double> newY) =>
      GazeTrace(t: t, x: newX, y: newY);

  /// Recorte `[start, stop)`.
  GazeTrace slice(int start, int stop) => GazeTrace(
        t: t.sublist(start, stop),
        x: x.sublist(start, stop),
        y: y.sublist(start, stop),
      );
}
