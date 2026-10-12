"""Vetores de ouro para verificar a porta do pipeline para outra linguagem.

O aplicativo do aluno roda em celular e extrai as características em Dart, não
em Python. São duas implementações do mesmo cálculo, e nada garante que
concordem: um limiar diferente, um arredondamento diferente ou um laço com
limite trocado produzem um vetor de características ligeiramente diferente. O
modelo então recebe uma entrada que nunca viu, e devolve uma predição errada
sem que nada acuse erro -- não há exceção, não há valor fora de faixa, só uma
resposta diferente.

Este módulo congela o que o Python calcula, estágio por estágio, num arquivo
JSON. A suíte Dart lê o mesmo arquivo e afirma que chega aos mesmos números. É
teste diferencial: nenhum dos lados é oráculo isolado, mas a divergência entre
os dois é sempre defeito de um deles.

Os casos incluem percursos degenerados de propósito -- vazio, uma amostra só,
tudo perdido por piscada, buraco no meio. São onde as duas implementações mais
tendem a divergir, porque cada linguagem tem sua própria convenção para
contorno de lista vazia e divisão por zero.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from eyelearn.export.artifact import ModelArtifact
from eyelearn.features import reading
from eyelearn.pipeline import PipelineConfig, trace_to_features
from eyelearn.signal import events, preprocess
from eyelearn.synthetic import reading_trace
from eyelearn.trace import GazeTrace

#: Versão do formato do arquivo de vetores de ouro.
GOLDEN_VERSION = 1

#: Casas decimais com que os valores esperados são gravados.
#:
#: Só os valores *esperados* são arredondados, nunca as amostras de entrada. O
#: arredondamento da entrada tornava o arquivo auto-inconsistente: as
#: expectativas vinham do percurso em precisão plena e o arquivo guardava o
#: percurso arredondado, de modo que a suíte Dart recebia uma entrada diferente
#: da que gerou as expectativas e falhava por um motivo que nada tinha a ver
#: com a porta do pipeline. As amostras saem pelo ``repr`` do ``json``, que
#: faz ida e volta exata em precisão dupla.
#:
#: Doze casas nos esperados ficam bem dentro da tolerância de 1e-9 com que a
#: suíte Dart compara.
EXPECTED_DECIMALS = 12


@dataclass(frozen=True)
class GoldenCase:
    """Um caso de verificação, com entrada e saída esperada em cada estágio."""

    case_id: str
    trace: GazeTrace
    note: str = ""


def reference_cases() -> list[GoldenCase]:
    """Os casos que atravessam a fronteira de linguagem.

    Percursos curtos de propósito: o arquivo é lido por uma suíte de testes, e
    um percurso de trinta segundos a 250 Hz não acrescenta cobertura sobre um
    de dois segundos -- só peso.
    """
    cases: list[GoldenCase] = []

    short, _ = reading_trace(n_lines=1, fixations_per_line=4, n_regressions=0)
    cases.append(GoldenCase("leitura_simples", short, "uma linha, sem regressão"))

    with_regressions, _ = reading_trace(
        n_lines=2, fixations_per_line=5, n_regressions=2
    )
    cases.append(
        GoldenCase(
            "leitura_com_regressoes",
            with_regressions,
            "duas linhas, com regressões e retorno de linha",
        )
    )

    # A amplitude de 3 graus é escolhida, e não o padrão de 2: a 30 Hz uma
    # sacada de 2 graus ocupa uma amostra só, e sua velocidade por diferença
    # centrada dá exatamente 30 graus por segundo -- o próprio limiar do I-VT.
    # Um caso equilibrado no limiar vira ou não vira fixação conforme o último
    # bit da aritmética da plataforma, e não serve de vetor de ouro para
    # comparar duas linguagens. A 3 graus a velocidade vai a 45 e a detecção
    # fica inequívoca. O comportamento no limiar está documentado no lado
    # Python, em TestWebcamRateLimit.
    slow, _ = reading_trace(
        n_lines=1,
        fixations_per_line=4,
        sampling_rate=30.0,
        saccade_amplitude=3.0,
        jitter_deg=0.0,
    )
    cases.append(
        GoldenCase(
            "taxa_de_webcam",
            slow,
            "30 Hz, como uma câmera comum; sacada de 3 graus",
        )
    )

    # Degenerados: é onde as convenções de cada linguagem divergem.
    empty = GazeTrace(
        t=np.array([]), x=np.array([]), y=np.array([]), subject_id="borda"
    )
    cases.append(GoldenCase("vazio", empty, "nenhuma amostra"))

    single = GazeTrace(
        t=np.array([0.0]), x=np.array([1.0]), y=np.array([2.0]), subject_id="borda"
    )
    cases.append(GoldenCase("amostra_unica", single, "uma amostra, sem velocidade"))

    all_lost = GazeTrace(
        t=np.arange(20) * 0.004,
        x=np.full(20, np.nan),
        y=np.full(20, np.nan),
        subject_id="borda",
    )
    cases.append(GoldenCase("tudo_perdido", all_lost, "piscada do início ao fim"))

    base, _ = reading_trace(n_lines=1, fixations_per_line=4)
    gapped = GazeTrace(
        t=np.concatenate([base.t[:60], base.t[60:] + 0.5]),
        x=base.x,
        y=base.y,
        subject_id="borda",
    )
    cases.append(
        GoldenCase("com_buraco", gapped, "meio segundo sem amostra no meio")
    )

    stationary = GazeTrace(
        t=np.arange(100) * 0.004,
        x=np.full(100, 3.0),
        y=np.full(100, -1.0),
        subject_id="borda",
    )
    cases.append(
        GoldenCase("parado", stationary, "olhar imóvel: uma fixação, nenhuma sacada")
    )

    return cases


def build_fixture(
    artifact: ModelArtifact | None = None,
    config: PipelineConfig | None = None,
    cases: list[GoldenCase] | None = None,
) -> dict[str, Any]:
    """Monta o conteúdo do arquivo de vetores de ouro.

    Args:
        artifact: modelo exportado. Quando informado, cada caso recebe também a
            pontuação e a classe esperadas, verificando a inferência além da
            extração.
        config: parâmetros de extração. Quando ``artifact`` é informado, os
            parâmetros vêm dele, para que o arquivo não possa descrever uma
            extração diferente da que o modelo espera.
        cases: casos a congelar. O padrão é :func:`reference_cases`.

    Returns:
        Estrutura serializável com um registro por caso e por estágio.
    """
    if artifact is not None:
        config = _config_from_artifact(artifact)
    config = config or PipelineConfig()
    cases = cases if cases is not None else reference_cases()

    return {
        "version": GOLDEN_VERSION,
        "generated_by": "eyelearn.export.golden",
        "preprocessing": {
            "method": config.method,
            "smoothing_ms": config.smoothing_ms,
            "max_gap": config.max_gap,
            "velocity_threshold": config.velocity_threshold,
            "dispersion_threshold": config.dispersion_threshold,
            "min_fixation_duration": config.min_fixation_duration,
            "bounds_deg": list(config.bounds_deg) if config.bounds_deg else None,
        },
        "feature_names": list(reading.FEATURE_NAMES),
        "cases": [_build_case(case, config, artifact) for case in cases],
    }


def save_fixture(path: Path | str, **kwargs: Any) -> Path:
    """Escreve o arquivo de vetores de ouro."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = build_fixture(**kwargs)
    path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return path


