"""Testes da degradação controlada do sinal.

A degradação é o instrumento de medida do experimento principal. Um defeito
aqui não quebra o pipeline: produz silenciosamente uma curva de acurácia
errada, que é pior do que nenhuma curva.
"""

from __future__ import annotations

import numpy as np
import pytest

from eyelearn.degradation import degrade as deg
from eyelearn.synthetic import reading_trace


class TestDownsample:
    @pytest.mark.parametrize("target_hz", [30.0, 60.0, 120.0])
    def test_reaches_target_rate(self, target_hz: float):
        trace, _ = reading_trace(n_lines=3, fixations_per_line=8, sampling_rate=250.0)
        reduced = deg.downsample(trace, target_hz)
        assert reduced.sampling_rate == pytest.approx(target_hz, rel=0.1)

    def test_reduces_sample_count(self):
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6, sampling_rate=250.0)
        assert len(deg.downsample(trace, 50.0)) < len(trace)

    def test_keeps_only_measured_positions(self):
        # Nenhuma interpolação: o percurso reduzido tem de ser um subconjunto
        # das amostras originais, como aconteceria numa câmera mais lenta.
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6, sampling_rate=250.0)
        reduced = deg.downsample(trace, 50.0)
        assert np.all(np.isin(reduced.t, trace.t))
        assert np.all(np.isin(reduced.x, trace.x))

    def test_higher_target_rate_is_a_no_op(self):
        # Reduzir não pode inventar amostras.
        trace, _ = reading_trace(n_lines=1, fixations_per_line=4, sampling_rate=60.0)
        assert len(deg.downsample(trace, 500.0)) == len(trace)

    def test_preserves_temporal_order_and_metadata(self):
        trace, _ = reading_trace(
            n_lines=2, fixations_per_line=6, subject_id="S42", label=1
        )
        reduced = deg.downsample(trace, 40.0)
        assert np.all(np.diff(reduced.t) > 0)
        assert reduced.subject_id == "S42"
        assert reduced.label == 1

    def test_covers_the_original_time_span(self):
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6)
        reduced = deg.downsample(trace, 30.0)
        assert reduced.duration == pytest.approx(trace.duration, abs=1.0 / 30.0)

    def test_rejects_non_positive_rate(self):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=2)
        with pytest.raises(ValueError, match="target_hz"):
            deg.downsample(trace, 0.0)


class TestSpatialNoise:
    def test_zero_sigma_is_a_no_op(self):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=4)
        noisy = deg.add_spatial_noise(trace, 0.0)
        assert np.array_equal(noisy.x, trace.x)

    def test_noise_has_the_requested_standard_deviation(self, rng):
        trace, _ = reading_trace(n_lines=5, fixations_per_line=10, jitter_deg=0.0)
        noisy = deg.add_spatial_noise(trace, 0.6, rng)
        residual = noisy.x - trace.x
        assert np.std(residual) == pytest.approx(0.6, rel=0.1)
        assert np.mean(residual) == pytest.approx(0.0, abs=0.05)

    def test_noise_does_not_change_sampling(self):
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6)
        noisy = deg.add_spatial_noise(trace, 1.0, np.random.default_rng(0))
        assert np.array_equal(noisy.t, trace.t)

    def test_is_reproducible_with_a_seeded_generator(self):
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6)
        first = deg.add_spatial_noise(trace, 0.5, np.random.default_rng(7))
        second = deg.add_spatial_noise(trace, 0.5, np.random.default_rng(7))
        assert np.array_equal(first.x, second.x)

    def test_axes_receive_independent_noise(self, rng):
        trace, _ = reading_trace(n_lines=5, fixations_per_line=10, jitter_deg=0.0)
        noisy = deg.add_spatial_noise(trace, 0.6, rng)
        correlation = np.corrcoef(noisy.x - trace.x, noisy.y - trace.y)[0, 1]
        assert abs(correlation) < 0.1

    def test_rejects_negative_sigma(self):
        trace, _ = reading_trace(n_lines=1, fixations_per_line=2)
        with pytest.raises(ValueError, match="sigma_deg"):
            deg.add_spatial_noise(trace, -0.5)


class TestDegrade:
    def test_applies_both_dimensions(self, rng):
        trace, _ = reading_trace(n_lines=3, fixations_per_line=8, sampling_rate=250.0)
        level = deg.DegradationLevel(30.0, 0.6, "teste")
        degraded = deg.degrade(trace, level, rng)

        assert degraded.sampling_rate == pytest.approx(30.0, rel=0.1)
        assert len(degraded) < len(trace)

    def test_original_level_leaves_the_signal_untouched(self):
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6)
        level = deg.DegradationLevel(None, 0.0, "original")
        degraded = deg.degrade(trace, level)
        assert np.array_equal(degraded.x, trace.x)
        assert np.array_equal(degraded.t, trace.t)

    def test_rate_is_reduced_before_noise_is_added(self, rng):
        # Na ordem inversa, a subamostragem descartaria parte das amostras já
        # contaminadas, o que equivaleria a uma média local e atenuaria o
        # ruído que se quer medir.
        trace, _ = reading_trace(n_lines=5, fixations_per_line=10, jitter_deg=0.0)
        level = deg.DegradationLevel(50.0, 1.0, "teste")
        degraded = deg.degrade(trace, level, rng)

        reference = deg.downsample(trace, 50.0)
        residual = degraded.x - reference.x
        assert np.std(residual) == pytest.approx(1.0, rel=0.15)


class TestWebcamGrid:
    def test_starts_from_the_undegraded_signal(self):
        first = deg.webcam_grid()[0]
        assert first.sampling_rate_hz is None
        assert first.noise_sigma_deg == 0.0

    def test_degradation_increases_monotonically(self):
        # A curva precisa percorrer níveis cada vez piores; uma grade fora de
        # ordem tornaria o gráfico ilegível e a comparação com a literatura
        # impossível.
        grid = deg.webcam_grid()
        rates = [level.sampling_rate_hz or np.inf for level in grid]
        noises = [level.noise_sigma_deg for level in grid]

        severity = list(zip((-np.array(rates)).tolist(), noises, strict=True))
        assert severity == sorted(severity)

    def test_covers_the_reported_webcam_error_range(self):
        # Valliappan et al. (2020) relatam de 0,6 a 1,0 grau de erro para
        # rastreamento por câmera comum após calibração individual.
        noises = {level.noise_sigma_deg for level in deg.webcam_grid()}
        assert 0.6 in noises
        assert 1.0 in noises

    def test_labels_are_unique(self):
        labels = [level.label for level in deg.webcam_grid()]
        assert len(set(labels)) == len(labels)
