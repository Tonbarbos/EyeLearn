"""Leitura das sessões vindas do aplicativo do aluno.

É a ponte entre o celular e o painel do professor. O aplicativo grava um JSON
por gravação; este módulo os lê, agrega por turma e produz a comparação que o
painel apresenta.

**A normalização é intraturma, não contra um modelo clínico.** O que o painel
mostra é onde a leitura de uma criança fica em relação à dos colegas dela, pelo
escore z da turma. A razão é dupla. A primeira é estatística: o modelo foi
treinado numa base tcheca de 70 crianças, e a distribuição absoluta das
características numa turma brasileira não é a mesma -- um valor "alto" ali pode
ser a média aqui. A segunda é de uso: o professor decide adaptação pedagógica
para a turma que tem, e "lê mais devagar que a maioria dos colegas" é
acionável, enquanto "pontuação 0,62" não é.

O módulo não emite rótulo diagnóstico, e não há função que o produza.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from eyelearn.features.reading import FEATURE_NAMES

#: Versão do formato de sessão que este módulo entende. Tem de coincidir com
#: ``sessionFormatVersion`` em ``mobile/eyelearn_core/lib/src/session.dart``.
SESSION_FORMAT_VERSION = 1

#: Pisos de qualidade, iguais aos do aplicativo.
MIN_VALID_RATIO = 0.75
MIN_SAMPLING_RATE_HZ = 20.0


@dataclass(frozen=True)
class Session:
    """Uma gravação importada do aplicativo."""

    participant_code: str
    task: str
    started_at: str
    duration_seconds: float
    sampling_rate_hz: float
    valid_sample_ratio: float
    features: dict[str, float]
    score: float
    model: dict[str, Any]
    #: Sessão gerada para demonstração (``scripts/make_demo_class.py``), com
    #: percurso inventado em vez de criança lendo.
    demo_data: bool = False

    @property
    def has_usable_quality(self) -> bool:
        """Se a gravação tem qualidade para ser interpretada.

        O painel marca a sessão reprovada em vez de escondê-la: saber que a
        captura falhou é informação, e uma sessão que desaparece sem explicação
        levaria o professor a repetir a atividade sem saber por quê.
        """
        return (
            self.valid_sample_ratio >= MIN_VALID_RATIO
            and self.sampling_rate_hz >= MIN_SAMPLING_RATE_HZ
        )

    @property
    def trained_on_synthetic_data(self) -> bool:
        """Se o modelo que pontuou esta sessão veio de dados sintéticos.

        O painel precisa avisar: uma pontuação de modelo sintético não diz nada
        sobre leitura, e apresentá-la sem ressalva seria pior do que não
        apresentar.
        """
        return self.model.get("training_data") == "synthetic"


def load_session(path: Path | str) -> Session:
    """Lê um arquivo de sessão.

    Raises:
        FileNotFoundError: se o arquivo não existir.
        ValueError: se a versão do formato for desconhecida, ou se faltar
            característica. Um arquivo de versão futura pode ter a mesma forma
            e outra semântica; aceitá-lo produziria comparação errada.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"sessão não encontrada: {path}")

    payload = json.loads(path.read_text(encoding="utf-8"))
    return session_from_dict(payload)


def session_from_dict(payload: dict[str, Any]) -> Session:
    """Monta a sessão a partir do mapa já decodificado."""
    version = payload.get("format_version")
    if version != SESSION_FORMAT_VERSION:
        raise ValueError(
            f"versão de sessão não suportada: {version!r}; "
            f"esperada {SESSION_FORMAT_VERSION}"
        )

    features = payload.get("features", {})
    missing = set(FEATURE_NAMES) - features.keys()
    if missing:
        raise ValueError(f"características ausentes na sessão: {sorted(missing)}")

    return Session(
        participant_code=str(payload["participant_code"]),
        task=str(payload["task"]),
        started_at=str(payload["started_at"]),
        duration_seconds=float(payload["duration_seconds"]),
        sampling_rate_hz=float(payload["sampling_rate_hz"]),
        valid_sample_ratio=float(payload["valid_sample_ratio"]),
        features={name: float(features[name]) for name in FEATURE_NAMES},
        score=float(payload["score"]),
        model=dict(payload.get("model", {})),
        demo_data=bool(payload.get("demo_data", False)),
    )


def load_sessions(directory: Path | str, pattern: str = "*.json") -> list[Session]:
    """Lê todas as sessões de um diretório, ignorando as ilegíveis.

    Um arquivo corrompido não interrompe a importação: o professor pode ter
    recebido uma dúzia de sessões por canais diferentes, e perder as onze boas
    por causa de uma ruim seria o pior resultado possível. As ignoradas podem
    ser contadas comparando o tamanho da lista com a quantidade de arquivos.
    """
    directory = Path(directory)
    if not directory.is_dir():
        raise FileNotFoundError(f"diretório não encontrado: {directory}")

    sessions = []
    for path in sorted(directory.glob(pattern)):
        try:
            sessions.append(load_session(path))
        except (ValueError, KeyError, json.JSONDecodeError):
            continue
    return sessions


