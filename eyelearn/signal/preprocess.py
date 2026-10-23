"""Pré-processamento do sinal do olhar.

Cobre a primeira etapa da seção 4.3 da metodologia: descarte das amostras
perdidas por piscadas e falhas de rastreamento, conversão de unidades e
suavização das séries de coordenadas.
"""

from __future__ import annotations

import numpy as np

from eyelearn.trace import GazeTrace


def pixels_to_degrees(
    x_px: np.ndarray,
    y_px: np.ndarray,
    screen_width_px: int,
    screen_height_px: int,
    screen_width_cm: float,
    viewing_distance_cm: float,
) -> tuple[np.ndarray, np.ndarray]:
    """Converte coordenadas de tela em graus de ângulo visual.

    A conversão toma o centro da tela como origem e usa a aproximação de
    pequeno ângulo apenas na derivada: cada eixo é convertido por arco-tangente
    da distância física até o centro, o que mantém o erro baixo também nas
    bordas de uma tela grande.

    Args:
        x_px: coordenada horizontal em pixels.
        y_px: coordenada vertical em pixels.
        screen_width_px: largura da tela em pixels.
        screen_height_px: altura da tela em pixels.
        screen_width_cm: largura física da tela em centímetros.
        viewing_distance_cm: distância entre o olho e a tela em centímetros.

    Returns:
        Par ``(x_deg, y_deg)`` com a origem no centro da tela.
    """
    if screen_width_px <= 0 or screen_height_px <= 0:
        raise ValueError("as dimensões da tela em pixels devem ser positivas")
    if screen_width_cm <= 0:
        raise ValueError("a largura física da tela deve ser positiva")
    if viewing_distance_cm <= 0:
        raise ValueError("a distância de visualização deve ser positiva")

    cm_per_px = screen_width_cm / screen_width_px
    dx_cm = (np.asarray(x_px, dtype=float) - screen_width_px / 2.0) * cm_per_px
    dy_cm = (np.asarray(y_px, dtype=float) - screen_height_px / 2.0) * cm_per_px

    x_deg = np.degrees(np.arctan2(dx_cm, viewing_distance_cm))
    y_deg = np.degrees(np.arctan2(dy_cm, viewing_distance_cm))
    return x_deg, y_deg


def invalid_mask(
    trace: GazeTrace,
    bounds_deg: tuple[float, float] | None = None,
) -> np.ndarray:
    """Marca as amostras que não representam olhar válido.

    São inválidas as amostras não finitas (as gravações costumam codificar
    piscada como ``NaN`` ou ``0``) e, quando ``bounds_deg`` é informado, as que
    caem fora da área de estímulo.

    Args:
        trace: percurso a inspecionar.
        bounds_deg: par ``(meia_largura, meia_altura)`` em graus. Amostras com
            ``|x| > meia_largura`` ou ``|y| > meia_altura`` são descartadas.

    Returns:
        Máscara booleana ``True`` nas amostras inválidas.
    """
    bad = ~np.isfinite(trace.x) | ~np.isfinite(trace.y)

    if bounds_deg is not None:
        half_w, half_h = bounds_deg
        if half_w <= 0 or half_h <= 0:
            raise ValueError("os limites da área de estímulo devem ser positivos")
        with np.errstate(invalid="ignore"):
            bad |= np.abs(trace.x) > half_w
            bad |= np.abs(trace.y) > half_h

    return bad


def drop_invalid(
    trace: GazeTrace,
    bounds_deg: tuple[float, float] | None = None,
) -> GazeTrace:
    """Remove as amostras inválidas do percurso.

    As amostras são removidas, e não interpoladas: a interpolação sobre uma
    piscada inteira inventa uma trajetória que o olho não percorreu e produz
    sacadas falsas na detecção de eventos. O vetor de tempos preserva o buraco,
    e os algoritmos de detecção o tratam por :func:`split_on_gaps`.
    """
    keep = ~invalid_mask(trace, bounds_deg)
    return GazeTrace(
        t=trace.t[keep],
        x=trace.x[keep],
        y=trace.y[keep],
        subject_id=trace.subject_id,
        task=trace.task,
        label=trace.label,
    )


