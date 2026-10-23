/// Inferência no aparelho: consome o artefato de `eyelearn/export/artifact.py`.
///
/// O modelo é treinado em Python e atravessa a fronteira como JSON com a função
/// de decisão explícita. Não há TensorFlow Lite nem dependência nativa: as três
/// famílias de modelo usadas no estudo têm função de decisão fechada e curta, e
/// reimplementá-la aqui dá reprodução exata, verificável contra vetores de ouro.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'features.dart';

/// Versão do formato de artefato que esta biblioteca entende.
const int supportedArtifactVersion = 1;

/// Natureza da pontuação devolvida pelo modelo.
enum ScoreKind {
  /// Entre 0 e 1, legível como probabilidade.
  probability('probability'),

  /// Distância à fronteira de decisão, de escala arbitrária.
  decision('decision');

  const ScoreKind(this.wireName);

  final String wireName;

  static ScoreKind fromWire(String name) => values.firstWhere(
        (kind) => kind.wireName == name,
        orElse: () => throw FormatException('score_kind desconhecido: $name'),
      );
}

/// Parâmetros de extração com que o modelo foi treinado.
///
/// O aparelho tem de extrair as características do mesmo jeito que o treino as
/// extraiu. Um limiar diferente dos dois lados produz um vetor que o modelo
/// nunca viu, e a predição sai errada sem que nada acuse erro -- por isso estes
/// parâmetros viajam dentro do artefato, em vez de serem fixados no código do
/// aplicativo.
class PreprocessingConfig {
  final String method;
  final double smoothingMs;
  final double maxGap;
  final double velocityThreshold;
  final double dispersionThreshold;
  final double minFixationDuration;
  final ({double w, double h})? boundsDeg;

  const PreprocessingConfig({
    required this.method,
    required this.smoothingMs,
    required this.maxGap,
    required this.velocityThreshold,
    required this.dispersionThreshold,
    required this.minFixationDuration,
    this.boundsDeg,
  });

  factory PreprocessingConfig.fromJson(Map<String, dynamic> json) {
    final bounds = json['bounds_deg'] as List<dynamic>?;
    return PreprocessingConfig(
      method: json['method'] as String,
      smoothingMs: (json['smoothing_ms'] as num).toDouble(),
      maxGap: (json['max_gap'] as num).toDouble(),
      velocityThreshold: (json['velocity_threshold'] as num).toDouble(),
      dispersionThreshold: (json['dispersion_threshold'] as num).toDouble(),
      minFixationDuration: (json['min_fixation_duration'] as num).toDouble(),
      boundsDeg: bounds == null
          ? null
          : (
              w: (bounds[0] as num).toDouble(),
              h: (bounds[1] as num).toDouble()
            ),
    );
  }

  /// Janela da média móvel em amostras, para a taxa informada.
  ///
  /// Arredonda para o ímpar mais próximo, com empate para baixo. Tem de
  /// coincidir com `PipelineConfig.smoothing_window` do lado Python -- a
  /// conversão vive nos dois lados porque a taxa só é conhecida em tempo de
  /// execução, e no celular ela varia com a câmera e com a carga do aparelho.
  int smoothingWindow(double samplingRate) {
    if (samplingRate <= 0) return 1;

    final samples = smoothingMs * samplingRate / 1000.0;
    final lower = ((samples - 1) / 2).floor() * 2 + 1;
    final upper = lower + 2;
    final window = (samples - lower) <= (upper - samples) ? lower : upper;
    return window < 1 ? 1 : window;
  }
}

/// Modelo treinado, em formato portátil.
class ModelArtifact {
  final int version;

  /// Ordem das características com que o modelo foi treinado.
  final List<String> featureNames;

  final List<double> scalerMean;
  final List<double> scalerScale;
  final ScoreKind scoreKind;
  final PreprocessingConfig preprocessing;
  final Map<String, dynamic> metadata;

  final _Predictor _predictor;

  ModelArtifact._({
    required this.version,
    required this.featureNames,
    required this.scalerMean,
    required this.scalerScale,
    required this.scoreKind,
    required this.preprocessing,
    required this.metadata,
    required _Predictor predictor,
  }) : _predictor = predictor;

