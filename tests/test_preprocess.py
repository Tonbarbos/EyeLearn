"""Testes do pré-processamento do sinal."""

from __future__ import annotations

import numpy as np
import pytest

from eyelearn.signal import preprocess
from eyelearn.trace import GazeTrace


def make_trace(x, y, dt: float = 0.004, **kwargs) -> GazeTrace:
    """Monta um percurso com amostragem uniforme a partir das coordenadas."""
    x = np.asarray(x, dtype=float)
    return GazeTrace(
        t=np.arange(x.size) * dt,
        x=x,
        y=np.asarray(y, dtype=float),
        subject_id=kwargs.pop("subject_id", "S01"),
        **kwargs,
    )


class TestGazeTrace:
    def test_rejects_mismatched_lengths(self):
        with pytest.raises(ValueError, match="mesmo tamanho"):
            GazeTrace(t=np.arange(3.0), x=np.zeros(2), y=np.zeros(3), subject_id="S01")

    def test_rejects_non_increasing_time(self):
        with pytest.raises(ValueError, match="estritamente crescente"):
            GazeTrace(
                t=np.array([0.0, 0.2, 0.1]),
                x=np.zeros(3),
                y=np.zeros(3),
                subject_id="S01",
            )

    def test_rejects_unknown_label(self):
        with pytest.raises(ValueError, match="label inválido"):
            GazeTrace(
                t=np.arange(3.0), x=np.zeros(3), y=np.zeros(3), subject_id="S01", label=7
            )

    def test_sampling_rate_uses_median_not_mean(self):
        # Um buraco de 0,5 s em meio a amostras de 250 Hz: a média dos
        # intervalos diria 100 Hz, a mediana mantém 250 Hz.
        t = np.array([0.0, 0.004, 0.008, 0.508, 0.512])
        trace = GazeTrace(t=t, x=np.zeros(5), y=np.zeros(5), subject_id="S01")
        assert trace.sampling_rate == pytest.approx(250.0)

    def test_empty_trace_has_no_duration_or_rate(self):
        trace = GazeTrace(t=np.array([]), x=np.array([]), y=np.array([]), subject_id="S01")
        assert len(trace) == 0
        assert trace.duration == 0.0
        assert trace.sampling_rate == 0.0


class TestPixelsToDegrees:
    def test_screen_centre_maps_to_origin(self):
        x_deg, y_deg = preprocess.pixels_to_degrees(
            np.array([960.0]), np.array([540.0]), 1920, 1080, 53.1, 60.0
        )
        assert x_deg[0] == pytest.approx(0.0)
        assert y_deg[0] == pytest.approx(0.0)

    def test_horizontal_extent_matches_geometry(self):
        # Metade da largura física a 60 cm: arctan(26,55/60) ≈ 23,87°.
        x_deg, _ = preprocess.pixels_to_degrees(
            np.array([1920.0]), np.array([540.0]), 1920, 1080, 53.1, 60.0
        )
        assert x_deg[0] == pytest.approx(np.degrees(np.arctan2(26.55, 60.0)), abs=1e-9)

    def test_rejects_invalid_geometry(self):
        with pytest.raises(ValueError, match="distância de visualização"):
            preprocess.pixels_to_degrees(
                np.array([0.0]), np.array([0.0]), 1920, 1080, 53.1, 0.0
            )


class TestDropInvalid:
    def test_removes_non_finite_samples(self):
        trace = make_trace([0.0, np.nan, 1.0, np.inf], [0.0, 0.0, 0.0, 0.0])
        cleaned = preprocess.drop_invalid(trace)
        assert len(cleaned) == 2
        assert np.all(np.isfinite(cleaned.x))

    def test_removes_samples_outside_stimulus_area(self):
        trace = make_trace([0.0, 50.0, 1.0], [0.0, 0.0, 99.0])
        cleaned = preprocess.drop_invalid(trace, bounds_deg=(20.0, 15.0))
        assert len(cleaned) == 1
        assert cleaned.x[0] == pytest.approx(0.0)

    def test_preserves_time_gaps_left_by_removal(self):
        # O buraco tem de sobreviver ao descarte: é por ele que split_on_gaps
        # evita criar uma sacada onde não houve movimento rastreado.
        trace = make_trace([0.0, np.nan, np.nan, 1.0], [0.0, 0.0, 0.0, 0.0])
        cleaned = preprocess.drop_invalid(trace)
        assert cleaned.t[1] - cleaned.t[0] == pytest.approx(0.012)

    def test_keeps_metadata(self):
        trace = make_trace([0.0, np.nan], [0.0, 0.0], task="text", label=1)
        cleaned = preprocess.drop_invalid(trace)
        assert cleaned.subject_id == "S01"
        assert cleaned.task == "text"
        assert cleaned.label == 1


