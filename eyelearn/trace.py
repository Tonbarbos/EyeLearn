"""Estrutura de dados central: a série temporal do olhar.

Todas as coordenadas circulam em **graus de ângulo visual**, não em pixels.
Os limiares dos algoritmos de detecção de eventos (I-VT, I-DT) são definidos
na literatura nessa unidade, e manter uma só unidade dentro do pipeline evita
conversões espalhadas pelo código. A conversão a partir de pixels é feita uma
única vez, na entrada, por :func:`eyelearn.signal.preprocess.pixels_to_degrees`.
"""

from __future__ import annotations

from dataclasses import dataclass, replace

import numpy as np

#: Rótulos de classe usados em todo o projeto.
TYPICAL = 0
DYSLEXIC = 1


@dataclass(frozen=True)
class GazeTrace:
    """Percurso do olhar de um participante em uma tarefa.

    Attributes:
        t: instantes de amostragem, em segundos, estritamente crescentes.
        x: coordenada horizontal do olhar, em graus de ângulo visual.
        y: coordenada vertical do olhar, em graus de ângulo visual.
        subject_id: identificador do participante. É a unidade de agrupamento
            na validação cruzada -- nenhum participante pode aparecer ao mesmo
            tempo no treino e no teste.
        task: nome da tarefa de leitura (sílabas, texto, pseudotexto).
        label: :data:`DYSLEXIC`, :data:`TYPICAL` ou ``None`` quando desconhecido.
    """

    t: np.ndarray
    x: np.ndarray
    y: np.ndarray
    subject_id: str
    task: str = "unknown"
    label: int | None = None

    def __post_init__(self) -> None:
        t = np.asarray(self.t, dtype=float)
        x = np.asarray(self.x, dtype=float)
        y = np.asarray(self.y, dtype=float)

        if not (t.ndim == x.ndim == y.ndim == 1):
            raise ValueError("t, x e y devem ser unidimensionais")
        if not (t.shape == x.shape == y.shape):
            raise ValueError(
                f"t, x e y devem ter o mesmo tamanho: {t.shape}, {x.shape}, {y.shape}"
            )
        if t.size and not np.all(np.isfinite(t)):
            raise ValueError("t não pode conter NaN ou infinito")
        if t.size > 1 and np.any(np.diff(t) <= 0):
            raise ValueError("t deve ser estritamente crescente")
        if self.label not in (None, TYPICAL, DYSLEXIC):
            raise ValueError(f"label inválido: {self.label!r}")

        # dataclass congelada: contorna o __setattr__ bloqueado para guardar
        # as versões normalizadas dos arrays.
        object.__setattr__(self, "t", t)
        object.__setattr__(self, "x", x)
        object.__setattr__(self, "y", y)

    def __len__(self) -> int:
        return int(self.t.size)

    @property
    def duration(self) -> float:
        """Intervalo coberto pelo percurso, em segundos."""
        if self.t.size < 2:
            return 0.0
        return float(self.t[-1] - self.t[0])

    @property
    def sampling_rate(self) -> float:
        """Taxa de amostragem mediana, em Hz.

        Usa a mediana dos intervalos, e não a média, porque amostras perdidas
        por piscadas deixam buracos longos que distorceriam a média.
        """
        if self.t.size < 2:
            return 0.0
        median_dt = float(np.median(np.diff(self.t)))
        if median_dt <= 0:
            return 0.0
        return 1.0 / median_dt

    def with_coordinates(self, x: np.ndarray, y: np.ndarray) -> GazeTrace:
        """Devolve uma cópia com outras coordenadas e os mesmos metadados."""
        return replace(self, x=x, y=y)

    def slice(self, start: int, stop: int) -> GazeTrace:
        """Devolve o recorte ``[start, stop)`` preservando os metadados."""
        return replace(self, t=self.t[start:stop], x=self.x[start:stop], y=self.y[start:stop])
