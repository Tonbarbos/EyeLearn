"""Gera os ativos que o aplicativo do aluno embarca.

Produz em ``mobile/eyelearn_core/assets``:

* ``model_<tarefa>.json`` -- um modelo por tarefa (``syllables``, ``text``,
  ``pseudotext``), em formato portátil, lido pelo aparelho. Um por tarefa
  porque o padrão de leitura muda muito de uma tarefa para outra: no ETDD70,
  um modelo único para as três acerta 77%, e um por tarefa, de 80% a 86%. O
  aplicativo sabe a tarefa -- ela vem do QR do professor -- e escolhe o
  modelo;
* ``golden.json`` -- os vetores de ouro, lidos pela suíte Dart para verificar
  que a porta do pipeline concorda com o Python. Usa o modelo de ``text``.

Os dois saem da mesma execução de propósito. Gerados em momentos diferentes,
poderiam descrever extrações diferentes, e a suíte Dart passaria a validar algo
que o modelo embarcado não espera.

Uso::

    python scripts/build_mobile_assets.py                      # coorte sintética
    python scripts/build_mobile_assets.py --etdd70 PASTA_DO_DATA_ZIP \\
        --labels dyslexia_class_label.csv                      # base real

Sem ``--etdd70`` os modelos são treinados na coorte sintética. Serve para exercitar
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

from eyelearn.data.etdd70 import load_etdd70  # noqa: E402
from eyelearn.export.artifact import ModelArtifact, export_artifact  # noqa: E402
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

TASKS = ("syllables", "text", "pseudotext")

#: Tarefa cujo modelo gera os vetores de ouro. Texto com sentido: é a leitura
#: mais próxima da de sala de aula.
GOLDEN_TASK = "text"


def model_file(task: str) -> str:
    return f"model_{task}.json"


def synthetic_cohort() -> list[GazeTrace]:
    """Coorte sintética, a mesma que a suíte de testes usa."""
    sys.path.insert(0, str(REPOSITORY_ROOT / "tests"))
    from conftest import make_cohort  # noqa: PLC0415

    return make_cohort(n_per_group=12)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--etdd70", type=Path, help="pasta onde data.zip foi extraído")
    parser.add_argument("--labels", type=Path, help="dyslexia_class_label.csv")
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        choices=sorted(build_models()),
        help=f"modelo a embarcar (padrão: {DEFAULT_MODEL})",
    )
    parser.add_argument("--out", type=Path, default=ASSETS, help="pasta de saída dos ativos")
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "não escreve nada; confere que os ativos commitados estão coerentes "
            "entre si e com o pipeline atual. Usado na integração contínua."
        ),
    )
    args = parser.parse_args()

    if args.check:
        return _check(args.out)

    if args.etdd70:
        dataset = load_etdd70(args.etdd70, args.labels)
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

    artifacts = {
        task: train_artifact([t for t in traces if t.task == task], task, provenance, args)
        for task in TASKS
    }

    args.out.mkdir(parents=True, exist_ok=True)
    for task, artifact in artifacts.items():
        artifact.save(args.out / model_file(task))
        # A cópia para o aplicativo sai da mesma execução: gerada em outro
        # momento, poderia ser de um modelo diferente do que a suíte Dart
        # verificou.
        artifact.save(APP_ASSETS / model_file(task))
        meta = artifact.metadata
        print(
            f"{task:>10}: {meta['n_subjects']} participantes, acurácia "
            f"{meta['cv_accuracy']:.3f}, AUC {meta['cv_roc_auc']:.3f}, "
            f"VPP {meta['ppv_at_school_prevalence']:.3f}"
        )
    for stale in (args.out / "model.json", APP_ASSETS / "model.json"):
        stale.unlink(missing_ok=True)  # o modelo único da versão anterior

    save_fixture(args.out / "golden.json", artifact=artifacts[GOLDEN_TASK])
    print(f"base: {provenance}; ativos em {args.out.relative_to(REPOSITORY_ROOT)}")
    return 0


def train_artifact(traces, task: str, provenance: str, args) -> ModelArtifact:
    config = PipelineConfig()
    X, y, groups = build_dataset(traces, config=config)
    if X.shape[0] == 0:
        raise SystemExit(f"nenhum percurso rotulado para a tarefa {task}")

    model = build_models()[args.model]

    # A validação cruzada roda antes do ajuste final e com separação por
    # sujeito: o número que vai para o artefato tem de ser o desempenho
    # honesto, não o acerto do modelo sobre os próprios dados de treino.
    folds = subject_folds(y, groups, n_splits=5, n_repeats=5)
    evaluation = cross_validate(model, X, y, folds, model_name=args.model)

    model.fit(X, y)
    return export_artifact(
        model,
        config=config,
        metadata={
            "task": task,
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


def _check(out: Path) -> int:
    """Confere os ativos commitados.

    Não retreina: o modelo embarcado é treinado no ETDD70, que a integração
    contínua não tem. O que se confere é o que pode quebrar sem ninguém ver:

    * os vetores de ouro são os que o pipeline **atual** produz com o modelo
      commitado -- se alguém mudar a extração e esquecer de regerar, a suíte
      Dart continuaria passando contra um arquivo velho;
    * as cópias do aplicativo são idênticas às do núcleo;
    * cada modelo declara a tarefa do próprio nome.
    """
    stale = []
    artifacts = {}
    for task in TASKS:
        path = out / model_file(task)
        if not path.exists():
            stale.append(f"{model_file(task)}: não existe")
            continue
        artifacts[task] = ModelArtifact.load(path)
        if artifacts[task].metadata.get("task") != task:
            stale.append(f"{model_file(task)}: declara outra tarefa")
        app_copy = APP_ASSETS / model_file(task)
        if not app_copy.exists() or _stable(
            json.loads(app_copy.read_text(encoding="utf-8"))
        ) != _stable(json.loads(path.read_text(encoding="utf-8"))):
            stale.append(f"eyelearn_app/assets/{model_file(task)}: difere do núcleo")

    golden = out / "golden.json"
    if GOLDEN_TASK in artifacts:
        expected = build_fixture(artifact=artifacts[GOLDEN_TASK])
        if not golden.exists():
            stale.append("golden.json: não existe")
        elif json.loads(golden.read_text(encoding="utf-8")) != expected:
            stale.append("golden.json: difere do que o pipeline atual gera")

    if stale:
        print("Ativos desatualizados:", file=sys.stderr)
        for problem in stale:
            print(f"  - {problem}", file=sys.stderr)
        print("\nRode: python scripts/build_mobile_assets.py --etdd70 ...", file=sys.stderr)
        return 1

    provenance = {a.metadata.get("training_data") for a in artifacts.values()}
    print(f"ativos em dia ({', '.join(sorted(provenance))})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