class TestValidSampleRatio:
    def test_counts_proportion_of_usable_samples(self):
        trace = make_trace([0.0, np.nan, 1.0, 2.0], [0.0] * 4)
        assert preprocess.valid_sample_ratio(trace) == pytest.approx(0.75)

    def test_empty_trace_is_fully_invalid(self):
        trace = GazeTrace(t=np.array([]), x=np.array([]), y=np.array([]), subject_id="S01")
        assert preprocess.valid_sample_ratio(trace) == 0.0


class TestSplitOnGaps:
    def test_splits_at_long_gap(self):
        t = np.array([0.0, 0.004, 0.008, 0.5, 0.504, 0.508])
        trace = GazeTrace(t=t, x=np.zeros(6), y=np.zeros(6), subject_id="S01")
        segments = preprocess.split_on_gaps(trace, max_gap=0.075)
        assert len(segments) == 2
        assert [len(s) for s in segments] == [3, 3]

    def test_tolerates_short_gap(self):
        t = np.array([0.0, 0.004, 0.05, 0.054])
        trace = GazeTrace(t=t, x=np.zeros(4), y=np.zeros(4), subject_id="S01")
        assert len(preprocess.split_on_gaps(trace, max_gap=0.075)) == 1

    def test_drops_segments_too_short_for_velocity(self):
        # O segmento do meio tem uma só amostra: não há como derivar velocidade.
        t = np.array([0.0, 0.004, 0.5, 1.0, 1.004])
        trace = GazeTrace(t=t, x=np.zeros(5), y=np.zeros(5), subject_id="S01")
        segments = preprocess.split_on_gaps(trace, max_gap=0.075)
        assert [len(s) for s in segments] == [2, 2]

    def test_rejects_non_positive_gap(self):
        trace = make_trace([0.0, 1.0], [0.0, 0.0])
        with pytest.raises(ValueError, match="max_gap"):
            preprocess.split_on_gaps(trace, max_gap=0.0)


class TestSmooth:
    def test_rejects_even_window(self):
        trace = make_trace([0.0, 1.0, 2.0], [0.0, 0.0, 0.0])
        with pytest.raises(ValueError, match="ímpar"):
            preprocess.smooth(trace, window=4)

    def test_unit_window_is_identity(self):
        trace = make_trace([0.0, 5.0, 1.0], [2.0, 2.0, 2.0])
        smoothed = preprocess.smooth(trace, window=1)
        assert np.array_equal(smoothed.x, trace.x)

    def test_removes_single_sample_spike(self):
        trace = make_trace([0.0, 0.0, 3.0, 0.0, 0.0], [0.0] * 5)
        smoothed = preprocess.smooth(trace, window=3)
        assert smoothed.x[2] == pytest.approx(1.0)

    def test_preserves_constant_signal_including_edges(self):
        # Com janela encurtada nas bordas, um sinal constante sai intacto;
        # preenchimento por zero rebaixaria as pontas.
        trace = make_trace(np.full(7, 4.0), np.full(7, -2.0))
        smoothed = preprocess.smooth(trace, window=5)
        assert np.allclose(smoothed.x, 4.0)
        assert np.allclose(smoothed.y, -2.0)

    def test_does_not_shift_signal_in_time(self):
        # Média móvel centrada preserva a posição do centro de massa de uma
        # rampa; uma janela deslocada moveria o pico.
        trace = make_trace(np.arange(11.0), np.zeros(11))
        smoothed = preprocess.smooth(trace, window=5)
        assert smoothed.x[5] == pytest.approx(5.0)


class TestVelocity:
    def test_constant_speed_motion(self):
        # 0,4 graus por amostra a 250 Hz equivale a 100 graus por segundo.
        trace = make_trace(np.arange(10) * 0.4, np.zeros(10))
        v = preprocess.velocity(trace)
        assert np.allclose(v, 100.0)

    def test_stationary_signal_has_zero_velocity(self):
        trace = make_trace(np.full(10, 3.0), np.full(10, 3.0))
        assert np.allclose(preprocess.velocity(trace), 0.0)

    def test_combines_both_axes(self):
        # 3 e 4 graus por segundo em cada eixo dão 5 na composição.
        trace = make_trace(np.arange(5) * 0.012, np.arange(5) * 0.016, dt=1.0)
        v = preprocess.velocity(trace)
        assert np.allclose(v, 0.02)

    def test_short_trace_has_no_velocity(self):
        trace = make_trace([1.0], [1.0])
        assert preprocess.velocity(trace).shape == (1,)
        assert np.all(preprocess.velocity(trace) == 0.0)
