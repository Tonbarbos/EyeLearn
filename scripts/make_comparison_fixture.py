"""Gera as sessões de exemplo e a comparação com a turma que o Dart reproduz.

O painel do professor passou a rodar no navegador, em Dart, e a comparação
intraturma (escores z, destacados, sugestões) existe agora nas duas
linguagens. Este arquivo é a fronteira: o Python calcula, o Dart confere.

Turma fictícia, com o que a comparação precisa tratar: uma criança que
repetiu a tarefa (vale a última), uma gravação de qualidade ruim (fica de
fora), uma característica constante na turma (escore zero, não infinito) e
uma criança que se destaca.

Uso::

    python scripts/make_comparison_fixture.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.features.reading import FEATURE_NAMES  # noqa: E402
from eyelearn.session import (  # noqa: E402
    SESSION_FORMAT_VERSION,
    compare_within_class,
    session_from_dict,
    suggestions_for,
)

FIXTURE = REPOSITORY_ROOT / "mobile/eyelearn_core/assets/comparison_example.json"


def payload(code, started, features, *, rate=29.0, valid=0.93, task="text"):
    return {
        "format_version": SESSION_FORMAT_VERSION,
        "participant_code": code,
        "task": task,
        "started_at": started,
        "duration_seconds": 30.0,
        "sampling_rate_hz": rate,
        "valid_sample_ratio": valid,
        "features": {name: float(features[i]) for i, name in enumerate(FEATURE_NAMES)},
        "score": 0.5,
        "model": {"score_kind": "probability", "training_data": "etdd70"},
    }


def main() -> int:
    rng = np.random.default_rng(7)
    base = rng.uniform(0.5, 3.0, size=len(FEATURE_NAMES))
    # Constante na turma inteira: o desvio é zero.
    constant = FEATURE_NAMES.index("peak_velocity_mean")

    payloads = []
    for index, code in enumerate(["AAA222", "BBB333", "CCC444", "DDD555", "EEE666"]):
        features = base * rng.uniform(0.85, 1.15, size=len(FEATURE_NAMES))
        features[constant] = base[constant]
        if code == "EEE666":  # destaca-se: fixações longas, muitas voltas
            features[FEATURE_NAMES.index("fixation_duration_mean")] *= 1.9
            features[FEATURE_NAMES.index("regression_ratio")] *= 2.2
        payloads.append(payload(code, f"2026-10-20T14:{index:02d}:00Z", features))

    # BBB333 repetiu: a gravação mais nova vale, a antiga sai.
    older = base * 3.0
    older[constant] = base[constant]
    payloads.append(payload("BBB333", "2026-10-19T09:00:00Z", older))
    # Gravação ruim (10 Hz): fica fora da comparação.
    payloads.append(payload("FFF777", "2026-10-20T15:00:00Z", base * 5.0, rate=10.0))
    # Outra tarefa: não entra na comparação do texto.
    payloads.append(payload("AAA222", "2026-10-20T16:00:00Z", base * 7.0, task="syllables"))

    sessions = [session_from_dict(p) for p in payloads]
    comparison = compare_within_class(sessions, "text")
    expected = {
        "task": comparison.task,
        "participant_codes": comparison.participant_codes,
        "z_scores": comparison.z_scores.tolist(),
        "class_mean": comparison.class_mean.tolist(),
        "class_std": comparison.class_std.tolist(),
        "outliers": comparison.outliers(),
        "suggestions": {
            code: suggestions_for(comparison, code) for code in comparison.participant_codes
        },
    }
    FIXTURE.write_text(
        json.dumps({"sessions": payloads, "expected": expected}, ensure_ascii=False, indent=2)
        + "\n",
        encoding="utf-8",
    )
    print(f"escrito: {FIXTURE.relative_to(REPOSITORY_ROOT)}")
    print("destacados:", expected["outliers"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
