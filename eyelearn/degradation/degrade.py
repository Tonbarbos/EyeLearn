"""Degradação controlada do sinal do olhar.

Suporta o experimento principal do projeto (seção 4.3 da metodologia). O
ETDD70 foi gravado em equipamento de bancada, bem mais preciso do que uma
webcam comum. Degradar esse sinal em passos controlados permite medir a curva
de acurácia em função da qualidade de aquisição e estimar até onde uma solução
de baixo custo se sustenta -- sem precisar de um rastreador de bancada para
fazer a comparação.

Duas dimensões são degradadas de forma independente:

* **resolução temporal**, pela redução da taxa de amostragem. Vajs et al.
  (2023) observaram queda de 88,9% para 87,8% de acurácia ao passar de 60 Hz
  para 30 Hz, o que sugere que a taxa sozinha não inviabiliza a classificação.
* **precisão espacial**, pela soma de ruído gaussiano. Sistemas baseados em
  câmera comum operam entre 0,6 e 1 grau de erro mesmo após calibração
  individual (Valliappan et al., 2020), contra os cerca de 0,5 grau de um
  equipamento de bancada.

A degradação é aplicada **depois** da divisão em treino e teste, e sobre
ambos os lados: o objetivo é simular um sistema que grava em qualidade de
webcam, não treinar com sinal limpo e testar com sinal ruim.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from eyelearn.trace import GazeTrace


@dataclass(frozen=True)
class DegradationLevel:
    """Um ponto da curva de degradação.

    Attributes:
        sampling_rate_hz: taxa de amostragem alvo. ``None`` preserva a original.
        noise_sigma_deg: desvio padrão do ruído espacial, em graus.
        label: nome curto do nível, usado nos gráficos e nas tabelas.
    """

    sampling_rate_hz: float | None
    noise_sigma_deg: float
    label: str


def webcam_grid() -> list[DegradationLevel]:
    """Níveis de degradação usados no experimento.

    A grade vai do sinal original ao pior caso plausível de webcam. As taxas
    cobrem o que uma câmera comum entrega (30 Hz) e o que sobra quando a
    detecção falha em parte dos quadros (15 Hz). Os desvios de ruído cobrem a
    faixa relatada para rastreamento por câmera de uso geral.
    """
    return [
        DegradationLevel(None, 0.0, "original"),
        DegradationLevel(60.0, 0.0, "60 Hz"),
        DegradationLevel(30.0, 0.0, "30 Hz"),
        DegradationLevel(30.0, 0.3, "30 Hz + 0,3°"),
        DegradationLevel(30.0, 0.6, "30 Hz + 0,6°"),
        DegradationLevel(30.0, 1.0, "30 Hz + 1,0°"),
        DegradationLevel(15.0, 1.0, "15 Hz + 1,0°"),
    ]


def downsample(trace: GazeTrace, target_hz: float) -> GazeTrace:
    """Reduz a taxa de amostragem do percurso.

    Seleciona, para cada instante de uma grade uniforme em ``target_hz``, a
    amostra original mais próxima. A seleção por grade é preferível à
    decimação por fator inteiro porque funciona para qualquer par de taxas e
    não assume amostragem perfeitamente uniforme na entrada -- que já não é
    uniforme depois do descarte das piscadas.

    Amostras não são interpoladas: o percurso resultante contém apenas
    posições efetivamente medidas, como aconteceria em uma câmera mais lenta.

    Args:
        trace: percurso a reduzir.
        target_hz: taxa alvo. Se for maior ou igual à original, o percurso é
            devolvido inalterado -- reduzir não pode inventar amostras.

    Returns:
        Percurso com a taxa reduzida e os mesmos metadados.
    """
    if target_hz <= 0:
        raise ValueError("target_hz deve ser positivo")
    if len(trace) < 2 or target_hz >= trace.sampling_rate:
        return trace

    grid = np.arange(trace.t[0], trace.t[-1] + 1.0 / target_hz, 1.0 / target_hz)
    # searchsorted dá o vizinho à direita de cada ponto da grade; comparar com
    # o vizinho à esquerda escolhe o mais próximo dos dois.
    right = np.searchsorted(trace.t, grid, side="left").clip(0, len(trace) - 1)
    left = (right - 1).clip(0, len(trace) - 1)
    closer_to_left = np.abs(trace.t[left] - grid) < np.abs(trace.t[right] - grid)
    indices = np.unique(np.where(closer_to_left, left, right))

    return GazeTrace(
        t=trace.t[indices],
        x=trace.x[indices],
        y=trace.y[indices],
        subject_id=trace.subject_id,
        task=trace.task,
        label=trace.label,
    )


def add_spatial_noise(
    trace: GazeTrace,
    sigma_deg: float,
    rng: np.random.Generator | None = None,
) -> GazeTrace:
    """Soma ruído gaussiano independente a cada coordenada.

    Modela o erro de estimativa do olhar como ruído branco de média zero. É
    uma simplificação: o erro real de um rastreador por câmera tem também uma
    componente sistemática, que varia com a posição na tela e com a posição da
    cabeça, e cujo efeito sobre a classificação tende a ser menor, por deslocar
    o percurso inteiro sem alterar sua forma. O ruído branco é portanto o caso
    mais severo entre os dois, e é o que degrada a detecção de eventos.

    Args:
        trace: percurso a degradar.
        sigma_deg: desvio padrão do ruído, em graus. Zero devolve o percurso
            inalterado.
        rng: gerador de números aleatórios. Informe um gerador semeado para
            que o experimento seja reprodutível.
    """
    if sigma_deg < 0:
        raise ValueError("sigma_deg não pode ser negativo")
    if sigma_deg == 0 or len(trace) == 0:
        return trace

    rng = rng if rng is not None else np.random.default_rng()
    return trace.with_coordinates(
        trace.x + rng.normal(0.0, sigma_deg, size=trace.x.shape),
        trace.y + rng.normal(0.0, sigma_deg, size=trace.y.shape),
    )


def degrade(
    trace: GazeTrace,
    level: DegradationLevel,
    rng: np.random.Generator | None = None,
) -> GazeTrace:
    """Aplica um nível de degradação completo.

    A ordem importa: a taxa é reduzida antes do ruído. Reduzir depois
    descartaria parte das amostras já contaminadas, o que equivaleria a uma
    média local e atenuaria o ruído que se quer medir.
    """
    reduced = trace if level.sampling_rate_hz is None else downsample(
        trace, level.sampling_rate_hz
    )
    return add_spatial_noise(reduced, level.noise_sigma_deg, rng)
