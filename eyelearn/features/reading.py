"""Engenharia de características do percurso de leitura.

Extrai as medidas descritas na seção 4.3 da metodologia. A escolha privilegia
características interpretáveis -- quantidade e duração das fixações, amplitude
das sacadas, proporção de regressões, tempo total -- seguindo Vajs et al.
(2023), que mostram que medidas desse tipo discriminam leitores disléxicos de
não disléxicos sem abrir mão da interpretação clínica.

Todas as características são taxas, médias ou proporções, nunca contagens
brutas. Contagem bruta cresce com a duração da gravação, e gravações de
duração diferente não seriam comparáveis entre participantes. O tempo total de
leitura entra como característica própria, não como escala das demais.
"""

from __future__ import annotations

import numpy as np

from eyelearn.signal.events import Fixation, Saccade

#: Ordem canônica das características. O vetor de entrada do modelo segue esta
#: ordem, e os testes verificam que ela não muda sem que os modelos treinados
#: sejam invalidados.
FEATURE_NAMES: tuple[str, ...] = (
    "fixation_rate",
    "fixation_duration_mean",
    "fixation_duration_std",
    "fixation_duration_median",
    "saccade_rate",
    "saccade_amplitude_mean",
    "saccade_amplitude_std",
    "progressive_amplitude_mean",
    "regression_ratio",
    "regression_rate",
    "peak_velocity_mean",
    "line_sweep_rate",
    "reading_time",
    "scanpath_length",
)


def extract(
    fixations: list[Fixation],
    saccades: list[Saccade],
    reading_time: float | None = None,
) -> dict[str, float]:
    """Calcula o vetor de características de uma gravação.

    Args:
        fixations: fixações em ordem temporal.
        saccades: sacadas em ordem temporal.
        reading_time: duração da tarefa em segundos. Quando omitida, é
            estimada pelo intervalo entre o início da primeira fixação e o fim
            da última -- o que subestima a duração real se a gravação começou
            ou terminou durante uma sacada, mas mantém a medida comparável
            entre participantes.

    Returns:
        Dicionário com uma entrada por nome em :data:`FEATURE_NAMES`.

    Note:
        Com listas vazias todas as características valem ``0.0``. A alternativa
        -- devolver ``NaN`` -- obrigaria o classificador a imputar valores, e o
        valor imputado diria mais sobre a imputação do que sobre o leitor. Uma
        gravação sem fixação detectada é um problema de qualidade de sinal e
        deve ser filtrada antes da modelagem, por
        :func:`eyelearn.signal.preprocess.valid_sample_ratio`.
    """
    span = _reading_time(fixations, reading_time)

    durations = np.array([f.duration for f in fixations], dtype=float)
    amplitudes = np.array([s.amplitude for s in saccades], dtype=float)
    peaks = np.array([s.peak_velocity for s in saccades], dtype=float)

    progressive = [s for s in saccades if s.kind == "progressive"]
    regressive = [s for s in saccades if s.kind == "regressive"]
    line_sweeps = [s for s in saccades if s.kind == "line_sweep"]

    # As regressões são medidas contra as sacadas dentro da linha: o retorno de
    # linha é obrigatório em qualquer leitor e, no denominador, diluiria a
    # diferença entre os grupos.
    within_line = len(progressive) + len(regressive)

    return {
        "fixation_rate": _rate(len(fixations), span),
        "fixation_duration_mean": _mean(durations),
        "fixation_duration_std": _std(durations),
        "fixation_duration_median": _median(durations),
        "saccade_rate": _rate(len(saccades), span),
        "saccade_amplitude_mean": _mean(amplitudes),
        "saccade_amplitude_std": _std(amplitudes),
        "progressive_amplitude_mean": _mean(
            np.array([s.amplitude for s in progressive], dtype=float)
        ),
        "regression_ratio": len(regressive) / within_line if within_line else 0.0,
        "regression_rate": _rate(len(regressive), span),
        "peak_velocity_mean": _mean(peaks),
        "line_sweep_rate": _rate(len(line_sweeps), span),
        "reading_time": span,
        "scanpath_length": float(np.sum(amplitudes)) if amplitudes.size else 0.0,
    }


def to_vector(features: dict[str, float]) -> np.ndarray:
    """Converte o dicionário de características no vetor na ordem canônica.

    Raises:
        KeyError: se faltar alguma característica de :data:`FEATURE_NAMES`.
    """
    missing = set(FEATURE_NAMES) - features.keys()
    if missing:
        raise KeyError(f"características ausentes: {sorted(missing)}")
    return np.array([features[name] for name in FEATURE_NAMES], dtype=float)


def to_matrix(rows: list[dict[str, float]]) -> np.ndarray:
    """Empilha vários vetores de características em uma matriz ``(n, d)``."""
    if not rows:
        return np.empty((0, len(FEATURE_NAMES)), dtype=float)
    return np.vstack([to_vector(row) for row in rows])


def _reading_time(fixations: list[Fixation], provided: float | None) -> float:
    if provided is not None:
        if provided < 0:
            raise ValueError("reading_time não pode ser negativo")
        return float(provided)
    if not fixations:
        return 0.0
    return float(fixations[-1].t_end - fixations[0].t_start)


def _rate(count: int, span: float) -> float:
    """Ocorrências por segundo, ou ``0.0`` quando não há intervalo medido."""
    return count / span if span > 0 else 0.0


def _mean(values: np.ndarray) -> float:
    return float(np.mean(values)) if values.size else 0.0


def _std(values: np.ndarray) -> float:
    return float(np.std(values)) if values.size else 0.0


def _median(values: np.ndarray) -> float:
    return float(np.median(values)) if values.size else 0.0
