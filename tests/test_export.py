"""Testes da exportação do modelo e dos vetores de ouro.

O artefato é a fronteira entre o treino em Python e a inferência no aparelho.
Um defeito aqui não quebra nada visivelmente: o aplicativo carrega, roda e
devolve predições erradas. Os testes verificam as duas pontas da fronteira --
que o artefato reproduz o scikit-learn, e que o arquivo de vetores de ouro
descreve exatamente a extração que o artefato espera.
"""

from __future__ import annotations

import json

import numpy as np
import pytest
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.tree import DecisionTreeClassifier

from eyelearn.export.artifact import (
    ARTIFACT_VERSION,
    ModelArtifact,
    UnsupportedModelError,
    export_artifact,
)
from eyelearn.export.golden import GOLDEN_VERSION, build_fixture, reference_cases
from eyelearn.features.reading import FEATURE_NAMES
from eyelearn.models.train import build_models
from eyelearn.pipeline import PipelineConfig, build_dataset

pytestmark = pytest.mark.slow

MODEL_NAMES = sorted(build_models())


@pytest.fixture(scope="module")
def dataset(cohort):
    return build_dataset(cohort)


@pytest.fixture(scope="module")
def artifact(fitted_models):
    """Artefato da regressão logística, o modelo embarcado por padrão."""
    return export_artifact(fitted_models["logistic"])


@pytest.fixture(scope="module")
def fitted_models(dataset):
    """Um modelo ajustado de cada tipo, reaproveitado entre os testes."""
    X, y, _ = dataset
    models = {}
    for name, model in build_models().items():
        model.fit(X, y)
        models[name] = model
    return models


class TestReproducesScikitLearn:
    """O artefato é a implementação de referência da fronteira.

    Se a pontuação calculada a partir do artefato concorda com o modelo
    original, a exportação não perdeu nada -- e o que o aparelho tem de
    conferir passa a ser apenas a aritmética, não a completude do arquivo.
    """

    @pytest.mark.parametrize("name", MODEL_NAMES)
    def test_score_matches_the_original_model(self, name, fitted_models, dataset):
        X, _, _ = dataset
        model = fitted_models[name]
        artifact = export_artifact(model)

        if artifact.score_kind == "probability":
            reference = model.predict_proba(X)[:, 1]
        else:
            reference = model.decision_function(X)

        assert artifact.score(X) == pytest.approx(reference, abs=1e-12)

    @pytest.mark.parametrize("name", MODEL_NAMES)
    def test_prediction_matches_the_original_model(
        self, name, fitted_models, dataset
    ):
        X, _, _ = dataset
        model = fitted_models[name]
        assert np.array_equal(export_artifact(model).predict(X), model.predict(X))

    def test_forest_matches_bit_for_bit(self, fitted_models, dataset):
        # A floresta é o caso em que a concordância é exata, e por um motivo
        # que custou achar: as árvores do scikit-learn convertem a entrada para
        # precisão simples antes de percorrer, mas guardam os limiares em
        # precisão dupla. Sem reproduzir a conversão, a travessia cai em outra
        # folha e a saída daquela árvore erra por até 1,0.
        X, _, _ = dataset
        model = fitted_models["random_forest"]
        artifact = export_artifact(model)
        assert np.array_equal(artifact.score(X), model.predict_proba(X)[:, 1])

    def test_single_row_and_batch_agree(self, fitted_models, dataset):
        X, _, _ = dataset
        artifact = export_artifact(fitted_models["logistic"])
        batch = artifact.score(X)
        for row in range(min(5, X.shape[0])):
            assert artifact.score(X[row]) == pytest.approx(batch[row], abs=1e-15)


