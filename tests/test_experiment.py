"""Testes do experimento da curva de degradação.

Os testes verificam a estrutura e a aritmética da curva, não os valores de
acurácia. Fixar um valor de acurácia aqui prenderia o teste ao gerador
sintético e quebraria a cada ajuste nele -- sem dizer nada sobre corretude. O
resultado científico vem do ETDD70, não destes testes.
"""

from __future__ import annotations

import numpy as np
import pytest

from eyelearn.degradation.degrade import DegradationLevel
from eyelearn.experiments.degradation_curve import accuracy_drop, run_degradation_curve
from eyelearn.models.train import build_models
from eyelearn.pipeline import PipelineConfig, build_dataset

#: Todo o módulo treina modelos ou gera centenas de exemplos, e fica fora
#: da seleção rápida usada pelo teste de mutação.
pytestmark = pytest.mark.slow

#: Grade reduzida: dois níveis bastam para exercitar o laço, e a grade
#: completa multiplicaria o tempo da suíte por sete.
LEVELS = [
    DegradationLevel(None, 0.0, "original"),
    DegradationLevel(30.0, 1.0, "30 Hz + 1,0°"),
]


@pytest.fixture(scope="module")
def curve(cohort):
    return run_degradation_curve(
        cohort, levels=LEVELS, n_splits=4, n_repeats=1, seed=0
    )


class TestCurveStructure:
    def test_one_row_per_level_and_model(self, curve):
        assert len(curve) == len(LEVELS) * len(build_models())

    def test_carries_every_reported_metric(self, curve):
        expected = {
            "level",
            "sampling_rate_hz",
            "noise_sigma_deg",
            "model",
            "accuracy",
            "accuracy_ci_low",
            "accuracy_ci_high",
            "sensitivity",
            "specificity",
            "f1",
            "roc_auc",
            "ppv_at_prevalence",
        }
        assert expected <= set(curve.columns)

    def test_metrics_are_proportions(self, curve):
        for column in ("accuracy", "sensitivity", "specificity", "f1", "roc_auc"):
            assert curve[column].between(0.0, 1.0).all(), column

    def test_confidence_interval_brackets_the_mean(self, curve):
        assert (curve["accuracy_ci_low"] <= curve["accuracy"]).all()
        assert (curve["accuracy"] <= curve["accuracy_ci_high"]).all()

    def test_levels_appear_in_the_requested_order(self, curve):
        assert list(curve["level"].unique()) == [level.label for level in LEVELS]

    def test_positive_predictive_value_is_below_accuracy(self, curve):
        # A base é balanceada e a prevalência escolar é de cerca de 10%: o
        # valor preditivo positivo tem de ficar bem abaixo da acurácia. Vê-los
        # próximos indicaria que o ajuste de prevalência não foi aplicado.
        assert (curve["ppv_at_prevalence"] < curve["accuracy"]).all()


class TestDegradationIsActuallyApplied:
    def test_features_change_with_degradation(self, cohort):
        # Se a degradação não alterasse as características, a curva seria
        # plana por construção e o experimento não mediria nada.
        config = PipelineConfig()
        rng = np.random.default_rng(0)

        original, _, _ = build_dataset(cohort, config=config, level=LEVELS[0])
        degraded, _, _ = build_dataset(cohort, config=config, level=LEVELS[1], rng=rng)

        assert not np.allclose(original, degraded)

    def test_labels_and_groups_survive_degradation(self, cohort):
        config = PipelineConfig()
        _, y_clean, g_clean = build_dataset(cohort, config=config)
        _, y_degraded, g_degraded = build_dataset(
            cohort, config=config, level=LEVELS[1], rng=np.random.default_rng(0)
        )
        assert np.array_equal(y_clean, y_degraded)
        assert np.array_equal(g_clean, g_degraded)

    def test_is_reproducible_for_a_given_seed(self, cohort):
        first = run_degradation_curve(
            cohort, levels=LEVELS, n_splits=4, n_repeats=1, seed=5
        )
        second = run_degradation_curve(
            cohort, levels=LEVELS, n_splits=4, n_repeats=1, seed=5
        )
        assert np.allclose(first["accuracy"], second["accuracy"])


class TestAccuracyDrop:
    def test_baseline_has_no_drop(self, curve):
        drop = accuracy_drop(curve, "random_forest")
        assert drop.iloc[0]["drop"] == pytest.approx(0.0)

    def test_drop_is_in_percentage_points(self, curve):
        drop = accuracy_drop(curve, "random_forest")
        baseline = float(drop.iloc[0]["accuracy"])
        for _, row in drop.iterrows():
            assert row["drop"] == pytest.approx((baseline - row["accuracy"]) * 100.0)

    def test_covers_every_level(self, curve):
        assert len(accuracy_drop(curve, "svm")) == len(LEVELS)

    def test_unknown_model_is_reported_with_the_alternatives(self, curve):
        with pytest.raises(ValueError, match="random_forest"):
            accuracy_drop(curve, "rede_neural")


class TestEmptyInput:
    def test_unlabelled_traces_are_reported(self, cohort):
        unlabelled = [
            trace.__class__(
                t=trace.t, x=trace.x, y=trace.y, subject_id=trace.subject_id
            )
            for trace in cohort[:6]
        ]
        with pytest.raises(ValueError, match="nenhum percurso rotulado"):
            run_degradation_curve(unlabelled, levels=LEVELS[:1], n_splits=2, n_repeats=1)
