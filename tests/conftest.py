"""Fixtures compartilhadas.

Os testes não dependem do ETDD70. A base não é redistribuível e exigiria
download para rodar a integração contínua; no lugar dela, os percursos
sintéticos de :mod:`eyelearn.synthetic` fornecem o gabarito que o dado real
não tem.
"""

from __future__ import annotations

import numpy as np
import pytest

from eyelearn.synthetic import reading_trace
from eyelearn.trace import DYSLEXIC, TYPICAL, GazeTrace


@pytest.fixture
def rng() -> np.random.Generator:
    """Gerador semeado, para que as falhas sejam reproduzíveis."""
    return np.random.default_rng(20251012)


@pytest.fixture
def clean_trace() -> GazeTrace:
    """Percurso de leitura sem regressões, com estrutura conhecida."""
    trace, _ = reading_trace(n_lines=3, fixations_per_line=8, n_regressions=0)
    return trace


#: Perfis das duas populações sintéticas: média e desvio da duração das
#: fixações, em segundos, e faixa de regressões por gravação.
_PROFILES = {
    TYPICAL: {"duration": (0.235, 0.025), "regressions": (0, 3)},
    DYSLEXIC: {"duration": (0.275, 0.025), "regressions": (2, 6)},
}


def make_cohort(
    n_per_group: int = 12,
    seed: int = 0,
) -> list[GazeTrace]:
    """Monta uma coorte sintética rotulada, com três tarefas por participante.

    O grupo disléxico recebe mais regressões e fixações mais longas, o padrão
    descrito na literatura de leitura. O objetivo não é simular dislexia de
    forma fiel -- isso nenhum gerador faz -- mas produzir duas populações
    parcialmente separáveis, suficientes para exercitar a validação cruzada,
    as relações metamórficas e o teste de vazamento.

    As duas distribuições se sobrepõem de propósito. Com populações
    perfeitamente separáveis, qualquer classificador acerta tudo, e os testes
    que dependem de erro -- robustez a ruído, efeito do vazamento, queda por
    degradação -- passariam sem exercitar nada.

    Cada participante tem seu próprio nível de dificuldade, sorteado uma vez e
    reaproveitado nas três tarefas. É isso que reproduz a estrutura do ETDD70 e
    torna o vazamento por sujeito possível: sem variação individual, as três
    gravações de um participante não carregariam nada que o identifique.
    """
    master = np.random.default_rng(seed)
    traces: list[GazeTrace] = []

    for label in (TYPICAL, DYSLEXIC):
        profile = _PROFILES[label]
        mean_duration, spread = profile["duration"]
        low, high = profile["regressions"]

        for index in range(n_per_group):
            subject_id = f"{'D' if label == DYSLEXIC else 'T'}{index:02d}"
            subject_duration = float(master.normal(mean_duration, spread))
            subject_regressions = int(master.integers(low, high + 1))

            for task in ("syllables", "text", "pseudotext"):
                trace, _ = reading_trace(
                    n_lines=3,
                    fixations_per_line=8,
                    fixation_duration=max(
                        subject_duration + float(master.normal(0.0, 0.008)), 0.1
                    ),
                    n_regressions=subject_regressions,
                    subject_id=subject_id,
                    label=label,
                    rng=np.random.default_rng(master.integers(1 << 32)),
                )
                traces.append(
                    GazeTrace(
                        t=trace.t,
                        x=trace.x,
                        y=trace.y,
                        subject_id=subject_id,
                        task=task,
                        label=label,
                    )
                )

    return traces


@pytest.fixture(scope="module")
def cohort() -> list[GazeTrace]:
    """Coorte sintética rotulada, reaproveitada entre os testes do módulo."""
    return make_cohort()