class TestArtifactContents:
    def test_declares_the_canonical_feature_order(self, fitted_models):
        # A ordem viaja dentro do artefato porque é o que impede o aparelho de
        # montar o vetor com as colunas trocadas.
        artifact = export_artifact(fitted_models["logistic"])
        assert artifact.feature_names == list(FEATURE_NAMES)

    def test_carries_the_preprocessing_parameters(self, fitted_models):
        config = PipelineConfig(method="idt", smoothing_ms=12.0, max_gap=0.1)
        artifact = export_artifact(fitted_models["logistic"], config=config)

        assert artifact.preprocessing["method"] == "idt"
        assert artifact.preprocessing["smoothing_ms"] == 12.0
        assert artifact.preprocessing["max_gap"] == 0.1

    def test_records_provenance(self, fitted_models):
        artifact = export_artifact(
            fitted_models["logistic"], metadata={"training_data": "etdd70"}
        )
        assert artifact.metadata["training_data"] == "etdd70"
        assert artifact.metadata["positive_class"] == "dyslexic"
        assert "exported_at" in artifact.metadata

    def test_scaler_has_one_entry_per_feature(self, fitted_models):
        artifact = export_artifact(fitted_models["logistic"])
        assert len(artifact.scaler["mean"]) == len(FEATURE_NAMES)
        assert len(artifact.scaler["scale"]) == len(FEATURE_NAMES)

    @pytest.mark.parametrize(
        ("name", "expected"),
        [
            ("logistic", "probability"),
            ("svm", "decision"),
            ("random_forest", "probability"),
        ],
    )
    def test_declares_the_score_kind(self, name, expected, fitted_models):
        # O aplicativo precisa saber se a pontuação é probabilidade ou
        # distância à fronteira: o limiar de decisão é 0,5 num caso e 0 no
        # outro.
        assert export_artifact(fitted_models[name]).score_kind == expected

    def test_logistic_artifact_stays_small(self, fitted_models):
        # O aplicativo embarca o arquivo. Dois quilobytes contra meio megabyte
        # da floresta é a razão de a regressão logística ser o modelo padrão.
        artifact = export_artifact(fitted_models["logistic"])
        assert len(artifact.to_json()) < 8 * 1024


class TestRoundTrip:
    @pytest.mark.parametrize("name", MODEL_NAMES)
    def test_survives_json_round_trip(self, name, fitted_models, dataset):
        X, _, _ = dataset
        artifact = export_artifact(fitted_models[name])
        restored = ModelArtifact.from_dict(json.loads(artifact.to_json()))
        assert restored.score(X) == pytest.approx(artifact.score(X), abs=1e-15)

    def test_saves_and_loads_from_disk(self, fitted_models, dataset, tmp_path):
        X, _, _ = dataset
        artifact = export_artifact(fitted_models["random_forest"])
        path = artifact.save(tmp_path / "nested" / "model.json")

        assert path.exists()
        assert np.array_equal(ModelArtifact.load(path).score(X), artifact.score(X))

    def test_rejects_unknown_version(self, fitted_models):
        payload = json.loads(export_artifact(fitted_models["logistic"]).to_json())
        payload["version"] = ARTIFACT_VERSION + 1
        with pytest.raises(ValueError, match="versão de artefato"):
            ModelArtifact.from_dict(payload)

    def test_rejects_wrong_feature_count(self, fitted_models):
        artifact = export_artifact(fitted_models["logistic"])
        with pytest.raises(ValueError, match="características"):
            artifact.score(np.zeros((1, len(FEATURE_NAMES) - 1)))


class TestUnsupportedModels:
    def test_rejects_unexportable_classifier(self):
        model = Pipeline(
            [("scaler", StandardScaler()), ("clf", DecisionTreeClassifier())]
        )
        X = np.random.default_rng(0).normal(size=(20, len(FEATURE_NAMES)))
        model.fit(X, np.array([0, 1] * 10))

        with pytest.raises(UnsupportedModelError, match="DecisionTree"):
            export_artifact(model)

    def test_rejects_pipeline_without_the_expected_steps(self):
        model = Pipeline([("clf", build_models()["logistic"].named_steps["clf"])])
        with pytest.raises(ValueError, match="'scaler' e 'clf'"):
            export_artifact(model)

    def test_rejects_unfitted_scaler(self):
        model = build_models()["logistic"]
        with pytest.raises(ValueError, match="StandardScaler ajustado"):
            export_artifact(model)


