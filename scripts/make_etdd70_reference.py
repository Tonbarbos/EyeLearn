"""Gera a referência do ETDD70 com que uma sessão do aplicativo é comparada.

Uma turma pequena (ou uma sessão só, num teste) não dá comparação
intraturma. A alternativa é olhar onde a sessão cai em relação às crianças
do ETDD70: as sem dislexia e as com dislexia, por característica.

A comparação só faz algum sentido contra o ETDD70 **degradado até a
qualidade do aplicativo**. O sinal original é de um rastreador de bancada a
250 Hz com erro abaixo de 0,5°; o do aplicativo é de câmera de celular, a
15-30 Hz e com 2 a 3° de erro, e a detecção de fixações e sacadas muda com
isso (fixações se fundem, sacadas pequenas somem). Por isso a referência sai
em três condições: o original, 30 Hz com 2° de ruído e 15 Hz com 2°.

O arquivo leva só agregados por grupo (média, desvio, percentis), nada de
participante: é derivado do ETDD70, CC BY 4.0 -- citar Dostálová et al.
(2024).

Uso::

    python scripts/make_etdd70_reference.py --etdd70 PASTA --labels dyslexia_class_label.csv
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.data.etdd70 import load_etdd70  # noqa: E402
from eyelearn.degradation.degrade import DegradationLevel, degrade  # noqa: E402
from eyelearn.features.reading import FEATURE_NAMES  # noqa: E402
from eyelearn.pipeline import trace_to_features  # noqa: E402
from eyelearn.trace import DYSLEXIC  # noqa: E402

OUT = REPOSITORY_ROOT / "mobile/eyelearn_app/assets/etdd70_reference.json"

CONDITIONS = [
    ("original", DegradationLevel(None, 0.0, "original")),
    ("30hz_2deg", DegradationLevel(30.0, 2.0, "30 Hz + 2°")),
    ("15hz_2deg", DegradationLevel(15.0, 2.0, "15 Hz + 2°")),
]


def summarize(rows: list[dict[str, float]]) -> dict[str, dict[str, float]]:
    out = {}
    for name in FEATURE_NAMES:
        values = np.array([r[name] for r in rows], dtype=float)
        values = values[np.isfinite(values)]
        out[name] = {
            "mean": float(values.mean()),
            "std": float(values.std(ddof=1)) if len(values) > 1 else 0.0,
            "p10": float(np.percentile(values, 10)),
            "p50": float(np.percentile(values, 50)),
            "p90": float(np.percentile(values, 90)),
        }
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--etdd70", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    dataset = load_etdd70(args.etdd70, args.labels).filter_by_quality()
    rng = np.random.default_rng(args.seed)
    tasks: dict[str, dict] = {}
    for task in sorted({t.task for t in dataset.traces}):
        traces = [t for t in dataset.traces if t.task == task and t.label is not None]
        conditions = {}
        for key, level in CONDITIONS:
            groups: dict[str, list[dict[str, float]]] = {"typical": [], "dyslexic": []}
            for trace in traces:
                features = trace_to_features(degrade(trace, level, rng))
                group = "dyslexic" if trace.label == DYSLEXIC else "typical"
                groups[group].append(features)
            conditions[key] = {
                "label": level.label,
                "groups": {
                    name: {"n": len(rows), "features": summarize(rows)}
                    for name, rows in groups.items()
                },
            }
            print(f"{task:11s} {level.label:12s} "
                  f"típicos {len(groups['typical'])}, dislexia {len(groups['dyslexic'])}")
        tasks[task] = conditions

    payload = {
        "source": "ETDD70 (Dostálová et al., 2024), Zenodo 13332134, CC BY 4.0",
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "note": "agregados por grupo; nenhum dado de participante",
        "feature_names": list(FEATURE_NAMES),
        "tasks": tasks,
    }
    args.out.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n",
                        encoding="utf-8")
    print(f"escrito: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
