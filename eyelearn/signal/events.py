"""Detecção de fixações e sacadas.

Implementa os dois algoritmos comparados por Salvucci e Goldberg (2000):

* **I-VT** (*velocity threshold*): classifica cada amostra pela velocidade
  angular instantânea. Barato e sensível à amostragem.
* **I-DT** (*dispersion threshold*): procura janelas temporais em que o olhar
  permanece dentro de uma área pequena. Mais robusto a ruído, por não derivar
  o sinal, e por isso relevante para o experimento de degradação da seção 4.3.

Os dois recebem um percurso com amostragem contínua. Buracos deixados por
piscadas devem ser separados antes, por
:func:`eyelearn.signal.preprocess.split_on_gaps`; :func:`detect_events` faz
isso automaticamente.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

import numpy as np

from eyelearn.signal import preprocess
from eyelearn.trace import GazeTrace

#: Duração mínima aceita para uma fixação, em segundos. Fixações de leitura em
#: crianças ficam entre 150 e 400 ms; o piso de 60 ms descarta agrupamentos
#: espúrios sem cortar fixações curtas legítimas.
MIN_FIXATION_DURATION = 0.06

#: Limiar de velocidade do I-VT, em graus por segundo.
VELOCITY_THRESHOLD = 30.0

#: Limiar de dispersão do I-DT, em graus.
DISPERSION_THRESHOLD = 1.0

SaccadeKind = Literal["progressive", "regressive", "line_sweep"]


@dataclass(frozen=True)
class Fixation:
    """Período em que o olhar permanece parado sobre uma região.

    Attributes:
        t_start: início, em segundos.
        t_end: fim, em segundos.
        x: centroide horizontal, em graus.
        y: centroide vertical, em graus.
        n_samples: quantidade de amostras que a compõem.
    """

    t_start: float
    t_end: float
    x: float
    y: float
    n_samples: int

    @property
    def duration(self) -> float:
        return self.t_end - self.t_start


@dataclass(frozen=True)
class Saccade:
    """Movimento rápido entre duas fixações consecutivas.

    Attributes:
        t_start: fim da fixação anterior, em segundos.
        t_end: início da fixação seguinte, em segundos.
        dx: deslocamento horizontal entre os centroides, em graus. Positivo
            para a direita, o sentido da leitura.
        dy: deslocamento vertical, em graus. Positivo para baixo.
        peak_velocity: maior velocidade angular observada no trajeto, em
            graus por segundo.
        kind: classificação do movimento, ver :func:`classify_saccade`.
    """

    t_start: float
    t_end: float
    dx: float
    dy: float
    peak_velocity: float
    kind: SaccadeKind

    @property
    def duration(self) -> float:
        return self.t_end - self.t_start

    @property
    def amplitude(self) -> float:
        """Distância euclidiana percorrida, em graus."""
        return float(np.hypot(self.dx, self.dy))


def ivt(
    trace: GazeTrace,
    velocity_threshold: float = VELOCITY_THRESHOLD,
    min_fixation_duration: float = MIN_FIXATION_DURATION,
) -> list[Fixation]:
    """Detecta fixações por limiar de velocidade (I-VT).

    Args:
        trace: segmento de amostragem contínua.
        velocity_threshold: velocidade acima da qual a amostra é considerada
            parte de uma sacada, em graus por segundo.
        min_fixation_duration: duração mínima para que um grupo de amostras
            lentas conte como fixação, em segundos.

    Returns:
        Fixações em ordem temporal.
    """
    if velocity_threshold <= 0:
        raise ValueError("velocity_threshold deve ser positivo")
    if min_fixation_duration < 0:
        raise ValueError("min_fixation_duration não pode ser negativo")
    if len(trace) < 2:
        return []

    slow = preprocess.velocity(trace) <= velocity_threshold

    fixations = []
    for start, stop in _runs(slow):
        candidate = _fixation_from_slice(trace, start, stop)
        if candidate.duration >= min_fixation_duration:
            fixations.append(candidate)
    return fixations


def idt(
    trace: GazeTrace,
    dispersion_threshold: float = DISPERSION_THRESHOLD,
    min_fixation_duration: float = MIN_FIXATION_DURATION,
) -> list[Fixation]:
    """Detecta fixações por limiar de dispersão (I-DT).

    Percorre o percurso com uma janela que começa com a duração mínima e cresce
    enquanto o olhar couber na área permitida. Quando a janela estoura o limiar,
    a fixação é fechada e a busca recomeça do fim dela.

    A dispersão é medida como ``(max(x) - min(x)) + (max(y) - min(y))``, a
    definição usada por Salvucci e Goldberg (2000).

    A janela maximal é recortada antes de virar fixação, por
    :func:`_compact_core`. A formulação original não faz esse recorte e, com
    isso, fragmenta sistematicamente o percurso: a janela cresce até entrar na
    sacada seguinte, de modo que a fixação emitida termina no meio da sacada e
    a busca recomeça dali. A janela seguinte abrange o resto da sacada mais o
    início da fixação de destino, cuja dispersão somada ainda cabe no limiar --
    e uma fixação única acaba reportada como duas, com os centroides
    deslocados na direção da sacada.

    Args:
        trace: segmento de amostragem contínua.
        dispersion_threshold: dispersão máxima tolerada dentro de uma fixação,
            em graus.
        min_fixation_duration: duração mínima da janela inicial, em segundos.

    Returns:
        Fixações em ordem temporal.
    """
    if dispersion_threshold <= 0:
        raise ValueError("dispersion_threshold deve ser positivo")
    if min_fixation_duration < 0:
        raise ValueError("min_fixation_duration não pode ser negativo")

    n = len(trace)
    if n < 2:
        return []

    fixations: list[Fixation] = []
    start = 0

    while start < n:
        stop = _window_reaching_duration(trace, start, min_fixation_duration)
        if stop is None:
            # Não há amostras suficientes até o fim do segmento para formar
            # outra fixação de duração mínima.
            break

        if _dispersion(trace, start, stop) > dispersion_threshold:
            start += 1
            continue

        radius = dispersion_threshold / 2.0

        # A janela mínima cabe no limiar, mas pode começar dentro da sacada
        # anterior. Ancorar no agrupamento antes de crescer evita que essas
        # amostras consumam o orçamento de dispersão e truncem a fixação.
        anchored = _compact_core(trace, start, stop, radius)
        if anchored is None:
            start += 1
            continue

        anchor = anchored[0]
        stop = max(anchored[1], anchor + 2)
        while stop < n and _dispersion(trace, anchor, stop + 1) <= dispersion_threshold:
            stop += 1

        core = _compact_core(trace, anchor, stop, radius)
        if core is None:
            start += 1
            continue

        core_start, core_stop = core
        candidate = _fixation_from_slice(trace, core_start, core_stop)
        if candidate.duration >= min_fixation_duration and core_stop > start:
            fixations.append(candidate)
            start = core_stop
        else:
            # Garante avanço mesmo quando o recorte não produz uma fixação
            # aceitável, para que o laço sempre termine.
            start += 1

    return fixations


def saccades_between(trace: GazeTrace, fixations: list[Fixation]) -> list[Saccade]:
    """Deriva as sacadas dos intervalos entre fixações consecutivas.

    As sacadas não são detectadas diretamente: o que sobra entre duas fixações
    é, por definição, o movimento que levou de uma à outra. A velocidade de
    pico é lida das amostras do intervalo; quando o intervalo não contém
    nenhuma amostra, ela é estimada pela razão entre amplitude e duração.
    """
    if len(fixations) < 2:
        return []

    v = preprocess.velocity(trace)
    saccades = []

    for previous, following in zip(fixations, fixations[1:], strict=False):
        dx = following.x - previous.x
        dy = following.y - previous.y
        duration = following.t_start - previous.t_end

        in_transit = (trace.t > previous.t_end) & (trace.t < following.t_start)
        if np.any(in_transit):
            peak = float(np.max(v[in_transit]))
        elif duration > 0:
            peak = float(np.hypot(dx, dy) / duration)
        else:
            peak = 0.0

        saccades.append(
            Saccade(
                t_start=previous.t_end,
                t_end=following.t_start,
                dx=float(dx),
                dy=float(dy),
                peak_velocity=peak,
                kind=classify_saccade(float(dx), float(dy)),
            )
        )

    return saccades


def classify_saccade(
    dx: float,
    dy: float,
    min_regression_amplitude: float = 0.5,
    line_sweep_descent: float = 0.75,
) -> SaccadeKind:
    """Classifica uma sacada segundo o sentido da leitura.

    A distinção importa para a proporção de regressões, uma das características
    mais discriminantes na literatura de dislexia. O retorno de linha também é
    um movimento grande para a esquerda, mas não é uma regressão: é o salto
    normal para o início da linha seguinte. Contá-lo como regressão inflaria a
    medida em todo leitor, apagando a diferença entre os grupos.

    Args:
        dx: deslocamento horizontal em graus, positivo para a direita.
        dy: deslocamento vertical em graus, positivo para baixo.
        min_regression_amplitude: deslocamento mínimo para a esquerda, em
            graus, abaixo do qual o movimento é ruído de centroide e não
            regressão.
        line_sweep_descent: descida mínima, em graus, para que uma sacada à
            esquerda seja lida como retorno de linha.

    Returns:
        ``"line_sweep"`` para o retorno de linha, ``"regressive"`` para o
        movimento contrário ao sentido da leitura dentro da mesma linha e
        ``"progressive"`` para o restante.
    """
    if dx < -min_regression_amplitude:
        if dy > line_sweep_descent:
            return "line_sweep"
        return "regressive"
    return "progressive"


def detect_events(
    trace: GazeTrace,
    method: Literal["ivt", "idt"] = "ivt",
    max_gap: float = 0.075,
    **kwargs: float,
) -> tuple[list[Fixation], list[Saccade]]:
    """Detecta fixações e sacadas em um percurso, respeitando os buracos.

    Parte o percurso nos intervalos sem amostra, roda o detector em cada
    segmento e junta os eventos. Nenhuma sacada é criada atravessando um
    buraco: o deslocamento observado ali não corresponde a um movimento
    rastreado.

    Args:
        trace: percurso já limpo por
            :func:`eyelearn.signal.preprocess.drop_invalid`.
        method: ``"ivt"`` ou ``"idt"``.
        max_gap: intervalo máximo entre amostras consecutivas, em segundos.
        **kwargs: parâmetros repassados ao detector escolhido.

    Returns:
        Par ``(fixações, sacadas)`` em ordem temporal.
    """
    detector = {"ivt": ivt, "idt": idt}.get(method)
    if detector is None:
        raise ValueError(f"método desconhecido: {method!r}; use 'ivt' ou 'idt'")

    all_fixations: list[Fixation] = []
    all_saccades: list[Saccade] = []

    for segment in preprocess.split_on_gaps(trace, max_gap):
        fixations = detector(segment, **kwargs)  # type: ignore[operator]
        all_fixations.extend(fixations)
        all_saccades.extend(saccades_between(segment, fixations))

    return all_fixations, all_saccades


def _runs(mask: np.ndarray) -> list[tuple[int, int]]:
    """Intervalos ``[start, stop)`` de valores ``True`` consecutivos."""
    if not np.any(mask):
        return []
    # A diferença da máscara estendida com False nas pontas marca cada
    # transição; os +1 e -1 identificam onde cada corrida abre e fecha.
    padded = np.concatenate(([False], mask, [False]))
    changes = np.diff(padded.astype(np.int8))
    starts = np.flatnonzero(changes == 1)
    stops = np.flatnonzero(changes == -1)
    return list(zip(starts.tolist(), stops.tolist(), strict=True))


def _fixation_from_slice(trace: GazeTrace, start: int, stop: int) -> Fixation:
    """Monta uma fixação a partir do intervalo ``[start, stop)``."""
    return Fixation(
        t_start=float(trace.t[start]),
        t_end=float(trace.t[stop - 1]),
        x=float(np.mean(trace.x[start:stop])),
        y=float(np.mean(trace.y[start:stop])),
        n_samples=stop - start,
    )


def _dispersion(trace: GazeTrace, start: int, stop: int) -> float:
    """Dispersão do intervalo ``[start, stop)``, em graus."""
    xs = trace.x[start:stop]
    ys = trace.y[start:stop]
    return float((xs.max() - xs.min()) + (ys.max() - ys.min()))


def _compact_core(
    trace: GazeTrace, start: int, stop: int, radius: float
) -> tuple[int, int] | None:
    """Maior trecho contíguo de ``[start, stop)`` agrupado em torno do centro.

    Toma a mediana das coordenadas da janela como centro e mantém as amostras
    a menos de ``radius`` dela. A mediana é preferível à média porque as
    amostras da fixação são maioria na janela, o que coloca a mediana dentro do
    agrupamento mesmo quando a janela já invadiu a sacada -- a média seria
    puxada para fora por ela.

    Returns:
        Par ``[core_start, core_stop)``, ou ``None`` se nenhuma amostra ficar
        dentro do raio.
    """
    xs = trace.x[start:stop]
    ys = trace.y[start:stop]
    inside = np.hypot(xs - np.median(xs), ys - np.median(ys)) <= radius

    runs = _runs(inside)
    if not runs:
        return None

    run_start, run_stop = max(runs, key=lambda run: run[1] - run[0])
    return start + run_start, start + run_stop


def _window_reaching_duration(
    trace: GazeTrace, start: int, min_duration: float
) -> int | None:
    """Menor ``stop`` tal que ``[start, stop)`` cubra ``min_duration``.

    Devolve ``None`` quando não restam amostras suficientes até o fim do
    segmento. Com ``min_duration`` igual a zero, a janela mínima é de duas
    amostras, para que exista dispersão a medir.
    """
    n = len(trace)
    target = trace.t[start] + min_duration
    stop = int(np.searchsorted(trace.t, target, side="left")) + 1
    stop = max(stop, start + 2)
    return stop if stop <= n else None