class TestGoldenFixture:
    def test_declares_its_version(self, artifact):
        assert build_fixture(artifact=artifact)["version"] == GOLDEN_VERSION

    def test_covers_every_reference_case(self, artifact):
        fixture = build_fixture(artifact=artifact)
        assert len(fixture["cases"]) == len(reference_cases())

    def test_case_identifiers_are_unique(self, artifact):
        ids = [case["id"] for case in build_fixture(artifact=artifact)["cases"]]
        assert len(set(ids)) == len(ids)

    def test_includes_degenerate_cases(self, artifact):
        # São onde as convenções de cada linguagem divergem: lista vazia,
        # divisão por zero, piscada do início ao fim.
        ids = {case["id"] for case in build_fixture(artifact=artifact)["cases"]}
        assert {"vazio", "amostra_unica", "tudo_perdido", "com_buraco"} <= ids

    def test_samples_are_written_at_full_precision(self, artifact):
        # O arredondamento das amostras tornava o arquivo auto-inconsistente:
        # as expectativas vinham do percurso em precisão plena e o arquivo
        # guardava o percurso arredondado, de modo que a suíte Dart recebia
        # outra entrada e falhava sem que houvesse defeito na porta.
        fixture = build_fixture(artifact=artifact)
        case = next(c for c in fixture["cases"] if c["id"] == "leitura_simples")
        original = next(
            c.trace for c in reference_cases() if c.case_id == "leitura_simples"
        )

        assert case["samples"]["t"] == pytest.approx(
            original.t.tolist(), abs=0.0, rel=0.0
        )

    def test_blinks_are_written_as_null(self, artifact):
        # NaN não é JSON válido. Deixá-lo chegar como zero daria uma
        # coordenada legítima no centro da tela onde houve piscada.
        fixture = build_fixture(artifact=artifact)
        case = next(c for c in fixture["cases"] if c["id"] == "tudo_perdido")
        assert all(value is None for value in case["samples"]["x"])

    def test_serialises_to_valid_json(self, artifact):
        # json.dumps aceita NaN por padrão e produz um arquivo que outros
        # leitores recusam; allow_nan=False falha alto se algum escapar.
        payload = build_fixture(artifact=artifact)
        json.dumps(payload, allow_nan=False)

    def test_describes_the_extraction_the_artifact_expects(self, artifact):
        # Montados de fontes separadas, o arquivo e o artefato poderiam
        # divergir, e a suíte Dart passaria a validar a coisa errada.
        fixture = build_fixture(artifact=artifact)
        assert fixture["preprocessing"] == artifact.preprocessing

    def test_feature_order_matches_the_artifact(self, artifact):
        fixture = build_fixture(artifact=artifact)
        assert fixture["feature_names"] == artifact.feature_names

    def test_every_case_carries_score_and_label(self, artifact):
        for case in build_fixture(artifact=artifact)["cases"]:
            assert "score" in case["expected"], case["id"]
            assert case["expected"]["label"] in (0, 1), case["id"]

    def test_expected_features_are_complete(self, artifact):
        for case in build_fixture(artifact=artifact)["cases"]:
            assert set(case["expected"]["features"]) == set(FEATURE_NAMES), case["id"]

    def test_fixture_without_artifact_omits_the_score(self):
        # Sem modelo, o arquivo ainda verifica a extração -- é útil durante o
        # desenvolvimento do pipeline, antes de haver modelo treinado.
        for case in build_fixture()["cases"]:
            assert "score" not in case["expected"]

    def test_saves_to_disk(self, artifact, tmp_path):
        from eyelearn.export.golden import save_fixture

        path = save_fixture(tmp_path / "golden.json", artifact=artifact)
        loaded = json.loads(path.read_text(encoding="utf-8"))
        assert loaded["version"] == GOLDEN_VERSION
