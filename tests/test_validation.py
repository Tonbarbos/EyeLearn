"""Testes da validação cruzada com separação por sujeito.

A metodologia (seção 4.4) chama o vazamento por sujeito de "erro metodológico
mais comum nesse tipo de experimento" e prevê um teste automatizado contra ele.
Este é o teste.
"""

from __future__ import annotations

import numpy as np
import pytest
from sklearn.model_selection import RepeatedStratifiedKFold

from eyelearn.models.train import build_models, cross_validate
from eyelearn.models.validation import (
    Fold,
    SubjectLeakageError,
    assert_no_subject_leakage,
    subject_folds,
)
from eyelearn.pipeline import build_dataset


@pytest.fixture
def labels_and_groups() -> tuple[np.ndarray, np.ndarray]:
    """Vinte participantes com três gravações cada, metade em cada classe."""
    subjects = [f"S{index:02d}" for index in range(20)]
    groups = np.array([subject for subject in subjects for _ in range(3)], dtype=object)
    y = np.array([0 if int(s[1:]) < 10 else 1 for s in subjects for _ in range(3)])
    return y, groups


class TestNoLeakage:
    def test_every_fold_separates_subjects(self, labels_and_groups):
        y, groups = labels_and_groups
        for fold in subject_folds(y, groups, n_splits=5, n_repeats=3):
            assert not set(groups[fold.train]) & set(groups[fold.test])

    def test_all_recordings_of_a_subject_stay_together(self, labels_and_groups):
        y, groups = labels_and_groups
        for fold in subject_folds(y, groups, n_splits=5, n_repeats=2):
            for subject in set(groups[fold.test]):
                recordings = np.flatnonzero(groups == subject)
                assert set(recordings).issubset(set(fold.test.tolist()))

    def test_detector_reports_the_offending_subjects(self):
        with pytest.raises(SubjectLeakageError, match="S03"):
            assert_no_subject_leakage(
                np.array(["S01", "S03"], dtype=object),
                np.array(["S03", "S07"], dtype=object),
            )

    def test_detector_accepts_disjoint_groups(self):
        assert_no_subject_leakage(
            np.array(["S01", "S02"], dtype=object),
            np.array(["S03", "S04"], dtype=object),
        )

    @pytest.mark.slow
    def test_leakage_inflates_measured_accuracy(self, cohort):
        # Demonstra por que a separação é obrigatória. Sem ela, o modelo
        # reconhece o indivíduo -- que aparece em três gravações -- em vez do
        # padrão de leitura, e o desempenho medido sobe sem que o modelo tenha
        # melhorado.
        X, y, groups = build_dataset(cohort)
        model = build_models()["random_forest"]

        honest = cross_validate(
            model, X, y, subject_folds(y, groups, n_splits=4, n_repeats=4)
        )
        leaky_splits = [
            Fold(train=train, test=test)
            for train, test in RepeatedStratifiedKFold(
                n_splits=4, n_repeats=4, random_state=0
            ).split(X, y)
        ]
        leaky = cross_validate(model, X, y, leaky_splits)

        assert leaky.mean("accuracy") > honest.mean("accuracy") + 0.03


class TestFoldStructure:
    def test_produces_splits_times_repeats_folds(self, labels_and_groups):
        y, groups = labels_and_groups
        folds = subject_folds(y, groups, n_splits=5, n_repeats=4)
        assert len(folds) == 20

    def test_each_repeat_covers_every_row_exactly_once(self, labels_and_groups):
        y, groups = labels_and_groups
        folds = subject_folds(y, groups, n_splits=5, n_repeats=3)

        for repeat in range(3):
            test_indices = np.concatenate(
                [fold.test for fold in folds if fold.repeat == repeat]
            )
            assert sorted(test_indices.tolist()) == list(range(len(y)))

    def test_train_and_test_partition_the_rows(self, labels_and_groups):
        y, groups = labels_and_groups
        for fold in subject_folds(y, groups, n_splits=5, n_repeats=2):
            assert not set(fold.train.tolist()) & set(fold.test.tolist())
            assert len(fold.train) + len(fold.test) == len(y)

    def test_repeats_produce_different_partitions(self, labels_and_groups):
        # Sem reembaralhar, as repetições não acrescentariam informação e o
        # intervalo de confiança da seção 4.5 teria largura zero.
        y, groups = labels_and_groups
        folds = subject_folds(y, groups, n_splits=5, n_repeats=2)
        first = [set(f.test.tolist()) for f in folds if f.repeat == 0]
        second = [set(f.test.tolist()) for f in folds if f.repeat == 1]
        assert first != second

    def test_both_classes_appear_in_each_test_fold(self, labels_and_groups):
        # A estratificação é o que mantém a área sob a curva definida em cada
        # partição.
        y, groups = labels_and_groups
        for fold in subject_folds(y, groups, n_splits=5, n_repeats=2):
            assert len(np.unique(y[fold.test])) == 2

    def test_is_reproducible_for_a_given_seed(self, labels_and_groups):
        y, groups = labels_and_groups
        first = subject_folds(y, groups, n_splits=5, n_repeats=2, seed=11)
        second = subject_folds(y, groups, n_splits=5, n_repeats=2, seed=11)
        assert all(
            np.array_equal(a.test, b.test) for a, b in zip(first, second, strict=True)
        )


class TestInputValidation:
    def test_rejects_mismatched_lengths(self):
        with pytest.raises(ValueError, match="mesmo tamanho"):
            subject_folds(np.zeros(5), np.array(["a", "b"], dtype=object))

    def test_rejects_fewer_subjects_than_folds(self):
        y = np.array([0, 1, 0, 1])
        groups = np.array(["S1", "S1", "S2", "S2"], dtype=object)
        with pytest.raises(ValueError, match="partições"):
            subject_folds(y, groups, n_splits=5)

    def test_rejects_degenerate_split_counts(self):
        y = np.array([0, 1] * 10)
        groups = np.array([f"S{i}" for i in range(20)], dtype=object)
        with pytest.raises(ValueError, match="n_splits"):
            subject_folds(y, groups, n_splits=1)
        with pytest.raises(ValueError, match="n_repeats"):
            subject_folds(y, groups, n_splits=5, n_repeats=0)
