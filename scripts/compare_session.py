"""Compara uma sessão do aplicativo com as crianças do ETDD70.

Para quando não há turma com quem comparar -- um teste com uma sessão só,
por exemplo. Mostra, por característica, onde a sessão cai em relação às
crianças sem dislexia e às com dislexia do ETDD70, na condição de sinal mais
parecida com a da sessão (ver ``scripts/make_etdd70_reference.py``).

**Não é diagnóstico**, e o resultado precisa ser lido com o aviso que o
próprio script imprime: a base é de crianças tchecas de 9 e 10 anos lendo
em tcheco num rastreador de bancada; a sessão é de outra pessoa, outro texto
e outro equipamento. O que a comparação mostra bem é o tamanho da diferença
entre o sinal da câmera e o do laboratório.

Uso::

    python scripts/compare_session.py sessao.json [--out comparacao.png]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
REFERENCE = REPOSITORY_ROOT / "mobile/eyelearn_app/assets/etdd70_reference.json"

LABELS = {
    "fixation_rate": "Fixações por segundo",
    "fixation_duration_mean": "Duração média da fixação (s)",
    "fixation_duration_std": "Desvio da duração da fixação (s)",
    "fixation_duration_median": "Mediana da duração da fixação (s)",
    "saccade_rate": "Sacadas por segundo",
    "saccade_amplitude_mean": "Amplitude média da sacada (°)",
    "saccade_amplitude_std": "Desvio da amplitude da sacada (°)",
    "progressive_amplitude_mean": "Amplitude da sacada para a frente (°)",
    "regression_ratio": "Proporção de regressões",
    "regression_rate": "Regressões por segundo",
    "peak_velocity_mean": "Velocidade de pico média (°/s)",
    "line_sweep_rate": "Trocas de linha por segundo",
    "reading_time": "Tempo de leitura (s)",
    "scanpath_length": "Comprimento do percurso (°)",
}


def pick_condition(rate_hz: float) -> str:
    """A condição de referência mais próxima da taxa da sessão."""
    if rate_hz >= 100:
        return "original"
    return "15hz_2deg" if rate_hz < 22.5 else "30hz_2deg"


def compare(session: dict, reference: dict, condition: str | None = None) -> dict:
    task = session["task"]
    condition = condition or pick_condition(session["sampling_rate_hz"])
    groups = reference["tasks"][task][condition]["groups"]
    rows = []
    for name in reference["feature_names"]:
        value = float(session["features"][name])
        row = {"feature": name, "value": value}
        for group in ("typical", "dyslexic"):
            stats = groups[group]["features"][name]
            std = stats["std"]
            row[group] = stats
            row[f"z_{group}"] = (value - stats["mean"]) / std if std > 0 else 0.0
        rows.append(row)
    return {
        "task": task,
        "condition": condition,
        "condition_label": reference["tasks"][task][condition]["label"],
        "n": {g: groups[g]["n"] for g in groups},
        "rows": rows,
    }


def plot(result: dict, path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    rows = result["rows"]
    fig, ax = plt.subplots(figsize=(8.5, 6.2), dpi=120)
    for i, row in enumerate(rows):
        for group, colour, offset in (("typical", "#5B4BE8", -0.12),
                                      ("dyslexic", "#C27A00", 0.12)):
            s = row[group]
            std = s["std"] or 1.0
            # Faixa p10-p90 do grupo, na escala de desvios das típicas.
            ref = rows[i]["typical"]
            ref_std = ref["std"] or 1.0
            lo = (s["p10"] - ref["mean"]) / ref_std
            hi = (s["p90"] - ref["mean"]) / ref_std
            ax.plot([lo, hi], [i + offset] * 2, color=colour, lw=5, alpha=0.35,
                    solid_capstyle="round")
            ax.plot([(s["mean"] - ref["mean"]) / ref_std], [i + offset], "o",
                    color=colour, ms=5)
            del std
        z = row["z_typical"]
        shown = max(min(z, 9.5), -9.5)
        ax.plot([shown], [i], "D", color="#1C2033", ms=7, zorder=5)
        if shown != z:
            ax.annotate(f"{z:+.0f}", (shown, i), textcoords="offset points",
                        xytext=(6 if z > 0 else -18, 4), fontsize=8)
    ax.axvline(0, color="#9AA0BF", lw=1)
    ax.set_yticks(range(len(rows)))
    ax.set_yticklabels([LABELS.get(r["feature"], r["feature"]) for r in rows], fontsize=9)
    ax.invert_yaxis()
    ax.set_xlim(-10, 10)
    ax.set_xlabel("desvios em relação às crianças sem dislexia do ETDD70")
    ax.set_title(
        f"Sessão × ETDD70 ({result['task']}, referência {result['condition_label']})\n"
        "losango: a sessão · roxo: sem dislexia · âmbar: com dislexia "
        "(ponto: média; faixa: 10% a 90%)",
        fontsize=10,
    )
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    fig.tight_layout()
    fig.savefig(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("session", type=Path)
    parser.add_argument("--reference", type=Path, default=REFERENCE)
    parser.add_argument("--condition", choices=["original", "30hz_2deg", "15hz_2deg"])
    parser.add_argument("--out", type=Path, help="gráfico em PNG")
    args = parser.parse_args()

    session = json.loads(args.session.read_text(encoding="utf-8"))
    reference = json.loads(args.reference.read_text(encoding="utf-8"))
    result = compare(session, reference, args.condition)

    print(f"Sessão {session['participant_code']}, tarefa {result['task']}, "
          f"{session['sampling_rate_hz']:.0f} Hz, {session['duration_seconds']:.1f} s, "
          f"{100 * session['valid_sample_ratio']:.0f}% de amostras válidas")
    print(f"Referência: ETDD70 a {result['condition_label']} "
          f"({result['n']['typical']} sem dislexia, {result['n']['dyslexic']} com)\n")
    print(f"{'característica':38s} {'sessão':>9s} {'sem dislexia':>17s} "
          f"{'com dislexia':>17s} {'z':>6s}")
    for row in result["rows"]:
        t, d = row["typical"], row["dyslexic"]
        print(f"{LABELS.get(row['feature'], row['feature']):38s} {row['value']:9.3f} "
              f"{t['mean']:8.3f} ±{t['std']:7.3f} {d['mean']:8.3f} ±{d['std']:7.3f} "
              f"{row['z_typical']:+6.1f}")
    far = sum(abs(r["z_typical"]) > 3 for r in result["rows"])
    print(f"\n{far} de {len(result['rows'])} características a mais de 3 desvios das "
          "crianças sem dislexia.")
    print("Não é diagnóstico. Base tcheca, rastreador de bancada; a sessão é de outro "
          "texto, outra pessoa e outro equipamento.")
    if args.out:
        plot(result, args.out)
        print(f"gráfico: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