def _build_case(
    case: GoldenCase,
    config: PipelineConfig,
    artifact: ModelArtifact | None,
) -> dict[str, Any]:
    trace = case.trace

    # Os estágios intermediários entram no arquivo para que uma falha na suíte
    # Dart aponte onde a divergência começa. Só a saída final diria que algo
    # está errado, não o quê.
    cleaned = preprocess.drop_invalid(trace, config.bounds_deg)
    smoothed = preprocess.smooth(
        cleaned, config.smoothing_window(cleaned.sampling_rate)
    )
    fixations, saccades = events.detect_events(
        smoothed,
        method=config.method,
        max_gap=config.max_gap,
        **config.detector_kwargs(),
    )
    features = trace_to_features(trace, config)

    record: dict[str, Any] = {
        "id": case.case_id,
        "note": case.note,
        "samples": {
            # Em precisão plena: ver EXPECTED_DECIMALS.
            "t": _exact(trace.t),
            "x": _exact(trace.x),
            "y": _exact(trace.y),
        },
        "expected": {
            "valid_sample_count": len(cleaned),
            "fixation_count": len(fixations),
            "saccade_count": len(saccades),
            "regression_count": sum(1 for s in saccades if s.kind == "regressive"),
            "line_sweep_count": sum(1 for s in saccades if s.kind == "line_sweep"),
            "fixations": [
                {
                    "t_start": round(f.t_start, EXPECTED_DECIMALS),
                    "t_end": round(f.t_end, EXPECTED_DECIMALS),
                    "x": round(f.x, EXPECTED_DECIMALS),
                    "y": round(f.y, EXPECTED_DECIMALS),
                }
                for f in fixations
            ],
            "features": {
                name: round(features[name], EXPECTED_DECIMALS)
                for name in reading.FEATURE_NAMES
            },
        },
    }

    if artifact is not None:
        vector = reading.to_vector(features)
        record["expected"]["score"] = round(
            float(artifact.score(vector)[0]), EXPECTED_DECIMALS
        )
        record["expected"]["label"] = int(artifact.predict(vector)[0])

    return record


def _config_from_artifact(artifact: ModelArtifact) -> PipelineConfig:
    """Reconstrói os parâmetros de extração a partir do artefato.

    Garante que o arquivo de vetores de ouro descreva exatamente a extração que
    o modelo exportado espera. Montar os dois de fontes separadas permitiria
    que divergissem, e o arquivo passaria a validar a coisa errada.
    """
    pre = artifact.preprocessing
    bounds = pre.get("bounds_deg")
    return PipelineConfig(
        method=pre["method"],
        smoothing_ms=pre["smoothing_ms"],
        max_gap=pre["max_gap"],
        bounds_deg=tuple(bounds) if bounds else None,
        velocity_threshold=pre["velocity_threshold"],
        dispersion_threshold=pre["dispersion_threshold"],
        min_fixation_duration=pre["min_fixation_duration"],
    )


def _exact(values: np.ndarray) -> list[float | None]:
    """Serializa em precisão plena, com ``NaN`` virando ``null``.

    O ``json`` grava cada float pelo ``repr``, que faz ida e volta exata em
    precisão dupla. ``NaN`` não é JSON válido, e a suíte Dart converte ``null``
    de volta para ``double.nan`` -- deixá-lo chegar como zero daria uma
    coordenada legítima no centro da tela onde houve piscada.
    """
    return [None if not np.isfinite(v) else float(v) for v in values]