def valid_sample_ratio(
    trace: GazeTrace,
    bounds_deg: tuple[float, float] | None = None,
) -> float:
    """Proporção de amostras válidas, usada como indicador de qualidade.

    Gravações com proporção baixa indicam perda de rastreamento e devem ser
    descartadas antes da modelagem.
    """
    if len(trace) == 0:
        return 0.0
    return float(np.mean(~invalid_mask(trace, bounds_deg)))


def split_on_gaps(trace: GazeTrace, max_gap: float = 0.075) -> list[GazeTrace]:
    """Parte o percurso nos buracos deixados pelas amostras descartadas.

    Depois de :func:`drop_invalid` o vetor de tempos deixa de ser uniforme. Um
    intervalo longo entre duas amostras consecutivas não é um movimento do
    olho, e calcular velocidade sobre ele geraria uma sacada inexistente. Cada
    segmento devolvido tem amostragem contínua e pode ser analisado isoladamente.

    Args:
        trace: percurso já limpo.
        max_gap: intervalo máximo tolerado entre amostras consecutivas, em
            segundos. O padrão de 75 ms acomoda a perda de poucas amostras sem
            atravessar uma piscada completa, que dura de 100 a 400 ms.

    Returns:
        Lista de segmentos contínuos, na ordem original. Segmentos com menos de
        duas amostras são descartados, por não admitirem cálculo de velocidade.
    """
    if max_gap <= 0:
        raise ValueError("max_gap deve ser positivo")
    if len(trace) < 2:
        return [trace] if len(trace) else []

    breaks = np.flatnonzero(np.diff(trace.t) > max_gap) + 1
    edges = [0, *breaks.tolist(), len(trace)]

    return [
        trace.slice(start, stop)
        for start, stop in zip(edges[:-1], edges[1:], strict=True)
        if stop - start >= 2
    ]


def smooth(trace: GazeTrace, window: int = 5) -> GazeTrace:
    """Suaviza as coordenadas por média móvel centrada.

    Reduz o tremor de alta frequência do rastreador, que de outro modo
    atravessa o limiar de velocidade do I-VT e fragmenta uma fixação única em
    várias. A janela precisa ser ímpar para que a média fique centrada na
    amostra, sem deslocar o sinal no tempo.

    Nas bordas a janela encurta em vez de recorrer a preenchimento: repetir a
    primeira amostra puxaria a trajetória para ela e achataria a primeira
    sacada.

    Args:
        trace: percurso a suavizar.
        window: tamanho da janela em amostras, ímpar e maior ou igual a 1.
            ``window=1`` devolve o sinal inalterado.
    """
    if window < 1 or window % 2 == 0:
        raise ValueError(f"window deve ser ímpar e positivo, recebido {window}")
    if window == 1 or len(trace) == 0:
        return trace

    return trace.with_coordinates(
        _moving_average(trace.x, window),
        _moving_average(trace.y, window),
    )


def _moving_average(values: np.ndarray, window: int) -> np.ndarray:
    """Média móvel centrada com janela encurtada nas bordas."""
    half = window // 2
    n = values.size
    # Soma acumulada com zero à esquerda permite somar qualquer intervalo em
    # tempo constante; os limites são recortados ao tamanho do array, e a
    # divisão usa a contagem real de elementos de cada janela.
    cumsum = np.concatenate(([0.0], np.cumsum(values)))
    starts = np.clip(np.arange(n) - half, 0, n)
    stops = np.clip(np.arange(n) + half + 1, 0, n)
    return (cumsum[stops] - cumsum[starts]) / (stops - starts)


def velocity(trace: GazeTrace) -> np.ndarray:
    """Velocidade angular instantânea, em graus por segundo.

    Usa diferenças centradas no interior da série e diferenças laterais nas
    extremidades, o que reduz o atraso de fase em relação à diferença simples
    para frente. O resultado tem o mesmo tamanho do percurso.
    """
    n = len(trace)
    if n < 2:
        return np.zeros(n)

    dx = np.gradient(trace.x, trace.t)
    dy = np.gradient(trace.y, trace.t)
    return np.hypot(dx, dy)
