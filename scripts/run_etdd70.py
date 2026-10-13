"""Roda o experimento do trabalho sobre o ETDD70 e escreve os resultados.

Três comparações, todas com validação cruzada estratificada e separação por
participante (5 partições x 5 repetições por padrão):

1. **Entre modelos**, no sinal original do rastreador de bancada, com as três
   tarefas juntas: regressão logística (linha de base), SVM e floresta
   aleatória, avaliados sobre as mesmas partições.
2. **Entre tarefas**: sílabas, texto com sentido e pseudotexto, cada uma
   sozinha. Diz qual atividade o aplicativo deveria priorizar.
3. **Entre níveis de degradação** (a curva): do sinal original até 15 Hz com
   1 grau de ruído, passando pelo ponto de operação do aplicativo, 30 Hz com
   2 a 3 graus.

Saída, na pasta ``--out``:

* ``modelos.csv``, ``tarefas.csv``, ``degradacao.csv``;
* ``degradacao.png``, a curva com intervalo de confiança;
* ``RESULTADOS.md``, o resumo com os números e a procedência dos dados.

Uso::

    python scripts/run_etdd70.py --etdd70 CAMINHO --labels CAMINHO/labels.csv
    python scripts/run_etdd70.py --synthetic      # ensaio, sem a base

``--synthetic`` roda o mesmo roteiro sobre a coorte sintética da suíte de
testes, para conferir que tudo funciona antes de a base estar disponível. Os
números desse ensaio não dizem nada sobre leitura, e o resumo diz isso em
destaque.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.data.etdd70 import load_dataset  # noqa: E402
from eyelearn.experiments.degradation_curve import run_degradation_curve  # noqa: E402
from eyelearn.models.train import SCHOOL_PREVALENCE, compare_models  # noqa: E402
from eyelearn.pipeline import PipelineConfig, build_dataset  # noqa: E402
from eyelearn.trace import DYSLEXIC, GazeTrace  # noqa: E402

TASK_LABELS = {
    "syllables": "Sílabas",
    "text": "Texto com sentido",
    "pseudotext": "Pseudotexto",
}
MODEL_LABELS = {
    "logistic": "Regressão logística",
    "svm": "SVM (RBF)",
    "random_forest": "Floresta aleatória",
}
METRICS = ("accuracy", "sensitivity", "specificity", "f1", "roc_auc")


def summarise(results, scope: str) -> list[dict]:
    rows = []
    for name, result in results.items():
        row = {"escopo": scope, "modelo": name}
        for metric in METRICS:
            row[metric] = result.mean(metric)
        row["accuracy_ci_low"], row["accuracy_ci_high"] = result.confidence_interval(
            "accuracy"
        )
        row["ppv_at_prevalence"] = result.ppv_at_prevalence()
        row["n_folds"] = len(result.folds)
        rows.append(row)
    return rows


def evaluate(traces: list[GazeTrace], scope: str, args) -> list[dict]:
    X, y, groups = build_dataset(traces, config=PipelineConfig())
    n_subjects = len(set(groups))
    n_splits = min(args.splits, n_subjects // 2)
    if n_splits < 2:
        print(f"  {scope}: poucos participantes ({n_subjects}); pulado")
        return []
    results = compare_models(
        X, y, groups, n_splits=n_splits, n_repeats=args.repeats, seed=args.seed
    )
    return summarise(results, scope)


def describe_cohort(traces: list[GazeTrace], removed: int) -> dict:
    subjects = {t.subject_id: t.label for t in traces}
    return {
        "gravacoes": len(traces),
        "removidas_por_qualidade": removed,
        "participantes": len(subjects),
        "com_dislexia": sum(1 for label in subjects.values() if label == DYSLEXIC),
        "por_tarefa": dict(Counter(t.task for t in traces)),
        "taxas_hz": sorted({round(t.sampling_rate) for t in traces}),
    }


def plot_curve(curve: pd.DataFrame, path: Path, synthetic: bool) -> None:
    figure, axes = plt.subplots(figsize=(8.6, 5.0), dpi=130)
    levels = list(dict.fromkeys(curve["level"]))
    positions = np.arange(len(levels))
    styles = {
        "logistic": ("#5B4BE8", "o"),
        "svm": ("#C27A00", "s"),
        "random_forest": ("#1C2033", "^"),
    }
    for offset, (model, group) in zip((-0.12, 0.0, 0.12), curve.groupby("model", sort=False),
                                      strict=False):
        colour, marker = styles.get(model, ("#6B7194", "o"))
        group = group.set_index("level").loc[levels]
        axes.errorbar(
            positions + offset,
            group["accuracy"] * 100,
            yerr=[
                (group["accuracy"] - group["accuracy_ci_low"]) * 100,
                (group["accuracy_ci_high"] - group["accuracy"]) * 100,
            ],
            color=colour,
            marker=marker,
            capsize=3,
            linewidth=1.6,
            label=MODEL_LABELS.get(model, model),
        )
    axes.axhline(50, color="#9AA0B8", linestyle="--", linewidth=1)
    axes.text(len(levels) - 0.5, 51, "acaso", color="#6B7194", ha="right", fontsize=9)
    axes.set_xticks(positions, levels, rotation=25, ha="right")
    axes.set_ylabel("acurácia (%)")
    axes.set_ylim(30, 100)
    axes.spines[["top", "right"]].set_visible(False)
    axes.legend(frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.3), ncol=3)
    title = "Acurácia por nível de degradação do sinal"
    if synthetic:
        title += " — ENSAIO SINTÉTICO, sem valor"
    axes.set_title(title, loc="left", fontsize=11)
    figure.tight_layout()
    figure.savefig(path)
    plt.close(figure)


def pct(value: float) -> str:
    return "—" if value is None or np.isnan(value) else f"{value * 100:.1f}".replace(".", ",")


def write_summary(path: Path, cohort: dict, models: pd.DataFrame, tasks: pd.DataFrame,
                  curve: pd.DataFrame | None, provenance: str, args) -> None:
    lines = [f"# Resultados do experimento — {provenance}", ""]
    if provenance == "sintético":
        lines += [
            "> **ENSAIO COM DADOS SINTÉTICOS.** Estes números vêm da coorte gerada",
            "> pela suíte de testes e não dizem nada sobre leitura nem sobre",
            "> dislexia. Servem só para conferir que o roteiro roda. Não citar.",
            "",
        ]
    lines += [
        f"Gerado em {datetime.now(UTC):%Y-%m-%d %H:%M} UTC. Validação cruzada "
        f"estratificada com separação por participante, {args.splits} partições x "
        f"{args.repeats} repetições, semente {args.seed}.",
        "",
        "## Coorte",
        "",
        f"- {cohort['participantes']} participantes, {cohort['com_dislexia']} com dislexia",
        f"- {cohort['gravacoes']} gravações usadas; {cohort['removidas_por_qualidade']} "
        "removidas por perda de rastreamento acima de 25%",
        "- por tarefa: " + ", ".join(
            f"{TASK_LABELS.get(k, k)} {v}" for k, v in sorted(cohort["por_tarefa"].items())
        ),
        f"- taxa de amostragem: {', '.join(f'{r} Hz' for r in cohort['taxas_hz'])}",
        "",
        "## 1. Comparação entre modelos (sinal original, três tarefas)",
        "",
        "| Modelo | Acurácia (IC 95%) | Sensibilidade | Especificidade | AUC | "
        f"VPP a {SCHOOL_PREVALENCE:.0%} |",
        "|---|---|---|---|---|---|",
    ]
    for row in models.itertuples():
        lines.append(
            f"| {MODEL_LABELS.get(row.modelo, row.modelo)} | {pct(row.accuracy)}% "
            f"({pct(row.accuracy_ci_low)}–{pct(row.accuracy_ci_high)}) | "
            f"{pct(row.sensitivity)}% | {pct(row.specificity)}% | {pct(row.roc_auc)}% | "
            f"{pct(row.ppv_at_prevalence)}% |"
        )
    lines += [
        "",
        "VPP: das crianças que o modelo apontaria numa escola com prevalência de "
        f"{SCHOOL_PREVALENCE:.0%}, quantas de fato teriam dislexia. A base é balanceada "
        "(metade com dislexia), então a acurácia sozinha superestima o uso real.",
        "",
        "## 2. Comparação entre tarefas (acurácia, sinal original)",
        "",
        "| Tarefa | " + " | ".join(MODEL_LABELS[m] for m in MODEL_LABELS) + " |",
        "|---|" + "---|" * len(MODEL_LABELS),
    ]
    for task, group in tasks.groupby("escopo", sort=False):
        by_model = group.set_index("modelo")
        cells = [
            f"{pct(by_model.loc[m, 'accuracy'])}%" if m in by_model.index else "—"
            for m in MODEL_LABELS
        ]
        lines.append(f"| {TASK_LABELS.get(task, task)} | " + " | ".join(cells) + " |")
    if curve is not None:
        lines += [
            "",
            "## 3. Curva de degradação (acurácia)",
            "",
            "![curva](degradacao.png)",
            "",
            "| Nível | " + " | ".join(MODEL_LABELS[m] for m in MODEL_LABELS) + " |",
            "|---|" + "---|" * len(MODEL_LABELS),
        ]
        for level, group in curve.groupby("level", sort=False):
            by_model = group.set_index("model")
            cells = [
                f"{pct(by_model.loc[m, 'accuracy'])}%" if m in by_model.index else "—"
                for m in MODEL_LABELS
            ]
            lines.append(f"| {level} | " + " | ".join(cells) + " |")
        lines += [
            "",
            "O aplicativo opera perto de **30 Hz + 2,0° a 3,0°** (calibração geométrica "
            "pela íris). É nessas linhas que se lê o que o sistema instalado pode "
            "entregar.",
        ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--etdd70", type=Path, help="pasta da base extraída")
    parser.add_argument("--labels", type=Path, help="CSV com subject,label")
    parser.add_argument("--synthetic", action="store_true",
                        help="ensaio na coorte sintética, sem a base")
    parser.add_argument("--out", type=Path, default=REPOSITORY_ROOT / "resultados")
    parser.add_argument("--splits", type=int, default=5)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--skip-degradation", action="store_true",
                        help="pula a curva, que é a etapa demorada")
    args = parser.parse_args()

    if args.synthetic == bool(args.etdd70):
        parser.error("use --etdd70 (com --labels) ou --synthetic")
    if bool(args.etdd70) != bool(args.labels):
        parser.error("--etdd70 e --labels andam juntos")

    if args.synthetic:
        sys.path.insert(0, str(REPOSITORY_ROOT / "tests"))
        from conftest import make_cohort  # noqa: PLC0415

        traces, removed, provenance = make_cohort(n_per_group=12), 0, "sintético"
    else:
        dataset = load_dataset(args.etdd70, labels=args.labels)
        kept = dataset.filter_by_quality()
        traces, removed, provenance = kept.traces, len(dataset) - len(kept), "ETDD70"

    args.out.mkdir(parents=True, exist_ok=True)
    cohort = describe_cohort(traces, removed)
    print(f"coorte: {cohort}")

    print("1/3 comparação entre modelos")
    models = pd.DataFrame(evaluate(traces, "todas", args))
    models.to_csv(args.out / "modelos.csv", index=False)

    print("2/3 comparação entre tarefas")
    task_rows = []
    for task in sorted({t.task for t in traces}):
        task_rows += evaluate([t for t in traces if t.task == task], task, args)
    tasks = pd.DataFrame(task_rows)
    tasks.to_csv(args.out / "tarefas.csv", index=False)

    curve = None
    if not args.skip_degradation:
        print("3/3 curva de degradação")
        curve = run_degradation_curve(
            traces, n_splits=args.splits, n_repeats=args.repeats, seed=args.seed
        )
        curve.to_csv(args.out / "degradacao.csv", index=False)
        plot_curve(curve, args.out / "degradacao.png", provenance == "sintético")

    write_summary(args.out / "RESULTADOS.md", cohort, models, tasks, curve, provenance, args)
    print(f"resultados em {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
