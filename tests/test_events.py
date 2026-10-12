"""Testes da detecção de fixações e sacadas.

O gabarito vem dos percursos sintéticos: a quantidade de fixações, de sacadas,
de regressões e de retornos de linha é conhecida por construção, o que dá ao
detector um oráculo que o dado real não oferece.
"""

from __future__ import annotations

import numpy as np
import pytest

from eyelearn.signal import events
from eyelearn.synthetic import reading_trace
from eyelearn.trace import GazeTrace


@pytest.fixture(params=["ivt", "idt"])
def detector_name(request) -> str:
    """Roda o mesmo teste nos dois detectores previstos na metodologia."""
    return request.param


def detect(trace: GazeTrace, name: str) -> list[events.Fixation]:
    return {"ivt": events.ivt, "idt": events.idt}[name](trace)


class TestFixationCount:
    @pytest.mark.parametrize("n_regressions", [0, 1, 3, 6])
    def test_recovers_exact_count_from_synthetic_scanpath(
        self, detector_name: str, n_regressions: int
    ):
        trace, spec = reading_trace(
            n_lines=3, fixations_per_line=8, n_regressions=n_regressions
        )
        assert len(detect(trace, detector_name)) == spec.n_fixations

    def test_recovers_fixation_centroids(self, detector_name: str):
        # Fixações em 0, 2, 4 e 6 graus, por construção do gerador.
        trace, _ = reading_trace(n_lines=1, fixations_per_line=4, n_regressions=0)
        centroids = [f.x for f in detect(trace, detector_name)]
        assert centroids == pytest.approx([0.0, 2.0, 4.0, 6.0], abs=0.1)

    def test_recovers_fixation_durations(self, detector_name: str):
        trace, spec = reading_trace(
            n_lines=2, fixations_per_line=5, fixation_duration=0.3
        )
        durations = [f.duration for f in detect(trace, detector_name)]
        assert np.mean(durations) == pytest.approx(spec.fixation_duration, abs=0.03)

    def test_single_long_fixation_is_not_fragmented(self, detector_name: str):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=1, fixation_duration=1.0)
        assert len(detect(trace, detector_name)) == 1


class TestEmptyAndDegenerateInput:
    def test_empty_trace_yields_no_fixations(self, detector_name: str):
        trace = GazeTrace(t=np.array([]), x=np.array([]), y=np.array([]), subject_id="S01")
        assert detect(trace, detector_name) == []

    def test_single_sample_yields_no_fixations(self, detector_name: str):
        trace = GazeTrace(
            t=np.array([0.0]), x=np.array([1.0]), y=np.array([1.0]), subject_id="S01"
        )
        assert detect(trace, detector_name) == []

    def test_pure_saccade_yields_no_fixation(self):
        # Movimento contínuo a 200 graus por segundo: nada fica parado.
        t = np.arange(50) * 0.004
        trace = GazeTrace(t=t, x=t * 200.0, y=np.zeros(50), subject_id="S01")
        assert events.ivt(trace) == []

    def test_rejects_invalid_thresholds(self):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=2)
        with pytest.raises(ValueError, match="velocity_threshold"):
            events.ivt(trace, velocity_threshold=0.0)
        with pytest.raises(ValueError, match="dispersion_threshold"):
            events.idt(trace, dispersion_threshold=-1.0)


class TestMinimumDuration:
    def test_discards_fixations_below_minimum(self):
        trace, _ = reading_trace(
            n_lines=1, fixations_per_line=4, fixation_duration=0.08
        )
        assert events.ivt(trace, min_fixation_duration=0.2) == []

    def test_keeps_fixations_above_minimum(self):
        trace, spec = reading_trace(
            n_lines=1, fixations_per_line=4, fixation_duration=0.3
        )
        found = events.ivt(trace, min_fixation_duration=0.2)
        assert len(found) == spec.n_fixations


