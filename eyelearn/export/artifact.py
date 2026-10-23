"""Artefato de modelo portátil, para inferência no aparelho.

O aplicativo do aluno roda em celular, onde não há Python nem scikit-learn. O
modelo treinado precisa, portanto, atravessar a fronteira de linguagem.

**Por que JSON explícito e não TensorFlow Lite.** A rota usual seria converter o
modelo para TFLite, mas o scikit-learn não exporta para TFLite diretamente: o
caminho passa por ONNX e depois por TensorFlow, três conversões cujo resultado
não é verificável sem rodar as duas pontas. Os modelos usados aqui -- regressão
logística, SVM com núcleo radial e floresta aleatória -- têm função de decisão
fechada e curta. Escrevê-la explicitamente em JSON e reimplementá-la no
aparelho dá reprodução exata, verificável por vetores de ouro
(:mod:`eyelearn.export.golden`), e dispensa a dependência nativa.

O artefato carrega também os parâmetros de pré-processamento. O aparelho tem de
extrair as características do mesmo jeito que o treino as extraiu; um limiar
diferente dos dois lados produz um vetor que o modelo nunca viu, e a predição
fica errada sem que nada acuse erro.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

from eyelearn.features.reading import FEATURE_NAMES
from eyelearn.pipeline import PipelineConfig
from eyelearn.trace import DYSLEXIC, TYPICAL

#: Versão do formato. O aplicativo recusa um artefato de versão desconhecida em
#: vez de adivinhar o significado dos campos.
ARTIFACT_VERSION = 1

ScoreKind = Literal["probability", "decision"]


class UnsupportedModelError(ValueError):
    """O modelo não tem função de decisão exportável por este módulo."""


@dataclass
class ModelArtifact:
    """Modelo treinado em formato portátil.

    Attributes:
        version: versão do formato do artefato.
        feature_names: ordem canônica das características. O aparelho monta o
            vetor nesta ordem; qualquer divergência troca o significado das
            colunas silenciosamente.
        scaler: ``{"mean": [...], "scale": [...]}`` da padronização.
        model: função de decisão, no formato de :func:`_export_model`.
        score_kind: ``"probability"`` quando a pontuação está entre 0 e 1 e
            pode ser lida como probabilidade; ``"decision"`` quando é a
            distância à fronteira, de escala arbitrária.
        preprocessing: parâmetros com que as características foram extraídas
            no treino, para que o aparelho use os mesmos.
        metadata: procedência -- quando, com que base, com que desempenho.
    """

    version: int
    feature_names: list[str]
    scaler: dict[str, list[float]]
    model: dict[str, Any]
    score_kind: ScoreKind
    preprocessing: dict[str, Any]
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_json(self, indent: int | None = 2) -> str:
        return json.dumps(asdict(self), indent=indent, ensure_ascii=False)

    def save(self, path: Path | str) -> Path:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.to_json(), encoding="utf-8")
        return path

    @classmethod
    def load(cls, path: Path | str) -> ModelArtifact:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls.from_dict(payload)

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> ModelArtifact:
        version = payload.get("version")
        if version != ARTIFACT_VERSION:
            raise ValueError(
                f"versão de artefato não suportada: {version!r}; "
                f"esperada {ARTIFACT_VERSION}"
            )
        return cls(
            version=version,
            feature_names=list(payload["feature_names"]),
            scaler=payload["scaler"],
            model=payload["model"],
            score_kind=payload["score_kind"],
            preprocessing=payload["preprocessing"],
            metadata=payload.get("metadata", {}),
        )

    def score(self, X: np.ndarray) -> np.ndarray:
        """Pontuação da classe positiva, implementada sobre o próprio artefato.

        É a implementação de referência: o que o aparelho precisa reproduzir.
        Mantê-la aqui, em vez de chamar o scikit-learn, permite testar que a
        exportação não perdeu nada -- se esta função concorda com o modelo
        original, o artefato está completo, e o que o aparelho tem de conferir
        é apenas a aritmética.
        """
        X = np.atleast_2d(np.asarray(X, dtype=float))
        if X.shape[1] != len(self.feature_names):
            raise ValueError(
                f"esperadas {len(self.feature_names)} características, "
                f"recebidas {X.shape[1]}"
            )

        mean = np.asarray(self.scaler["mean"], dtype=float)
        scale = np.asarray(self.scaler["scale"], dtype=float)
        Z = (X - mean) / scale

        kind = self.model["kind"]
        if kind == "logistic":
            return _score_logistic(self.model, Z)
        if kind == "svm_rbf":
            return _score_svm_rbf(self.model, Z)
        if kind == "random_forest":
            return _score_random_forest(self.model, Z)
        raise UnsupportedModelError(f"modelo desconhecido no artefato: {kind!r}")

    def predict(self, X: np.ndarray) -> np.ndarray:
        """Classe prevista, pelo limiar natural de cada tipo de pontuação."""
        threshold = 0.5 if self.score_kind == "probability" else 0.0
        return np.where(self.score(X) > threshold, DYSLEXIC, TYPICAL)


def export_artifact(
    model: Pipeline,
    config: PipelineConfig | None = None,
    metadata: dict[str, Any] | None = None,
) -> ModelArtifact:
    """Converte um pipeline treinado em artefato portátil.

    Args:
        model: pipeline com ``scaler`` e ``clf``, já ajustado.
        config: parâmetros de extração usados no treino. O aparelho tem de usar
            os mesmos, e por isso eles viajam dentro do artefato.
        metadata: procedência a registrar (base, desempenho, nível de
            degradação do treino).

    Returns:
        O artefato correspondente.

    Raises:
        UnsupportedModelError: se o classificador final não for um dos três
            tipos exportáveis.
        ValueError: se o pipeline não tiver sido ajustado.
    """
    config = config or PipelineConfig()

    try:
        scaler = model.named_steps["scaler"]
        classifier = model.named_steps["clf"]
    except (AttributeError, KeyError) as error:
        raise ValueError(
            "o pipeline precisa ter as etapas 'scaler' e 'clf'"
        ) from error

    if not isinstance(scaler, StandardScaler) or not hasattr(scaler, "mean_"):
        raise ValueError("a etapa 'scaler' precisa ser um StandardScaler ajustado")

    exported, score_kind = _export_model(classifier)

    return ModelArtifact(
        version=ARTIFACT_VERSION,
        feature_names=list(FEATURE_NAMES),
        scaler={
            "mean": scaler.mean_.tolist(),
            "scale": scaler.scale_.tolist(),
        },
        model=exported,
        score_kind=score_kind,
        preprocessing={
            "method": config.method,
            "smoothing_ms": config.smoothing_ms,
            "max_gap": config.max_gap,
            "velocity_threshold": config.velocity_threshold,
            "dispersion_threshold": config.dispersion_threshold,
            "min_fixation_duration": config.min_fixation_duration,
            "bounds_deg": list(config.bounds_deg) if config.bounds_deg else None,
        },
        metadata={
            "exported_at": datetime.now(UTC).isoformat(timespec="seconds"),
            "positive_class": "dyslexic",
            **(metadata or {}),
        },
    )


def _export_model(classifier: Any) -> tuple[dict[str, Any], ScoreKind]:
    """Serializa a função de decisão do classificador."""
    if isinstance(classifier, LogisticRegression):
        _require_binary(classifier)
        return (
            {
                "kind": "logistic",
                "coef": classifier.coef_[0].tolist(),
                "intercept": float(classifier.intercept_[0]),
            },
            "probability",
        )

    if isinstance(classifier, SVC):
        if classifier.kernel != "rbf":
            raise UnsupportedModelError(
                f"apenas o núcleo radial é exportável, não {classifier.kernel!r}"
            )
        _require_binary(classifier)
        # O SVC sem calibração não produz probabilidade, apenas a distância à
        # fronteira. O aplicativo apresenta faixas, não números, então a escala
        # arbitrária não é um problema -- mas precisa estar declarada.
        return (
            {
                "kind": "svm_rbf",
                "gamma": float(classifier._gamma),
                "intercept": float(classifier.intercept_[0]),
                "dual_coef": classifier.dual_coef_[0].tolist(),
                "support_vectors": classifier.support_vectors_.tolist(),
            },
            "decision",
        )

    if isinstance(classifier, RandomForestClassifier):
        _require_binary(classifier)
        return (
            {
                "kind": "random_forest",
                "trees": [_export_tree(estimator) for estimator in classifier.estimators_],
            },
            "probability",
        )

    raise UnsupportedModelError(
        f"sem exportação para {type(classifier).__name__}; "
        "exportáveis: LogisticRegression, SVC(kernel='rbf'), RandomForestClassifier"
    )


def _export_tree(estimator: Any) -> dict[str, Any]:
    """Serializa uma árvore como vetores paralelos indexados por nó.

    O formato de vetores paralelos é o mesmo do scikit-learn e atravessa bem
    para JSON: um nó folha tem ``left == -1``, e os nós internos comparam
    ``x[feature] <= threshold`` para decidir o lado.

    A folha guarda a proporção da classe positiva, não a contagem: é o que a
    predição usa, e a contagem bruta tornaria o arquivo maior sem necessidade.
    """
    tree = estimator.tree_

    # value tem forma (n_nós, 1, n_classes); a proporção da classe positiva é a
    # segunda coluna, já normalizada pelo scikit-learn por nó.
    totals = tree.value[:, 0, :].sum(axis=1)
    with np.errstate(invalid="ignore", divide="ignore"):
        positive = np.where(totals > 0, tree.value[:, 0, 1] / totals, 0.0)

    return {
        "left": tree.children_left.tolist(),
        "right": tree.children_right.tolist(),
        "feature": tree.feature.tolist(),
        "threshold": tree.threshold.tolist(),
        "positive_ratio": positive.tolist(),
    }


def _require_binary(classifier: Any) -> None:
    classes = list(getattr(classifier, "classes_", []))
    if classes != [TYPICAL, DYSLEXIC]:
        raise UnsupportedModelError(
            f"esperadas as classes [{TYPICAL}, {DYSLEXIC}], encontradas {classes}"
        )


def _score_logistic(model: dict[str, Any], Z: np.ndarray) -> np.ndarray:
    coef = np.asarray(model["coef"], dtype=float)
    logits = Z @ coef + float(model["intercept"])
    # Forma numericamente estável da sigmoide: a exponencial de um expoente
    # positivo grande estoura, então cada lado usa a forma que não estoura.
    return np.where(
        logits >= 0,
        1.0 / (1.0 + np.exp(-np.clip(logits, 0, None))),
        np.exp(np.clip(logits, None, 0)) / (1.0 + np.exp(np.clip(logits, None, 0))),
    )


def _score_svm_rbf(model: dict[str, Any], Z: np.ndarray) -> np.ndarray:
    support = np.asarray(model["support_vectors"], dtype=float)
    dual = np.asarray(model["dual_coef"], dtype=float)
    gamma = float(model["gamma"])

    # ||z - s||² expandido, para avaliar todos os pares de uma vez.
    squared = (
        np.sum(Z**2, axis=1)[:, None]
        - 2.0 * Z @ support.T
        + np.sum(support**2, axis=1)[None, :]
    )
    kernel = np.exp(-gamma * np.maximum(squared, 0.0))
    return kernel @ dual + float(model["intercept"])


def _score_random_forest(model: dict[str, Any], Z: np.ndarray) -> np.ndarray:
    trees = model["trees"]
    if not trees:
        raise UnsupportedModelError("a floresta exportada não tem árvores")

    # As árvores do scikit-learn convertem a entrada para float32 antes de
    # percorrer, mas guardam os limiares em float64. Um valor que é maior que o
    # limiar em precisão dupla pode ser menor ou igual depois de reduzido a
    # precisão simples, e a travessia cai em outra folha -- diferença de até
    # 1,0 na saída daquela árvore. Reproduzir a conversão aqui é o que dá
    # concordância exata com o scikit-learn, e é o que o aparelho também tem de
    # fazer. Regressão logística e SVM não passam por isso: ambos operam em
    # precisão dupla do começo ao fim.
    Z32 = Z.astype(np.float32)

    total = np.zeros(Z.shape[0], dtype=float)
    for tree in trees:
        total += _score_tree(tree, Z32)
    return total / len(trees)


def _score_tree(tree: dict[str, Any], Z32: np.ndarray) -> np.ndarray:
    """Percorre uma árvore. ``Z32`` tem de estar em precisão simples."""
    left = tree["left"]
    right = tree["right"]
    feature = tree["feature"]
    threshold = tree["threshold"]
    positive = tree["positive_ratio"]

    out = np.empty(Z32.shape[0], dtype=float)
    for row in range(Z32.shape[0]):
        node = 0
        while left[node] != -1:
            # O valor em precisão simples é promovido a dupla na comparação,
            # como acontece no código do scikit-learn.
            node = (
                left[node]
                if float(Z32[row, feature[node]]) <= threshold[node]
                else right[node]
            )
        out[row] = positive[node]
    return out