  /// Lê o artefato de uma cadeia JSON.
  factory ModelArtifact.fromJsonString(String source) =>
      ModelArtifact.fromJson(jsonDecode(source) as Map<String, dynamic>);

  /// Lê o artefato de um mapa já decodificado.
  ///
  /// Recusa versão desconhecida em vez de adivinhar o significado dos campos:
  /// um artefato de formato futuro pode ter a mesma forma e outra semântica, e
  /// aceitá-lo produziria predição errada em silêncio.
  factory ModelArtifact.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != supportedArtifactVersion) {
      throw FormatException(
        'versão de artefato não suportada: $version; '
        'esperada $supportedArtifactVersion',
      );
    }

    final scaler = json['scaler'] as Map<String, dynamic>;
    final mean = _doubles(scaler['mean']);
    final scale = _doubles(scaler['scale']);
    final names = (json['feature_names'] as List<dynamic>).cast<String>();

    if (mean.length != names.length || scale.length != names.length) {
      throw FormatException(
        'o padronizador tem ${mean.length} médias e ${scale.length} escalas '
        'para ${names.length} características',
      );
    }
    for (final value in scale) {
      if (value == 0 || !value.isFinite) {
        throw FormatException('escala inválida no padronizador: $value');
      }
    }

    return ModelArtifact._(
      version: version as int,
      featureNames: names,
      scalerMean: mean,
      scalerScale: scale,
      scoreKind: ScoreKind.fromWire(json['score_kind'] as String),
      preprocessing: PreprocessingConfig.fromJson(
        json['preprocessing'] as Map<String, dynamic>,
      ),
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? const {},
      predictor: _buildPredictor(
        json['model'] as Map<String, dynamic>,
        names.length,
      ),
    );
  }

  /// Limiar natural da pontuação para separar as classes.
  double get threshold => scoreKind == ScoreKind.probability ? 0.5 : 0.0;

  /// Pontuação da classe positiva para um vetor de características.
  double score(List<double> vector) {
    if (vector.length != featureNames.length) {
      throw ArgumentError(
        'esperadas ${featureNames.length} características, '
        'recebidas ${vector.length}',
      );
    }

    final standardised = List<double>.filled(vector.length, 0.0);
    for (var i = 0; i < vector.length; i++) {
      standardised[i] = (vector[i] - scalerMean[i]) / scalerScale[i];
    }
    return _predictor.score(standardised);
  }

  /// Pontuação a partir do mapa de características.
  ///
  /// Monta o vetor na ordem do artefato, não na ordem desta biblioteca.
  double scoreFeatures(Map<String, double> features) =>
      score(buildVector(features, order: featureNames));

  /// Classe prevista: [dyslexic] ou [typical] de `trace.dart`.
  int predict(List<double> vector) => score(vector) > threshold ? 1 : 0;
}

abstract class _Predictor {
  double score(List<double> z);
}

_Predictor _buildPredictor(Map<String, dynamic> model, int nFeatures) {
  final kind = model['kind'] as String;
  switch (kind) {
    case 'logistic':
      return _Logistic(
        coefficients: _doubles(model['coef']),
        intercept: (model['intercept'] as num).toDouble(),
        nFeatures: nFeatures,
      );
    case 'svm_rbf':
      return _SvmRbf(
        gamma: (model['gamma'] as num).toDouble(),
        intercept: (model['intercept'] as num).toDouble(),
        dualCoefficients: _doubles(model['dual_coef']),
        supportVectors: (model['support_vectors'] as List<dynamic>)
            .map((row) => _doubles(row))
            .toList(),
      );
    case 'random_forest':
      return _RandomForest(
        trees: (model['trees'] as List<dynamic>)
            .map((tree) => _Tree.fromJson(tree as Map<String, dynamic>))
            .toList(),
      );
    default:
      throw FormatException('modelo desconhecido no artefato: $kind');
  }
}

class _Logistic implements _Predictor {
  final List<double> coefficients;
  final double intercept;

