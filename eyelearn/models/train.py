"""Treino, avaliação e métricas dos classificadores.

Cobre a modelagem preditiva da seção 4.3 e os indicadores de desempenho da
seção 4.5. A rede convolucional unidimensional prevista na metodologia atua
sobre a série temporal, não sobre o vetor de características, e por isso vive
fora deste módulo -- aqui estão os modelos que consomem a saída de
:mod:`eyelearn.features.reading`.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

from eyelearn.models.validation import Fold, subject_folds
from eyelearn.trace import DYSLEXIC, TYPICAL

#: Prevalência da dislexia na população escolar, usada no cálculo do valor
#: preditivo positivo. A faixa relatada na literatura vai de 5% a 17%
#: dependendo do critério diagnóstico; 10% é o ponto intermediário e deve ser
#: informado explicitamente em qualquer resultado publicado.
SCHOOL_PREVALENCE = 0.10


def build_models(seed: int = 0) -> dict[str, Pipeline]:
    """Modelos comparados no experimento.

    Todos vêm encapsulados com padronização, inclusive os baseados em árvore,
    que não precisam dela: manter o mesmo invólucro garante que a diferença de
    desempenho venha do algoritmo e não da preparação dos dados.

    A regressão logística entra como linha de base. Sem ela não há como saber
    se o ganho de um modelo mais complexo é real ou se o problema já era
    linearmente separável.

    Args:
        seed: semente dos componentes estocásticos.
    """
    return {
        "logistic": Pipeline(
            [
                ("scaler", StandardScaler()),
                ("clf", LogisticRegression(max_iter=1000, random_state=seed)),
            ]
        ),
        # O SVC não estima probabilidade sem calibração, e a calibração
        # interna foi descontinuada no scikit-learn 1.9. A área sob a curva é
        # calculada a partir da função de decisão, cuja escala é arbitrária
        # mas cuja ordenação é tudo de que a métrica precisa.
        "svm": Pipeline(
            [
                ("scaler", StandardScaler()),
                ("clf", SVC(kernel="rbf", random_state=seed)),
            ]
        ),
        "random_forest": Pipeline(
            [
                ("scaler", StandardScaler()),
                (
                    "clf",
                    RandomForestClassifier(
                        n_estimators=300, random_state=seed, n_jobs=-1
                    ),
                ),
            ]
        ),
    }


@dataclass
class FoldMetrics:
    """Métricas de uma única partição."""

    accuracy: float
    sensitivity: float
    specificity: float
    f1: float
    roc_auc: float | None


@dataclass
class EvaluationResult:
    """Resultado agregado de um modelo ao longo das partições.

    Attributes:
        model_name: nome do modelo avaliado.
        folds: métricas de cada partição.
        confusion: matriz de confusão somada, na ordem
            ``[[vn, fp], [fn, vp]]``.
    """

    model_name: str
    folds: list[FoldMetrics] = field(default_factory=list)
    confusion: np.ndarray = field(default_factory=lambda: np.zeros((2, 2), dtype=int))

    def mean(self, metric: str) -> float:
        """Média de uma métrica entre as partições, ignorando as indefinidas."""
        values = [
            value
            for value in (getattr(fold, metric) for fold in self.folds)
            if value is not None
        ]
        return float(np.mean(values)) if values else float("nan")

    def confidence_interval(self, metric: str, level: float = 0.95) -> tuple[float, float]:
        """Faixa da métrica entre as partições, pelos percentis.

        **Não é o intervalo de confiança da média.** É a dispersão da métrica
        de uma partição para outra -- com 70 participantes, cada partição de
        teste tem uns 14, e a acurácia de uma partição varia muito. O
        intervalo da média é bem mais estreito. Para comparar dois níveis da
        curva de degradação, o certo é a diferença pareada nas mesmas
        partições, não a sobreposição destas faixas.

        Também não mede a incerteza de generalização para outra população --
        com 70 participantes de uma única base, essa é necessariamente maior.
        """
        if not 0 < level < 1:
            raise ValueError("level deve estar entre 0 e 1")
        values = [
            value
            for value in (getattr(fold, metric) for fold in self.folds)
            if value is not None
        ]
        if not values:
            return (float("nan"), float("nan"))
        tail = (1.0 - level) / 2.0 * 100.0
        return (
            float(np.percentile(values, tail)),
            float(np.percentile(values, 100.0 - tail)),
        )

    def ppv_at_prevalence(self, prevalence: float = SCHOOL_PREVALENCE) -> float:
        """Valor preditivo positivo ajustado à prevalência real.

        Ver :func:`ppv_at_prevalence`.
        """
        return ppv_at_prevalence(
            self.mean("sensitivity"), self.mean("specificity"), prevalence
        )


def evaluate_fold(
    y_true: np.ndarray, y_pred: np.ndarray, y_score: np.ndarray | None
) -> FoldMetrics:
    """Calcula as métricas de uma partição.

    A matriz de confusão é montada diretamente, e não por
    ``sklearn.metrics.confusion_matrix``, para que a ordem das classes seja
    explícita mesmo quando uma delas não aparece na partição -- situação em que
    a função do scikit-learn devolve uma matriz 1x1 e desalinha o somatório.
    """
    y_true = np.asarray(y_true)
    y_pred = np.asarray(y_pred)

    tp = int(np.sum((y_true == DYSLEXIC) & (y_pred == DYSLEXIC)))
    tn = int(np.sum((y_true == TYPICAL) & (y_pred == TYPICAL)))
    fp = int(np.sum((y_true == TYPICAL) & (y_pred == DYSLEXIC)))
    fn = int(np.sum((y_true == DYSLEXIC) & (y_pred == TYPICAL)))

    total = tp + tn + fp + fn
    accuracy = (tp + tn) / total if total else 0.0
    sensitivity = tp / (tp + fn) if (tp + fn) else 0.0
    specificity = tn / (tn + fp) if (tn + fp) else 0.0
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    f1 = (
        2 * precision * sensitivity / (precision + sensitivity)
        if (precision + sensitivity)
        else 0.0
    )

    # A área sob a curva é indefinida quando a partição tem uma única classe.
    auc: float | None = None
    if y_score is not None and len(np.unique(y_true)) == 2:
        auc = float(roc_auc_score(y_true, y_score))

    return FoldMetrics(
        accuracy=accuracy,
        sensitivity=sensitivity,
        specificity=specificity,
        f1=f1,
        roc_auc=auc,
    )


def cross_validate(
    model: Pipeline,
    X: np.ndarray,
    y: np.ndarray,
    folds: list[Fold],
    model_name: str = "model",
) -> EvaluationResult:
    """Treina e avalia um modelo em cada partição.

    Cada partição recebe um clone do modelo. Reaproveitar a mesma instância
    deixaria o ajuste da partição anterior influenciar a seguinte.
    """
    from sklearn.base import clone

    result = EvaluationResult(model_name=model_name)

    for fold in folds:
        estimator = clone(model)
        estimator.fit(X[fold.train], y[fold.train])

        y_pred = estimator.predict(X[fold.test])
        y_score = _positive_scores(estimator, X[fold.test])

        metrics = evaluate_fold(y[fold.test], y_pred, y_score)
        result.folds.append(metrics)

        y_true_fold = y[fold.test]
        result.confusion += np.array(
            [
                [
                    int(np.sum((y_true_fold == TYPICAL) & (y_pred == TYPICAL))),
                    int(np.sum((y_true_fold == TYPICAL) & (y_pred == DYSLEXIC))),
                ],
                [
                    int(np.sum((y_true_fold == DYSLEXIC) & (y_pred == TYPICAL))),
                    int(np.sum((y_true_fold == DYSLEXIC) & (y_pred == DYSLEXIC))),
                ],
            ],
            dtype=int,
        )

    return result


def compare_models(
    X: np.ndarray,
    y: np.ndarray,
    groups: np.ndarray,
    n_splits: int = 5,
    n_repeats: int = 5,
    seed: int = 0,
) -> dict[str, EvaluationResult]:
    """Avalia todos os modelos sobre as mesmas partições.

    As partições são geradas uma única vez e compartilhadas: comparar modelos
    sobre divisões diferentes misturaria a diferença entre algoritmos com a
    diferença entre sorteios.
    """
    folds = subject_folds(y, groups, n_splits=n_splits, n_repeats=n_repeats, seed=seed)
    return {
        name: cross_validate(model, X, y, folds, model_name=name)
        for name, model in build_models(seed=seed).items()
    }


def ppv_at_prevalence(
    sensitivity: float, specificity: float, prevalence: float = SCHOOL_PREVALENCE
) -> float:
    """Valor preditivo positivo em uma população com a prevalência informada.

    A acurácia medida em uma base balanceada -- 35 casos e 35 controles, no
    ETDD70 -- não diz quantos falsos positivos esperar em uso real, onde a
    condição é minoritária. O valor preditivo positivo responde a essa
    pergunta: dado um resultado positivo, qual a probabilidade de a criança
    realmente ter a condição.

    A diferença é grande o bastante para mudar a leitura do resultado.
    Perochon et al. (2023) relatam área sob a curva de 0,90 e valor preditivo
    positivo de 63,4% em rastreio de autismo, mesmo combinando o resultado a um
    questionário validado.

    Args:
        sensitivity: proporção de casos corretamente identificados.
        specificity: proporção de controles corretamente identificados.
        prevalence: prevalência da condição na população de uso.

    Returns:
        O valor preditivo positivo, entre 0 e 1. Devolve ``0.0`` quando nenhum
        positivo é esperado.
    """
    for name, value in (
        ("sensitivity", sensitivity),
        ("specificity", specificity),
        ("prevalence", prevalence),
    ):
        if not 0.0 <= value <= 1.0:
            raise ValueError(f"{name} deve estar entre 0 e 1, recebido {value}")

    true_positives = sensitivity * prevalence
    false_positives = (1.0 - specificity) * (1.0 - prevalence)
    denominator = true_positives + false_positives
    return float(true_positives / denominator) if denominator else 0.0


def _positive_scores(estimator: Pipeline, X: np.ndarray) -> np.ndarray | None:
    """Pontuação contínua da classe positiva, quando o modelo oferece uma.

    Prefere ``predict_proba``; cai para ``decision_function``, cuja escala é
    arbitrária mas cuja ordenação basta para a área sob a curva.
    """
    if hasattr(estimator, "predict_proba"):
        proba = estimator.predict_proba(X)
        classes = list(estimator.classes_)
        if DYSLEXIC in classes:
            return proba[:, classes.index(DYSLEXIC)]
        return None
    if hasattr(estimator, "decision_function"):
        return np.asarray(estimator.decision_function(X))
    return None