@dataclass(frozen=True)
class ClassComparison:
    """Onde cada criança fica em relação à turma, por característica.

    Attributes:
        task: tarefa a que a comparação se refere. Comparar leitura de sílabas
            com leitura de texto não faz sentido: as características têm
            escalas diferentes nas duas.
        participant_codes: códigos, na ordem das linhas.
        z_scores: matriz ``(participantes, características)`` de escores z.
        feature_names: nomes das colunas.
        class_mean: média da turma por característica.
        class_std: desvio padrão da turma por característica.
    """

    task: str
    participant_codes: list[str]
    z_scores: np.ndarray
    feature_names: list[str]
    class_mean: np.ndarray
    class_std: np.ndarray

    def for_participant(self, code: str) -> dict[str, float]:
        """Escores z de um participante, por característica."""
        try:
            row = self.participant_codes.index(code)
        except ValueError:
            raise KeyError(f"participante ausente da comparação: {code}") from None
        return dict(zip(self.feature_names, self.z_scores[row].tolist(), strict=True))

    def outliers(self, threshold: float = 1.5) -> dict[str, list[str]]:
        """Características em que cada participante se afasta da turma.

        O limiar de 1,5 desvios não é um ponto de corte diagnóstico: é o que
        destaca, numa turma de trinta, as poucas crianças que valem uma
        observação mais atenta do professor. Com 1,0 metade da turma apareceria;
        com 2,0, numa turma pequena, ninguém apareceria nunca.
        """
        if threshold <= 0:
            raise ValueError("threshold deve ser positivo")

        result: dict[str, list[str]] = {}
        for row, code in enumerate(self.participant_codes):
            flagged = [
                name
                for column, name in enumerate(self.feature_names)
                if abs(self.z_scores[row, column]) >= threshold
            ]
            if flagged:
                result[code] = flagged
        return result


def compare_within_class(
    sessions: list[Session],
    task: str,
    include_low_quality: bool = False,
) -> ClassComparison:
    """Calcula os escores z da turma para uma tarefa.

    Args:
        sessions: sessões importadas, de qualquer tarefa.
        task: tarefa a comparar.
        include_low_quality: incluir gravações que não atingem os pisos de
            qualidade. O padrão é não: uma captura ruim distorce a média da
            turma, e é contra a média da turma que todos os outros são medidos.

    Returns:
        A comparação.

    Raises:
        ValueError: se houver menos de três participantes com a tarefa. Com dois
            o desvio padrão não descreve dispersão nenhuma, e o escore z de cada
            um seria mecanicamente ±1 -- um número que pareceria significar algo
            e não significaria nada.
    """
    selected = [
        session
        for session in sessions
        if session.task == task
        and (include_low_quality or session.has_usable_quality)
    ]

    # Uma criança pode repetir a tarefa; a última gravação é a que vale.
    by_participant: dict[str, Session] = {}
    for session in sorted(selected, key=lambda s: s.started_at):
        by_participant[session.participant_code] = session

    if len(by_participant) < 3:
        raise ValueError(
            f"a tarefa {task!r} tem {len(by_participant)} participante(s) com "
            "gravação utilizável; a comparação intraturma precisa de pelo "
            "menos 3"
        )

    codes = sorted(by_participant)
    matrix = np.array(
        [[by_participant[code].features[name] for name in FEATURE_NAMES] for code in codes],
        dtype=float,
    )

    mean = matrix.mean(axis=0)
    std = matrix.std(axis=0)
    # Característica constante na turma: todo mundo igual, nenhum desvio. O
    # escore z é zero, não infinito.
    safe_std = np.where(std > 0, std, 1.0)
    z_scores = np.where(std > 0, (matrix - mean) / safe_std, 0.0)

    return ClassComparison(
        task=task,
        participant_codes=codes,
        z_scores=z_scores,
        feature_names=list(FEATURE_NAMES),
        class_mean=mean,
        class_std=std,
    )


#: Sugestões pedagógicas por característica em que a criança se destaca.
#:
#: São sugestões de adaptação, não condutas clínicas, e cada uma descreve o que
#: foi observado antes de propor o que fazer -- para que o professor possa
#: discordar da leitura, e não só da sugestão.
PEDAGOGICAL_SUGGESTIONS: dict[str, str] = {
    "fixation_duration_mean": (
        "Fixa o olhar em cada palavra por mais tempo que a maioria da turma. "
        "Pode ajudar: textos com fonte maior e mais espaçamento, e tempo extra "
        "em atividades de leitura."
    ),
    "regression_ratio": (
        "Volta atrás no texto com mais frequência que a maioria da turma, o que "
        "costuma indicar que a decodificação está custando esforço. Pode "
        "ajudar: leitura acompanhada, com apoio na linha, e textos mais curtos "
        "por vez."
    ),
    "fixation_rate": (
        "Faz mais paradas por segundo que a maioria da turma. Pode ajudar: "
        "dividir o texto em trechos menores, com pausa entre eles."
    ),
    "reading_time": (
        "Levou mais tempo que a maioria da turma para a mesma tarefa. Pode "
        "ajudar: prever tempo adicional em leituras avaliativas."
    ),
    "saccade_amplitude_mean": (
        "Avança em saltos menores que a maioria da turma, lendo em pedaços "
        "mais curtos. Pode ajudar: destacar sílabas ou blocos de palavras no "
        "material."
    ),
    "line_sweep_rate": (
        "Troca de linha com dificuldade mais frequente que a maioria da turma. "
        "Pode ajudar: régua de leitura ou marcador de linha."
    ),
}


def suggestions_for(
    comparison: ClassComparison,
    code: str,
    threshold: float = 1.5,
) -> list[str]:
    """Sugestões pedagógicas para um participante.

    Só olha as características em que a criança está **acima** da turma: as
    seis características com sugestão associada indicam mais esforço de leitura
    quando sobem. Ficar abaixo da média em duração de fixação não pede
    adaptação nenhuma.
    """
    z_scores = comparison.for_participant(code)
    return [
        PEDAGOGICAL_SUGGESTIONS[name]
        for name, z in z_scores.items()
        if name in PEDAGOGICAL_SUGGESTIONS and z >= threshold
    ]