class TestSaccades:
    def test_count_is_one_less_than_fixations(self, detector_name: str):
        trace, spec = reading_trace(n_lines=3, fixations_per_line=6, n_regressions=2)
        fixations = detect(trace, detector_name)
        saccades = events.saccades_between(trace, fixations)
        assert len(saccades) == len(fixations) - 1 == spec.n_saccades

    def test_amplitude_matches_construction(self):
        trace, spec = reading_trace(
            n_lines=1, fixations_per_line=5, saccade_amplitude=3.0
        )
        saccades = events.saccades_between(trace, events.ivt(trace))
        amplitudes = [s.amplitude for s in saccades]
        assert np.mean(amplitudes) == pytest.approx(spec.saccade_amplitude, abs=0.1)

    def test_no_saccade_from_fewer_than_two_fixations(self):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=1)
        assert events.saccades_between(trace, events.ivt(trace)) == []

    def test_peak_velocity_is_positive_during_movement(self):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=4)
        saccades = events.saccades_between(trace, events.ivt(trace))
        assert all(s.peak_velocity > events.VELOCITY_THRESHOLD for s in saccades)

    def test_amplitude_is_independent_of_direction(self):
        forward = events.Saccade(0.0, 0.03, 2.0, 0.0, 70.0, "progressive")
        backward = events.Saccade(0.0, 0.03, -2.0, 0.0, 70.0, "regressive")
        assert forward.amplitude == pytest.approx(backward.amplitude)


class TestSaccadeClassification:
    def test_rightward_movement_is_progressive(self):
        assert events.classify_saccade(2.0, 0.0) == "progressive"

    def test_leftward_movement_within_line_is_regressive(self):
        assert events.classify_saccade(-2.0, 0.0) == "regressive"

    def test_leftward_descent_is_line_sweep_not_regression(self):
        # O retorno de linha é grande e para a esquerda, mas não é regressão:
        # é o salto normal para o início da linha seguinte.
        assert events.classify_saccade(-14.0, 1.5) == "line_sweep"

    def test_tiny_leftward_jitter_is_not_regression(self):
        # Ruído de centroide abaixo do limiar não deve virar regressão: a
        # proporção de regressões é uma das características discriminantes e
        # inflá-la apagaria a diferença entre os grupos.
        assert events.classify_saccade(-0.2, 0.0) == "progressive"

    def test_counts_match_synthetic_specification(self):
        trace, spec = reading_trace(n_lines=3, fixations_per_line=8, n_regressions=4)
        saccades = events.saccades_between(trace, events.ivt(trace))
        kinds = [s.kind for s in saccades]
        assert kinds.count("regressive") == spec.n_regressions
        assert kinds.count("line_sweep") == spec.n_line_sweeps


class TestDetectEvents:
    def test_does_not_create_saccade_across_a_gap(self):
        # Dois blocos parados em posições distantes, separados por meio
        # segundo sem amostra. O deslocamento entre eles não foi rastreado, e
        # contá-lo como sacada inventaria um movimento de 20 graus.
        block = np.arange(30) * 0.004
        t = np.concatenate([block, block + 1.0])
        x = np.concatenate([np.zeros(30), np.full(30, 20.0)])
        trace = GazeTrace(t=t, x=x, y=np.zeros(60), subject_id="S01")

        fixations, saccades = events.detect_events(trace, method="ivt")
        assert len(fixations) == 2
        assert saccades == []

    def test_joins_events_from_all_segments(self):
        trace, spec = reading_trace(n_lines=2, fixations_per_line=4)
        fixations, saccades = events.detect_events(trace, method="ivt")
        assert len(fixations) == spec.n_fixations
        assert len(saccades) == spec.n_saccades

    def test_rejects_unknown_method(self):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=2)
        with pytest.raises(ValueError, match="método desconhecido"):
            events.detect_events(trace, method="i-am-not-a-detector")  # type: ignore[arg-type]


class TestFixationsAreOrdered:
    def test_events_come_out_in_temporal_order(self, detector_name: str):
        trace, _ = reading_trace(n_lines=3, fixations_per_line=6, n_regressions=3)
        fixations = detect(trace, detector_name)
        starts = [f.t_start for f in fixations]
        assert starts == sorted(starts)

    def test_fixations_do_not_overlap(self, detector_name: str):
        trace, _ = reading_trace(n_lines=3, fixations_per_line=6, n_regressions=3)
        fixations = detect(trace, detector_name)
        for previous, following in zip(fixations, fixations[1:], strict=False):
            assert previous.t_end <= following.t_start
