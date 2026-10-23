"""Geração de percursos sintéticos com estrutura conhecida.

A metodologia (seção 4.4) prevê testar o extrator de características com
percursos sintéticos, em que a quantidade de fixações e de sacadas é conhecida
de antemão. É a forma de obter um oráculo em um pipeline que, no dado real,
não tem nenhum: ninguém sabe quantas fixações "existem de verdade" em uma
gravação de webcam.

O gerador monta um percurso de leitura linha a linha: fixações sobre pontos
espaçados ao longo da linha, sacadas progressivas entre elas, regressões
opcionais e o retorno de linha no fim de cada linha.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from eyelearn.trace import GazeTrace


@dataclass(frozen=True)
class ScanpathSpec:
    """O que o percurso gerado contém, por construção.

    Serve de gabarito nos testes do detector de eventos e do extrator.

    Attributes:
        n_fixations: quantidade de fixações.
        n_saccades: quantidade de sacadas, sempre ``n_fixations - 1``.
        n_regressions: sacadas contrárias ao sentido da leitura, sem contar os
            retornos de linha.
        n_line_sweeps: retornos de linha.
        fixation_duration: duração de cada fixação, em segundos.
        saccade_amplitude: amplitude de cada sacada progressiva, em graus.
    """

    n_fixations: int
    n_saccades: int
    n_regressions: int
    n_line_sweeps: int
    fixation_duration: float
    saccade_amplitude: float


def reading_trace(
    n_lines: int = 3,
    fixations_per_line: int = 8,
    fixation_duration: float = 0.25,
    saccade_duration: float = 0.03,
    saccade_amplitude: float = 2.0,
    line_spacing: float = 1.5,
    sampling_rate: float = 250.0,
    n_regressions: int = 0,
    jitter_deg: float = 0.02,
    subject_id: str = "synthetic",
    label: int | None = None,
    rng: np.random.Generator | None = None,
) -> tuple[GazeTrace, ScanpathSpec]:
    """Gera um percurso de leitura com estrutura conhecida.

    As regressões são inseridas de forma determinística, distribuídas entre as
    fixações de dentro das linhas, para que o gabarito não dependa de sorteio.
    O ruído aleatório entra apenas no tremor dentro das fixações.

    Args:
        n_lines: quantidade de linhas de texto.
        fixations_per_line: fixações progressivas em cada linha.
        fixation_duration: duração de cada fixação, em segundos.
        saccade_duration: duração de cada sacada, em segundos.
        saccade_amplitude: amplitude das sacadas progressivas, em graus.
        line_spacing: distância vertical entre linhas, em graus. Precisa ser
            maior que o limiar de descida de
            :func:`eyelearn.signal.events.classify_saccade` para que o retorno
            de linha seja reconhecido como tal.
        sampling_rate: taxa de amostragem, em Hz.
        n_regressions: quantidade de regressões a inserir.
        jitter_deg: desvio padrão do tremor dentro das fixações, em graus.
            Precisa ficar baixo o bastante para não atravessar o limiar de
            velocidade do I-VT e fragmentar a fixação.
        subject_id: identificador do participante sintético.
        label: rótulo de classe, quando o percurso for usado em treino.
        rng: gerador de números aleatórios.

    Returns:
        Par ``(percurso, gabarito)``.
    """
    if n_lines < 1 or fixations_per_line < 1:
        raise ValueError("n_lines e fixations_per_line devem ser positivos")
    if fixation_duration <= 0 or saccade_duration <= 0:
        raise ValueError("as durações devem ser positivas")
    if sampling_rate <= 0:
        raise ValueError("sampling_rate deve ser positiva")
    if n_regressions < 0:
        raise ValueError("n_regressions não pode ser negativo")

    rng = rng if rng is not None else np.random.default_rng(0)
    positions = _reading_positions(
        n_lines, fixations_per_line, saccade_amplitude, line_spacing, n_regressions
    )

    dt = 1.0 / sampling_rate
    samples_per_fixation = max(int(round(fixation_duration / dt)), 1)
    samples_per_saccade = max(int(round(saccade_duration / dt)), 1)

    t_values: list[np.ndarray] = []
    x_values: list[np.ndarray] = []
    y_values: list[np.ndarray] = []
    clock = 0.0

    for index, (cx, cy) in enumerate(positions):
        # Fixação: amostras em torno do centro, com tremor.
        count = samples_per_fixation
        t_values.append(clock + np.arange(count) * dt)
        x_values.append(cx + rng.normal(0.0, jitter_deg, count))
        y_values.append(cy + rng.normal(0.0, jitter_deg, count))
        clock += count * dt

        if index + 1 >= len(positions):
            break

        # Sacada: interpolação linear até a fixação seguinte. Os pontos
        # intermediários excluem as duas pontas, que já pertencem às fixações.
        nx, ny = positions[index + 1]
        count = samples_per_saccade
        steps = np.arange(1, count + 1) / (count + 1)
        t_values.append(clock + np.arange(count) * dt)
        x_values.append(cx + (nx - cx) * steps)
        y_values.append(cy + (ny - cy) * steps)
        clock += count * dt

    n_fixations = len(positions)
    assert n_fixations == n_lines * fixations_per_line + 2 * n_regressions
    spec = ScanpathSpec(
        n_fixations=n_fixations,
        n_saccades=n_fixations - 1,
        n_regressions=n_regressions,
        n_line_sweeps=n_lines - 1,
        fixation_duration=fixation_duration,
        saccade_amplitude=saccade_amplitude,
    )

    trace = GazeTrace(
        t=np.concatenate(t_values),
        x=np.concatenate(x_values),
        y=np.concatenate(y_values),
        subject_id=subject_id,
        task="synthetic_reading",
        label=label,
    )
    return trace, spec


def _reading_positions(
    n_lines: int,
    fixations_per_line: int,
    saccade_amplitude: float,
    line_spacing: float,
    n_regressions: int,
) -> list[tuple[float, float]]:
    """Centros das fixações, na ordem em que o olhar os visita.

    As regressões são posicionadas nas primeiras oportunidades disponíveis
    dentro das linhas. Cada uma reproduz o padrão de releitura: o olhar volta
    uma amplitude inteira, até a fixação anterior, e em seguida avança de volta
    ao ponto de onde saiu. Assim toda sacada do percurso tem a mesma amplitude,
    e cada regressão acrescenta duas fixações e duas sacadas -- uma regressiva
    e uma progressiva.

    A amplitude cheia, e não meia amplitude, é o que mantém a sacada regressiva
    acima do limiar de velocidade do I-VT: meia amplitude na duração padrão
    resulta em cerca de 28 graus por segundo, abaixo do limiar de 30, e a
    regressão passaria despercebida pelo detector.

    O retorno de linha leva ao início da linha seguinte.
    """
    line_starts = [(0.0, line * line_spacing) for line in range(n_lines)]
    opportunities = _regression_slots(n_lines, fixations_per_line, n_regressions)

    positions: list[tuple[float, float]] = []
    for line, (x0, y) in enumerate(line_starts):
        x = x0
        for step in range(fixations_per_line):
            positions.append((x, y))
            if (line, step) in opportunities:
                positions.append((x - saccade_amplitude, y))
                positions.append((x, y))
            x += saccade_amplitude
    return positions


def _regression_slots(
    n_lines: int, fixations_per_line: int, n_regressions: int
) -> set[tuple[int, int]]:
    """Posições ``(linha, passo)`` que recebem uma regressão.

    Uma regressão só pode ser inserida depois da primeira fixação da linha --
    não há para onde voltar a partir do início -- e não na última, cuja sacada
    seguinte é o retorno de linha.
    """
    slots = [
        (line, step)
        for line in range(n_lines)
        for step in range(1, max(fixations_per_line - 1, 1))
    ]
    if n_regressions > len(slots):
        raise ValueError(
            f"não cabem {n_regressions} regressões em {n_lines} linha(s) de "
            f"{fixations_per_line} fixações: no máximo {len(slots)}"
        )
    return set(slots[:n_regressions])