  _Logistic({
    required this.coefficients,
    required this.intercept,
    required int nFeatures,
  }) {
    if (coefficients.length != nFeatures) {
      throw FormatException(
        'o modelo tem ${coefficients.length} coeficientes para '
        '$nFeatures características',
      );
    }
  }

  @override
  double score(List<double> z) {
    var logit = intercept;
    for (var i = 0; i < z.length; i++) {
      logit += z[i] * coefficients[i];
    }
    // Forma estável da sigmoide: a exponencial de um expoente positivo grande
    // estoura, então cada lado usa a forma que não estoura.
    if (logit >= 0) return 1.0 / (1.0 + math.exp(-logit));
    final exponential = math.exp(logit);
    return exponential / (1.0 + exponential);
  }
}

class _SvmRbf implements _Predictor {
  final double gamma;
  final double intercept;
  final List<double> dualCoefficients;
  final List<List<double>> supportVectors;

  _SvmRbf({
    required this.gamma,
    required this.intercept,
    required this.dualCoefficients,
    required this.supportVectors,
  }) {
    if (dualCoefficients.length != supportVectors.length) {
      throw FormatException(
        'o SVM tem ${dualCoefficients.length} coeficientes duais para '
        '${supportVectors.length} vetores de suporte',
      );
    }
  }

  @override
  double score(List<double> z) {
    var total = intercept;
    for (var s = 0; s < supportVectors.length; s++) {
      final support = supportVectors[s];
      var squared = 0.0;
      for (var i = 0; i < z.length; i++) {
        final difference = z[i] - support[i];
        squared += difference * difference;
      }
      total += dualCoefficients[s] * math.exp(-gamma * squared);
    }
    return total;
  }
}

class _RandomForest implements _Predictor {
  final List<_Tree> trees;

  /// Buffer de precisão simples, alocado na primeira pontuação e reaproveitado.
  ///
  /// A floresta é percorrida uma vez por árvore a cada gravação, e alocar um
  /// buffer por chamada num aparelho que também está decodificando vídeo é
  /// desperdício evitável.
  Float32List? _buffer;

  _RandomForest({required this.trees}) {
    if (trees.isEmpty) {
      throw const FormatException('a floresta exportada não tem árvores');
    }
  }

  @override
  double score(List<double> z) {
    // As árvores do scikit-learn convertem a entrada para precisão simples
    // antes de percorrer, mas guardam os limiares em precisão dupla. Um valor
    // que é maior que o limiar em dupla pode ser menor ou igual depois de
    // reduzido a simples, e a travessia cai em outra folha -- diferença de até
    // 1,0 na saída daquela árvore. Sem esta conversão a floresta não reproduz
    // o lado Python, e foi assim que a divergência apareceu na primeira
    // execução dos vetores de ouro.
    final narrowed = _buffer ??= Float32List(z.length);
    for (var i = 0; i < z.length; i++) {
      narrowed[i] = z[i];
    }

    var total = 0.0;
    for (final tree in trees) {
      total += tree.score(narrowed);
    }
    return total / trees.length;
  }
}

/// Árvore em vetores paralelos indexados por nó, como o scikit-learn a guarda.
class _Tree {
  final List<int> left;
  final List<int> right;
  final List<int> feature;
  final List<double> threshold;
  final List<double> positiveRatio;

  const _Tree({
    required this.left,
    required this.right,
    required this.feature,
    required this.threshold,
    required this.positiveRatio,
  });

  factory _Tree.fromJson(Map<String, dynamic> json) => _Tree(
        left: (json['left'] as List<dynamic>).cast<int>(),
        right: (json['right'] as List<dynamic>).cast<int>(),
        feature: (json['feature'] as List<dynamic>).cast<int>(),
        threshold: _doubles(json['threshold']),
        positiveRatio: _doubles(json['positive_ratio']),
      );

  double score(Float32List z32) {
    var node = 0;
    while (left[node] != -1) {
      // O valor em precisão simples é promovido a dupla na comparação, como
      // acontece no código do scikit-learn.
      node = z32[feature[node]] <= threshold[node] ? left[node] : right[node];
    }
    return positiveRatio[node];
  }
}

List<double> _doubles(dynamic value) =>
    (value as List<dynamic>).map((item) => (item as num).toDouble()).toList();
