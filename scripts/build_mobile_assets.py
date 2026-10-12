"""Gera os ativos que o aplicativo do aluno embarca.

Produz dois arquivos em ``mobile/eyelearn_core/assets``:

* ``model.json`` -- o modelo treinado em formato portátil, lido pelo aparelho;
* ``golden.json`` -- os vetores de ouro, lidos pela suíte Dart para verificar
  que a porta do pipeline concorda com o Python.

Os dois saem da mesma execução de propósito. Gerados em momentos diferentes,
poderiam descrever extrações diferentes, e a suíte Dart passaria a validar algo
que o modelo embarcado não espera.

Uso::

    python scripts/build_mobile_assets.py                      # coorte sintética
    python scripts/build_mobile_assets.py --etdd70 CAMINHO \\
        --labels CAMINHO/labels.csv                            # base real

Sem ``--etdd70`` o modelo é treinado na coorte sintética. Serve para exercitar
o aplicativo de ponta a ponta, **não** para uso real: um modelo treinado em
percursos gerados não aprendeu nada sobre leitura. O arquivo registra isso em
``metadata.training_data``, e o aplicativo mostra o aviso enquanto o valor for
``synthetic``.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.data.etdd70 import load_dataset  # noqa: E402
from eyelearn.export.artifact import export_artifact  # noqa: E402
from eyelearn.export.golden import build_fixture, save_fixture  # noqa: E402
from eyelearn.models.train import build_models, cross_validate  # noqa: E402
from eyelearn.models.validation import subject_folds  # noqa: E402
from eyelearn.pipeline import PipelineConfig, build_dataset  # noqa: E402
from eyelearn.trace import GazeTrace  # noqa: E402

ASSETS = REPOSITORY_ROOT / "mobile" / "eyelearn_core" / "assets"

#: O aplicativo Flutter embarca o modelo pelo seu próprio diretório de ativos.
#: O núcleo é um pacote Dart puro e não declara ativos Flutter, então o arquivo
#: é copiado em vez de referenciado -- e copiado pelo mesmo script, para que as
#: duas cópias nunca descrevam modelos diferentes.
APP_ASSETS = REPOSITORY_ROOT / "mobile" / "eyelearn_app" / "assets"

#: Modelo embarcado. A regressão logística é a escolha padrão por três razões:
#: reproduz o scikit-learn até o último bit, ocupa dois quilobytes contra meio
#: megabyte da floresta, e seus coeficientes são legíveis -- dá para conferir
#: quais características o modelo está usando sem rodar nada.
DEFAULT_MODEL = "logistic"


def synthetic_cohort() -> list[GazeTrace]:
    """Coorte sintética, a mesma que a suíte de testes usa."""
    sys.path.insert(0, str(REPOSITORY_ROOT / "tests"))
    from conftest import make_cohort  # noqa: PLC0415

    return make_cohort(n_per_group=12)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--etdd70", type=Path, help="pasta da base ETDD70 já extraída"
    )
    parser.add_argument(
        "--labels", type=Path, help="CSV de rótulos, com as colunas subject e label"
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        choices=sorted(build_models()),
        help=f"modelo a embarcar (padrão: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--out", type=Path, default=ASSETS, help="pasta de saída dos ativos"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "não escreve nada; compara os ativos commitados com os que seriam "
            "gerados agora e falha se divergirem. Usado na integração contínua."
        ),
    )
    args = parser.parse_args()

    if bool(args.etdd70) != bool(args.labels):
        parser.error("--etdd70 e --labels andam juntos")

    if args.etdd70:
        dataset = load_dataset(args.etdd70, labels=args.labels)
        traces = dataset.filter_by_quality().traces
        provenance = "etdd70"
    else:
        traces = synthetic_cohort()
        provenance = "synthetic"
        print(
            "AVISO: treinando na coorte sintética. O modelo resultante não "
            "aprendeu nada sobre leitura e serve apenas para exercitar o "
            "aplicativo.",
            file=sys.stderr,
        )

    config = PipelineConfig()
    X, y, groups = build_dataset(traces, config=config)
    if X.shape[0] == 0:
        parser.error("nenhum percurso rotulado disponível")

    model = build_models()[args.model]

    # A validação cruzada roda antes do ajuste final e com separação por
    # sujeito: o número que vai para o artefato tem de ser o desempenho
    # honesto, não o acerto do modelo sobre os próprios dados de treino.
    folds = subject_folds(y, groups, n_splits=5, n_repeats=5)
    evaluation = cross_validate(model, X, y, folds, model_name=args.model)

    model.fit(X, y)
    artifact = export_artifact(
        model,
        config=config,
        metadata={
            "model_name": args.model,
            "training_data": provenance,
            "n_recordings": int(X.shape[0]),
            "n_subjects": int(len(np.unique(groups))),
            "cv_accuracy": round(evaluation.mean("accuracy"), 4),
            "cv_sensitivity": round(evaluation.mean("sensitivity"), 4),
            "cv_specificity": round(evaluation.mean("specificity"), 4),
            "cv_roc_auc": round(evaluation.mean("roc_auc"), 4),
            "ppv_at_school_prevalence": round(evaluation.ppv_at_prevalence(), 4),
        },
    )

    if args.check:
        return _check(artifact, args.out)

    args.out.mkdir(parents=True, exist_ok=True)
    model_path = artifact.save(args.out / "model.json")
    golden_path = save_fixture(args.out / "golden.json", artifact=artifact)

    # A cópia para o aplicativo sai da mesma execução: gerada em outro momento,
    # poderia ser de um modelo diferente do que a suíte Dart verificou.
    app_path = artifact.save(APP_ASSETS / "model.json")

    print(f"modelo:  {model_path.relative_to(REPOSITORY_ROOT)}")
    print(f"ouro:    {golden_path.relative_to(REPOSITORY_ROOT)}")
    print(f"app:     {app_path.relative_to(REPOSITORY_ROOT)}")
    print(
        f"base:    {provenance} "
        f"({artifact.metadata['n_subjects']} participantes, "
        f"{artifact.metadata['n_recordings']} gravações)"
    )
    print(
        f"validação cruzada: acurácia {artifact.metadata['cv_accuracy']:.3f}, "
        f"VPP na prevalência escolar "
        f"{artifact.metadata['ppv_at_school_prevalence']:.3f}"
    )
    return 0


#: Campos que mudam a cada execução e não descrevem o modelo.
#:
#: O instante da exportação é útil como procedência, mas compará-lo faria a
#: verificação falhar sempre -- e uma verificação que falha sempre é desligada
#: na primeira semana.
VOLATILE_METADATA = ("exported_at",)


def _stable(payload: dict) -> dict:
    """Remove os campos voláteis, para comparação."""
    copy = json.loads(json.dumps(payload))
    for field in VOLATILE_METADATA:
        copy.get("metadata", {}).pop(field, None)
    return copy


def _check(artifact, out: Path) -> int:
    """Compara os ativos commitados com os que seriam gerados agora."""
    expected = {
        "model.json": _stable(json.loads(artifact.to_json())),
        "golden.json": build_fixture(artifact=artifact),
    }

    stale = []
    for name, payload in expected.items():
        path = out / name
        if not path.exists():
            stale.append(f"{name}: não existe")
            continue

        current = json.loads(path.read_text(encoding="utf-8"))
        if name == "model.json":
            current = _stable(current)
        if current != payload:
            stale.append(f"{name}: difere do que o pipeline atual gera")

    app_model = APP_ASSETS / "model.json"
    if not app_model.exists():
        stale.append("eyelearn_app/assets/model.json: não existe")
    elif _stable(json.loads(app_model.read_text(encoding="utf-8"))) != expected[
        "model.json"
    ]:
        stale.append("eyelearn_app/assets/model.json: difere do núcleo")

    if stale:
        print("Ativos desatualizados:", file=sys.stderr)
        for problem in stale:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "\nRode: python scripts/build_mobile_assets.py",
            file=sys.stderr,
        )
        return 1

    print("ativos em dia")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
