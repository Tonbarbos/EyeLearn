"""Testes das métricas e do laço de treino."""

from __future__ import annotations

import numpy as np
import pytest
from sklearn.base import clone
from sklearn.exceptions import NotFittedError
from sklearn.utils.validation import check_is_fitted

from eyelearn.models.train import (
    SCHOOL_PREVALENCE,
    EvaluationResult,
    FoldMetrics,
    build_models,
    compare_models,
    cross_validate,
    evaluate_fold,
    ppv_at_prevalence,
)
from eyelearn.models.validation import subject_folds
from eyelearn.pipeline import build_dataset
from eyelearn.trace import DYSLEXIC, TYPICAL

#: Todo o módulo treina modelos ou gera centenas de exemplos, e fica fora
#: da seleção rápida usada pelo teste de mutação.
pytestmark = pytest.mark.slow


class TestEvaluateFold:
    def test_perfect_prediction(self):
        y = np.array([TYPICAL, TYPICAL, DYSLEXIC, DYSLEXIC])
        metrics = evaluate_fold(y, y.copy(), None)
        assert metrics.accuracy == 1.0
        assert metrics.sensitivity == 1.0
        assert metrics.specificity == 1.0
        assert metrics.f1 == 1.0

    def test_sensitivity_and_specificity_are_not_swapped(self):
        # Todos os casos detectados, todos os controles errados: sensibilidade
        # máxima e especificidade nula. Trocar as duas é um erro silencioso
        # que faria o modelo parecer útil quando ele apenas diz "sim" sempre.
        y_true = np.array([TYPICAL, TYPICAL, DYSLEXIC, DYSLEXIC])
        y_pred = np.array([DYSLEXIC, DYSLEXIC, DYSLEXIC, DYSLEXIC])
        metrics = evaluate_fold(y_true, y_pred, None)
        assert metrics.sensitivity == 1.0
        assert metrics.specificity == 0.0
        assert metrics.accuracy == 0.5

    def test_all_negative_prediction(self):
        y_true = np.array([TYPICAL, TYPICAL, DYSLEXIC, DYSLEXIC])
        y_pred = np.array([TYPICAL] * 4)
        metrics = evaluate_fold(y_true, y_pred, None)
        assert metrics.sensitivity == 0.0
        assert metrics.specificity == 1.0
        assert metrics.f1 == 0.0

    def test_auc_is_undefined_for_single_class_fold(self):
        # Com uma só classe na partição a área sob a curva não existe, e
        # inventar um valor contaminaria a média entre partições.
        y_true = np.array([DYSLEXIC, DYSLEXIC])
        metrics = evaluate_fold(y_true, y_true.copy(), np.array([0.9, 0.8]))
        assert metrics.roc_auc is None

    def test_auc_rewards_correct_ranking(self):
        y_true = np.array([TYPICAL, TYPICAL, DYSLEXIC, DYSLEXIC])
        scores = np.array([0.1, 0.2, 0.8, 0.9])
        metrics = evaluate_fold(y_true, (scores > 0.5).astype(int), scores)
        assert metrics.roc_auc == pytest.approx(1.0)

    def test_empty_fold_does_not_divide_by_zero(self):
        metrics = evaluate_fold(np.array([]), np.array([]), None)
        assert metrics.accuracy == 0.0
        assert metrics.f1 == 0.0


class TestPositivePredictiveValue:
    def test_known_value(self):
        # Com 90% de sensibilidade e 90% de especificidade numa prevalência de
        # 10%, metade dos positivos é falsa.
        assert ppv_at_prevalence(0.9, 0.9, 0.1) == pytest.approx(0.5)

    def test_perfect_test_has_no_false_positives(self):
        assert ppv_at_prevalence(1.0, 1.0, 0.1) == pytest.approx(1.0)

    def test_balanced_population(self):
        assert ppv_at_prevalence(0.8, 0.6, 0.5) == pytest.approx(2.0 / 3.0)

    def test_falls_as_the_condition_becomes_rarer(self):
        # É a razão de a seção 4.5 pedir esta métrica: a acurácia medida numa
        # base balanceada não diz quantos falsos positivos esperar na escola.
        values = [ppv_at_prevalence(0.9, 0.9, p) for p in (0.5, 0.2, 0.1, 0.05)]
        assert values == sorted(values, reverse=True)

    def test_default_prevalence_is_the_school_figure(self):
        assert ppv_at_prevalence(0.9, 0.9) == pytest.approx(
            ppv_at_prevalence(0.9, 0.9, SCHOOL_PREVALENCE)
        )

    def test_useless_test_has_no_positive_value(self):
        assert ppv_at_prevalence(0.0, 1.0, 0.1) == 0.0

    @pytest.mark.parametrize(
        ("sensitivity", "specificity", "prevalence"),
        [(1.5, 0.9, 0.1), (0.9, -0.1, 0.1), (0.9, 0.9, 2.0)],
    )
    def test_rejects_values_outside_the_unit_interval(
        self, sensitivity: float, specificity: float, prevalence: float
    ):
        with pytest.raises(ValueError, match="entre 0 e 1"):
            ppv_at_prevalence(sensitivity, specificity, prevalence)


