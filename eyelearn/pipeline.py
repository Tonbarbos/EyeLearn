"""Encadeamento do pré-processamento à matriz de características.

Reúne as etapas da seção 4.3 em uma função só, para que o experimento de
degradação e o treino usem exatamente o mesmo caminho. Qualquer divergência
entre os dois invalidaria a comparação entre os níveis de degradação.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

import numpy as np

from eyelearn.degradation.degrade import DegradationLevel, degrade
from eyelearn.features import reading
from eyelearn.signal import events, preprocess
from eyelearn.trace import GazeTrace


@dataclass(frozen=True)
class PipelineConfig:
    """Parâmetros do caminho que vai do sinal bruto às características.

    Attributes:
        method: detector de eventos, ``"ivt"`` ou ``"idt"``.
        smoothing_window: janela da média móvel, em amostras.
        max_gap: intervalo máximo entre amostras consecutivas, em segundos.
        bounds_deg: limites da área de estímulo, em graus, ou ``None``.
        velocity_threshold: limiar do I-VT, em graus por segundo.
        dispersion_threshold: limiar do I-DT, em graus.
        min_fixation_duration: duração mínima de uma fixação, em segundos.
    """

    method: Literal["ivt", "idt"] = "ivt"
    smoothing_window: int = 5
    max_gap: float = 0.075
    bounds_deg: tuple[float, float] | None = None
    velocity_threshold: float = events.VELOCITY_THRESHOLD
    dispersion_threshold: float = events.DISPERSION_THRESHOLD
    min_fixation_duration: float = events.MIN_FIXATION_DURATION

    def detector_kwargs(self) -> dict[str, float]:
        """Parâmetros específicos do detector escolhido."""
        shared = {"min_fixation_duration": self.min_fixation_duration}
        if self.method == "ivt":
            return {**shared, "velocity_threshold": self.velocity_threshold}
        return {**shared, "dispersion_threshold": self.dispersion_threshold}


def trace_to_features(
    trace: GazeTrace,
    config: PipelineConfig | None = None,
) -> dict[str, float]:
    """Vai do percurso bruto ao dicionário de características.

    A ordem das etapas é a da metodologia: descarte das amostras inválidas,
    suavização, detecção de eventos e extração. O tempo de leitura passado ao
    extrator é a duração do percurso **antes** do descarte, que é a duração
    real da tarefa; medi-lo depois encurtaria a tarefa de quem perdeu mais
    amostras e distorceria todas as taxas.
    """
    config = config or PipelineConfig()
    task_duration = trace.duration

    cleaned = preprocess.drop_invalid(trace, config.bounds_deg)
    smoothed = preprocess.smooth(cleaned, config.smoothing_window)

    fixations, saccades = events.detect_events(
        smoothed,
        method=config.method,
        max_gap=config.max_gap,
        **config.detector_kwargs(),
    )
    return reading.extract(fixations, saccades, reading_time=task_duration)


def build_dataset(
    traces: list[GazeTrace],
    config: PipelineConfig | None = None,
    level: DegradationLevel | None = None,
    rng: np.random.Generator | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Monta a matriz de características de uma lista de percursos.

    Args:
        traces: percursos rotulados. Percursos sem rótulo são descartados, por
            não servirem a treino nem a avaliação supervisionada.
        config: parâmetros do pipeline.
        level: nível de degradação a aplicar antes da extração. ``None``
            preserva o sinal original.
        rng: gerador de números aleatórios da degradação.

    Returns:
        Tripla ``(X, y, groups)``, em que ``groups`` traz o identificador do
        participante de cada linha. ``groups`` é o que impede o vazamento na
        validação cruzada e precisa acompanhar ``X`` em todas as etapas.
    """
    config = config or PipelineConfig()

    rows: list[dict[str, float]] = []
    labels: list[int] = []
    groups: list[str] = []

    for trace in traces:
        if trace.label is None:
            continue
        prepared = trace if level is None else degrade(trace, level, rng)
        rows.append(trace_to_features(prepared, config))
        labels.append(trace.label)
        groups.append(trace.subject_id)

    return (
        reading.to_matrix(rows),
        np.array(labels, dtype=int),
        np.array(groups, dtype=object),
    )
