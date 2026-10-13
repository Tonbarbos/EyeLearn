"""Gera uma turma de sessões, no formato que o aplicativo do aluno grava.

Serve para experimentar o painel do professor sem precisar de celular, de
câmera e de crianças. **Não é dado real**: os percursos saem do gerador
sintético, e o modelo que os pontua foi treinado nos mesmos percursos. Nenhum
número daqui diz nada sobre leitura.

Uso::

    python scripts/make_demo_class.py --out /tmp/turma --students 18
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import numpy as np

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.export.artifact import ModelArtifact  # noqa: E402
from eyelearn.features.reading import FEATURE_NAMES  # noqa: E402
from eyelearn.pipeline import PipelineConfig, trace_to_features  # noqa: E402
from eyelearn.session import SESSION_FORMAT_VERSION  # noqa: E402
from eyelearn.synthetic import reading_trace  # noqa: E402

ARTIFACT = REPOSITORY_ROOT / "mobile" / "eyelearn_core" / "assets" / "model.json"

#: Tarefas, na ordem do ETDD70.
TASKS = ("syllables", "text", "pseudotext")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True, help="pasta de saída")
    parser.add_argument("--students", type=int, default=18)
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args()

    artifact = ModelArtifact.load(ARTIFACT)
    config = PipelineConfig()
    rng = np.random.default_rng(args.seed)

    args.out.mkdir(parents=True, exist_ok=True)
    for existing in args.out.glob("*.json"):
        existing.unlink()

    start = datetime(2026, 10, 9, 13, 30, tzinfo=UTC)
    written = 0

    for index in range(args.students):
        code = f"A{index + 1:02d}"

        # Cada criança tem o seu nível de esforço de leitura, sorteado uma vez
        # e mantido nas três tarefas -- é o que faz a turma ter dispersão e um
        # punhado de casos destacados, como uma turma de verdade.
        duration = float(rng.normal(0.245, 0.035))
        regressions = int(np.clip(rng.normal(2.2, 1.6), 0, 7))

        # Duas gravações de qualidade ruim na turma: o painel tem de marcá-las
        # em vez de escondê-las, e a demonstração precisa mostrar isso.
        poor_quality = index in (4, 11)

        for task_index, task in enumerate(TASKS):
            trace, _ = reading_trace(
                n_lines=3,
                fixations_per_line=8,
                fixation_duration=max(duration + float(rng.normal(0, 0.012)), 0.12),
                n_regressions=regressions,
                sampling_rate=30.0,
                saccade_amplitude=3.0,
                subject_id=code,
                rng=np.random.default_rng(int(rng.integers(1 << 32))),
            )

            features = trace_to_features(trace, config)
            vector = np.array([features[name] for name in FEATURE_NAMES])

            payload = {
                "format_version": SESSION_FORMAT_VERSION,
                "participant_code": code,
                "task": task,
                "started_at": (
                    start + timedelta(minutes=index * 7 + task_index * 2)
                ).isoformat().replace("+00:00", "Z"),
                "duration_seconds": round(trace.duration, 2),
                "sampling_rate_hz": round(11.0 if poor_quality else 29.4, 1),
                "valid_sample_ratio": round(0.38 if poor_quality else
                                            float(rng.uniform(0.86, 0.98)), 3),
                "features": {
                    name: round(float(value), 9)
                    for name, value in zip(FEATURE_NAMES, vector, strict=True)
                },
                "score": round(float(artifact.score(vector)[0]), 9),
                "model": {
                    "score_kind": artifact.score_kind,
                    "feature_names": list(FEATURE_NAMES),
                    **artifact.metadata,
                },
            }

            name = f"eyelearn_{code}_{task}.json"
            (args.out / name).write_text(
                json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            written += 1

    print(f"{written} sessões de {args.students} participantes em {args.out}")
    print("ATENÇÃO: dados sintéticos. Nenhum número aqui diz nada sobre leitura.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