class TestEvaluationResult:
    def test_mean_ignores_undefined_auc(self):
        result = EvaluationResult(model_name="teste")
        result.folds = [
            FoldMetrics(0.8, 0.8, 0.8, 0.8, 0.9),
            FoldMetrics(0.6, 0.6, 0.6, 0.6, None),
        ]
        assert result.mean("roc_auc") == pytest.approx(0.9)
        assert result.mean("accuracy") == pytest.approx(0.7)

    def test_mean_of_nothing_is_undefined(self):
        result = EvaluationResult(model_name="teste")
        assert np.isnan(result.mean("accuracy"))

    def test_confidence_interval_brackets_the_mean(self):
        result = EvaluationResult(model_name="teste")
        result.folds = [
            FoldMetrics(value, value, value, value, None)
            for value in (0.6, 0.7, 0.8, 0.9)
        ]
        low, high = result.confidence_interval("accuracy")
        assert low <= result.mean("accuracy") <= high

    def test_confidence_interval_narrows_with_agreement(self):
        agreeing = EvaluationResult(model_name="a")
        agreeing.folds = [FoldMetrics(0.75, 0.0, 0.0, 0.0, None) for _ in range(5)]
        spread = EvaluationResult(model_name="b")
        spread.folds = [
            FoldMetrics(value, 0.0, 0.0, 0.0, None) for value in (0.5, 0.6, 0.75, 0.9, 1.0)
        ]

        low_a, high_a = agreeing.confidence_interval("accuracy")
        low_b, high_b = spread.confidence_interval("accuracy")
        assert (high_a - low_a) < (high_b - low_b)

    def test_rejects_invalid_confidence_level(self):
        result = EvaluationResult(model_name="teste")
        result.folds = [FoldMetrics(0.8, 0.8, 0.8, 0.8, None)]
        with pytest.raises(ValueError, match="level"):
            result.confidence_interval("accuracy", level=1.5)


class TestCrossValidate:
    def test_confusion_matrix_totals_match_the_predictions(self, cohort):
        X, y, groups = build_dataset(cohort)
        folds = subject_folds(y, groups, n_splits=4, n_repeats=1)
        result = cross_validate(build_models()["logistic"], X, y, folds)

        # Cada repetição testa cada linha uma única vez.
        assert result.confusion.sum() == len(y)

    def test_confusion_matrix_rows_are_the_true_classes(self, cohort):
        X, y, groups = build_dataset(cohort)
        folds = subject_folds(y, groups, n_splits=4, n_repeats=1)
        result = cross_validate(build_models()["logistic"], X, y, folds)

        assert result.confusion[0].sum() == int(np.sum(y == TYPICAL))
        assert result.confusion[1].sum() == int(np.sum(y == DYSLEXIC))

    def test_does_not_fit_the_model_passed_in(self, cohort):
        # Reaproveitar a mesma instância entre partições deixaria o ajuste de
        # uma influenciar a seguinte.
        X, y, groups = build_dataset(cohort)
        model = build_models()["logistic"]
        cross_validate(model, X, y, subject_folds(y, groups, n_splits=4, n_repeats=1))

        with pytest.raises(NotFittedError):
            check_is_fitted(model.named_steps["clf"])

    def test_produces_one_metric_set_per_fold(self, cohort):
        X, y, groups = build_dataset(cohort)
        folds = subject_folds(y, groups, n_splits=4, n_repeats=2)
        result = cross_validate(build_models()["logistic"], X, y, folds)
        assert len(result.folds) == len(folds)

    def test_beats_chance_on_the_synthetic_cohort(self, cohort):
        # A coorte foi construída com dois perfis sobrepostos mas distintos.
        # Desempenho ao nível do acaso indicaria que o sinal se perdeu entre o
        # percurso e a característica.
        X, y, groups = build_dataset(cohort)
        folds = subject_folds(y, groups, n_splits=4, n_repeats=3)
        result = cross_validate(build_models()["random_forest"], X, y, folds)
        assert result.mean("accuracy") > 0.6


class TestModelCatalogue:
    def test_includes_a_linear_baseline(self):
        # Sem linha de base não há como saber se o ganho de um modelo mais
        # complexo é real ou se o problema já era linearmente separável.
        assert "logistic" in build_models()

    def test_every_model_standardises_its_input(self):
        for name, model in build_models().items():
            assert "scaler" in model.named_steps, name

    def test_models_are_unfitted_on_creation(self):
        for model in build_models().values():
            with pytest.raises(NotFittedError):
                check_is_fitted(model.named_steps["clf"])

    def test_clone_preserves_configuration(self):
        for model in build_models().values():
            assert clone(model).get_params().keys() == model.get_params().keys()

    def test_comparison_evaluates_every_model(self, cohort):
        X, y, groups = build_dataset(cohort)
        results = compare_models(X, y, groups, n_splits=4, n_repeats=1)
        assert set(results) == set(build_models())

    def test_comparison_uses_the_same_folds_for_all_models(self, cohort):
        # Comparar modelos sobre divisões diferentes misturaria a diferença
        # entre algoritmos com a diferença entre sorteios.
        X, y, groups = build_dataset(cohort)
        results = compare_models(X, y, groups, n_splits=4, n_repeats=2)
        fold_counts = {len(result.folds) for result in results.values()}
        assert len(fold_counts) == 1

    def test_all_models_expose_a_positive_class_score(self, cohort):
        # Sem pontuação contínua não há área sob a curva, que a seção 4.5 pede.
        X, y, groups = build_dataset(cohort)
        results = compare_models(X, y, groups, n_splits=4, n_repeats=1)
        for name, result in results.items():
            assert not np.isnan(result.mean("roc_auc")), name
