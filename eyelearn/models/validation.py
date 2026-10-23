"""Validação cruzada com separação por sujeito.

Cada participante do ETDD70 contribui com três gravações, uma por tarefa. Uma
validação cruzada comum espalharia as gravações de um mesmo participante entre
treino e teste, e o modelo aprenderia a reconhecer o indivíduo em vez do padrão
de leitura -- o desempenho medido apareceria inflado. É o erro metodológico
mais comum nesse tipo de experimento, e a seção 4.4 prevê um teste automatizado
contra ele.

O agrupamento usado aqui é o identificador do participante, e
:func:`assert_no_subject_leakage` falha alto se algum aparecer dos dois lados.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from sklearn.model_selection import StratifiedGroupKFold


class SubjectLeakageError(AssertionError):
    """Um participante apareceu ao mesmo tempo no treino e no teste."""


@dataclass(frozen=True)
class Fold:
    """Uma partição da validação cruzada.

    Attributes:
        train: índices das linhas de treino.
        test: índices das linhas de teste.
        repeat: número da repetição, a partir de zero.
    """

    train: np.ndarray
    test: np.ndarray
    repeat: int = 0


def subject_folds(
    y: np.ndarray,
    groups: np.ndarray,
    n_splits: int = 5,
    n_repeats: int = 5,
    seed: int = 0,
) -> list[Fold]:
    """Gera as partições estratificadas com separação por participante.

    Estratificada porque o rótulo precisa manter a proporção original em cada
    partição; agrupada porque a unidade que não pode se dividir é o
    participante. ``StratifiedGroupKFold`` atende aos dois critérios ao mesmo
    tempo, aproximando a estratificação dentro da restrição de agrupamento.

    As repetições reembaralham a atribuição dos participantes às partições e
    são a fonte dos intervalos de confiança da seção 4.5: com 70 participantes,
    uma única rodada de cinco partições tem variação grande o bastante para que
    uma diferença entre modelos possa vir apenas da divisão sorteada.

    Args:
        y: rótulos de cada linha.
        groups: identificador do participante de cada linha.
        n_splits: quantidade de partições por repetição.
        n_repeats: quantidade de repetições.
        seed: semente, para reprodutibilidade.

    Returns:
        Lista de ``n_splits * n_repeats`` partições.

    Raises:
        ValueError: se os tamanhos não casarem, ou se houver menos
            participantes do que partições.
        SubjectLeakageError: se alguma partição vazar participante.
    """
    y = np.asarray(y)
    groups = np.asarray(groups)

    if y.shape[0] != groups.shape[0]:
        raise ValueError(
            f"y e groups devem ter o mesmo tamanho: {y.shape[0]} e {groups.shape[0]}"
        )
    if n_splits < 2:
        raise ValueError("n_splits deve ser pelo menos 2")
    if n_repeats < 1:
        raise ValueError("n_repeats deve ser pelo menos 1")

    n_subjects = len(np.unique(groups))
    if n_subjects < n_splits:
        raise ValueError(
            f"há {n_subjects} participante(s) para {n_splits} partições; "
            "reduza n_splits"
        )

    folds: list[Fold] = []
    for repeat in range(n_repeats):
        splitter = StratifiedGroupKFold(
            n_splits=n_splits, shuffle=True, random_state=seed + repeat
        )
        for train_idx, test_idx in splitter.split(np.zeros_like(y), y, groups):
            assert_no_subject_leakage(groups[train_idx], groups[test_idx])
            folds.append(Fold(train=train_idx, test=test_idx, repeat=repeat))

    return folds


def assert_no_subject_leakage(
    train_groups: np.ndarray, test_groups: np.ndarray
) -> None:
    """Falha se algum participante aparecer nos dois lados da partição.

    Raises:
        SubjectLeakageError: com os identificadores vazados na mensagem.
    """
    shared = set(np.asarray(train_groups).tolist()) & set(
        np.asarray(test_groups).tolist()
    )
    if shared:
        raise SubjectLeakageError(
            "participante(s) presentes em treino e teste ao mesmo tempo: "
            f"{sorted(map(str, shared))}"
        )
