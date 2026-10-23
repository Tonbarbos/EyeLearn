"""Experimento da curva de degradação.

Mede a acurácia de classificação em função da qualidade do sinal de aquisição,
respondendo à pergunta central do projeto: até que ponto uma solução de baixo
custo se sustenta.

Para cada nível de degradação, o percurso é degradado, as características são
extraídas de novo e os modelos são reavaliados sobre as mesmas partições de
participantes. A extração precisa ser repetida a cada nível porque a
degradação atua no sinal, antes da detecção de eventos -- reaproveitar as
características do sinal original mediria apenas o efeito do ruído sobre o
classificador, e não sobre o pipeline, que é o que se quer medir.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from eyelearn.degradation.degrade import DegradationLevel, webcam_grid
from eyelearn.models.train import compare_models
from eyelearn.pipeline import PipelineConfig, build_dataset
from eyelearn.trace import GazeTrace


def run_degradation_curve(
    traces: list[GazeTrace],
    levels: list[DegradationLevel] | None = None,
    config: PipelineConfig | None = None,
    n_splits: int = 5,
    n_repeats: int = 5,
    seed: int = 0,
) -> pd.DataFrame:
    """Avalia os modelos em cada nível de degradação.

    A semente do gerador de ruído é derivada do índice do nível, de modo que
    cada nível use uma realização diferente do ruído e a execução inteira
    continue reprodutível.

    Args:
        traces: percursos rotulados da base.
        levels: níveis a percorrer. O padrão é :func:`webcam_grid`.
        config: parâmetros do pipeline de características.
        n_splits: partições por repetição da validação cruzada.
        n_repeats: repetições da validação cruzada.
        seed: semente base.

    Returns:
        Tabela com uma linha por par (nível, modelo) e as colunas de métricas,
        com os limites do intervalo de confiança e o valor preditivo positivo
        ajustado à prevalência.
    """
    levels = levels if levels is not None else webcam_grid()
    config = config or PipelineConfig()

    rows = []
    for index, level in enumerate(levels):
        rng = np.random.default_rng(seed + index)
        X, y, groups = build_dataset(traces, config=config, level=level, rng=rng)

        if X.shape[0] == 0:
            raise ValueError(
                "nenhum percurso rotulado disponível; verifique os rótulos da base"
            )

        results = compare_models(
            X, y, groups, n_splits=n_splits, n_repeats=n_repeats, seed=seed
        )

        for name, result in results.items():
            low, high = result.confidence_interval("accuracy")
            rows.append(
                {
                    "level": level.label,
                    "sampling_rate_hz": level.sampling_rate_hz,
                    "noise_sigma_deg": level.noise_sigma_deg,
                    "model": name,
                    "accuracy": result.mean("accuracy"),
                    "accuracy_ci_low": low,
                    "accuracy_ci_high": high,
                    "sensitivity": result.mean("sensitivity"),
                    "specificity": result.mean("specificity"),
                    "f1": result.mean("f1"),
                    "roc_auc": result.mean("roc_auc"),
                    "ppv_at_prevalence": result.ppv_at_prevalence(),
                }
            )

    return pd.DataFrame(rows)


def accuracy_drop(curve: pd.DataFrame, model: str) -> pd.DataFrame:
    """Queda de acurácia de cada nível em relação ao sinal original.

    Args:
        curve: saída de :func:`run_degradation_curve`.
        model: nome do modelo a isolar.

    Returns:
        Tabela com as colunas ``level``, ``accuracy`` e ``drop``, em que
        ``drop`` é a diferença em pontos percentuais em relação à primeira
        linha -- o sinal original.

    Raises:
        ValueError: se o modelo não constar da tabela.
    """
    subset = curve[curve["model"] == model]
    if subset.empty:
        available = sorted(curve["model"].unique())
        raise ValueError(f"modelo {model!r} ausente da curva; disponíveis: {available}")

    baseline = float(subset.iloc[0]["accuracy"])
    return pd.DataFrame(
        {
            "level": subset["level"].to_numpy(),
            "accuracy": subset["accuracy"].to_numpy(),
            "drop": (baseline - subset["accuracy"].to_numpy()) * 100.0,
        }
    )
