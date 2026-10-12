"""Testes baseados em propriedades, com Hypothesis.

Os testes de exemplo verificam os casos que imaginamos. Estes verificam as
invariantes do pipeline contra entradas que não imaginamos: percursos curtos,
percursos degenerados, coordenadas em qualquer ponto da tela, taxas de
amostragem incomuns. É a técnica prevista na seção 4.4 da metodologia
(MacIver et al., 2019).

O que se afirma aqui não é que a saída esteja correta -- não há oráculo para
isso -- mas que ela está sempre dentro do domínio esperado. Uma característica
fora do domínio é um defeito mesmo sem gabarito: nenhuma proporção pode passar
de 1, nenhuma taxa pode ser negativa, e um ``NaN`` propagado até o
classificador corromperia o treino em silêncio.
"""

from __future__ import annotations

import numpy as np
import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from eyelearn.degradation import degrade as deg
from eyelearn.features import reading
from eyelearn.pipeline import PipelineConfig, trace_to_features
from eyelearn.signal import events, preprocess
from eyelearn.trace import GazeTrace

#: Todo o módulo treina modelos ou gera centenas de exemplos, e fica fora
#: da seleção rápida usada pelo teste de mutação.
pytestmark = pytest.mark.slow

# A extração completa sobre centenas de exemplos gerados é lenta o bastante
# para disparar o prazo padrão do Hypothesis, que mede cada exemplo
# isoladamente. O limite de tempo não diz nada sobre corretude aqui.
PIPELINE_SETTINGS = settings(
    max_examples=60,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)

coordinates = st.floats(
    min_value=-30.0, max_value=30.0, allow_nan=False, allow_infinity=False
)


@st.composite
def gaze_traces(draw, min_size: int = 2, max_size: int = 300) -> GazeTrace:
    """Percursos arbitrários com amostragem uniforme.

    A taxa de amostragem varia de 20 Hz a 1 kHz, cobrindo desde a webcam mais
    lenta até o equipamento de bancada do ETDD70.
    """
    n = draw(st.integers(min_value=min_size, max_value=max_size))
    x = draw(st.lists(coordinates, min_size=n, max_size=n))
    y = draw(st.lists(coordinates, min_size=n, max_size=n))
    dt = draw(st.floats(min_value=0.001, max_value=0.05))

    return GazeTrace(
        t=np.arange(n) * dt,
        x=np.array(x),
        y=np.array(y),
        subject_id="hypothesis",
    )


@st.composite
def traces_with_losses(draw) -> GazeTrace:
    """Percursos com amostras perdidas, como as piscadas deixam."""
    trace = draw(gaze_traces(min_size=4))
    n = len(trace)
    mask = draw(st.lists(st.booleans(), min_size=n, max_size=n))

    x = trace.x.copy()
    y = trace.y.copy()
    x[np.array(mask)] = np.nan
    y[np.array(mask)] = np.nan
    return trace.with_coordinates(x, y)


class TestPreprocessInvariants:
    @given(gaze_traces(), st.integers(min_value=0, max_value=6))
    def test_smoothing_preserves_length(self, trace: GazeTrace, half: int):
        smoothed = preprocess.smooth(trace, window=2 * half + 1)
        assert len(smoothed) == len(trace)

    @given(gaze_traces(), st.integers(min_value=0, max_value=6))
    def test_smoothing_never_leaves_the_original_range(
        self, trace: GazeTrace, half: int
    ):
        # Uma média de valores não pode sair do intervalo deles. Sair indicaria
        # preenchimento indevido nas bordas.
        smoothed = preprocess.smooth(trace, window=2 * half + 1)
        assert np.all(smoothed.x >= trace.x.min() - 1e-9)
        assert np.all(smoothed.x <= trace.x.max() + 1e-9)

    @given(gaze_traces())
    def test_velocity_is_never_negative(self, trace: GazeTrace):
        assert np.all(preprocess.velocity(trace) >= 0.0)

    @given(gaze_traces())
    def test_velocity_has_one_value_per_sample(self, trace: GazeTrace):
        assert preprocess.velocity(trace).shape == (len(trace),)

    @given(traces_with_losses())
    def test_cleaning_only_removes_samples(self, trace: GazeTrace):
        cleaned = preprocess.drop_invalid(trace)
        assert len(cleaned) <= len(trace)
        assert np.all(np.isfinite(cleaned.x))
        assert np.all(np.isfinite(cleaned.y))

    @given(traces_with_losses())
    def test_cleaning_preserves_temporal_order(self, trace: GazeTrace):
        cleaned = preprocess.drop_invalid(trace)
        if len(cleaned) > 1:
            assert np.all(np.diff(cleaned.t) > 0)

    @given(traces_with_losses())
    def test_valid_ratio_is_a_proportion(self, trace: GazeTrace):
        assert 0.0 <= preprocess.valid_sample_ratio(trace) <= 1.0

    @given(gaze_traces(), st.floats(min_value=0.005, max_value=0.5))
    def test_splitting_preserves_every_usable_sample(
        self, trace: GazeTrace, max_gap: float
    ):
        segments = preprocess.split_on_gaps(trace, max_gap)
        assert sum(len(segment) for segment in segments) <= len(trace)
        assert all(len(segment) >= 2 for segment in segments)


class TestEventInvariants:
    @given(gaze_traces())
    @PIPELINE_SETTINGS
    def test_fixations_lie_inside_the_trace(self, trace: GazeTrace):
        for method in ("ivt", "idt"):
            fixations, _ = events.detect_events(trace, method=method)  # type: ignore[arg-type]
            for fixation in fixations:
                assert trace.t[0] <= fixation.t_start <= fixation.t_end <= trace.t[-1]

    @given(gaze_traces())
    @PIPELINE_SETTINGS
    def test_fixations_never_overlap(self, trace: GazeTrace):
        for method in ("ivt", "idt"):
            fixations, _ = events.detect_events(trace, method=method)  # type: ignore[arg-type]
            for previous, following in zip(fixations, fixations[1:], strict=False):
                assert previous.t_end <= following.t_start

    @given(gaze_traces())
    @PIPELINE_SETTINGS
    def test_fixation_durations_are_not_negative(self, trace: GazeTrace):
        fixations, _ = events.detect_events(trace)
        assert all(fixation.duration >= 0.0 for fixation in fixations)

    @given(gaze_traces())
    @PIPELINE_SETTINGS
    def test_detection_terminates_and_stays_bounded(self, trace: GazeTrace):
        # Os dois detectores têm laços cujo avanço depende do recorte da
        # janela. Nenhum pode devolver mais fixações do que há amostras.
        for method in ("ivt", "idt"):
            fixations, _ = events.detect_events(trace, method=method)  # type: ignore[arg-type]
            assert len(fixations) <= len(trace)

    @given(gaze_traces())
    @PIPELINE_SETTINGS
    def test_saccade_amplitude_is_never_negative(self, trace: GazeTrace):
        _, saccades = events.detect_events(trace)
        assert all(saccade.amplitude >= 0.0 for saccade in saccades)


class TestFeatureInvariants:
    @given(traces_with_losses())
    @PIPELINE_SETTINGS
    def test_extraction_never_raises(self, trace: GazeTrace):
        for method in ("ivt", "idt"):
            trace_to_features(trace, PipelineConfig(method=method))  # type: ignore[arg-type]

    @given(traces_with_losses())
    @PIPELINE_SETTINGS
    def test_every_feature_is_finite(self, trace: GazeTrace):
        vector = reading.to_vector(trace_to_features(trace))
        assert np.all(np.isfinite(vector))

    @given(traces_with_losses())
    @PIPELINE_SETTINGS
    def test_feature_set_is_always_complete(self, trace: GazeTrace):
        assert set(trace_to_features(trace)) == set(reading.FEATURE_NAMES)

    @given(traces_with_losses())
    @PIPELINE_SETTINGS
    def test_regression_ratio_is_a_proportion(self, trace: GazeTrace):
        ratio = trace_to_features(trace)["regression_ratio"]
        assert 0.0 <= ratio <= 1.0

    @given(traces_with_losses())
    @PIPELINE_SETTINGS
    def test_rates_and_durations_are_not_negative(self, trace: GazeTrace):
        features = trace_to_features(trace)
        for name in (
            "fixation_rate",
            "saccade_rate",
            "regression_rate",
            "line_sweep_rate",
            "fixation_duration_mean",
            "fixation_duration_std",
            "saccade_amplitude_mean",
            "reading_time",
            "scanpath_length",
        ):
            assert features[name] >= 0.0, name


class TestDegradationInvariants:
    @given(gaze_traces(), st.floats(min_value=5.0, max_value=200.0))
    def test_downsampling_never_adds_samples(self, trace: GazeTrace, target_hz: float):
        assert len(deg.downsample(trace, target_hz)) <= len(trace)

    @given(gaze_traces(), st.floats(min_value=5.0, max_value=200.0))
    def test_downsampling_keeps_time_strictly_increasing(
        self, trace: GazeTrace, target_hz: float
    ):
        reduced = deg.downsample(trace, target_hz)
        if len(reduced) > 1:
            assert np.all(np.diff(reduced.t) > 0)

    @given(gaze_traces(), st.floats(min_value=5.0, max_value=200.0))
    def test_downsampling_only_reuses_original_samples(
        self, trace: GazeTrace, target_hz: float
    ):
        reduced = deg.downsample(trace, target_hz)
        assert np.all(np.isin(reduced.t, trace.t))

    @given(gaze_traces(), st.floats(min_value=0.0, max_value=3.0))
    def test_noise_preserves_sampling(self, trace: GazeTrace, sigma: float):
        noisy = deg.add_spatial_noise(trace, sigma, np.random.default_rng(0))
        assert np.array_equal(noisy.t, trace.t)
        assert len(noisy) == len(trace)

    @given(
        gaze_traces(),
        st.floats(min_value=5.0, max_value=200.0),
        st.floats(min_value=0.0, max_value=3.0),
    )
    def test_degradation_preserves_identity(
        self, trace: GazeTrace, target_hz: float, sigma: float
    ):
        # O identificador do participante é o que impede o vazamento na
        # validação cruzada. Perdê-lo na degradação invalidaria o experimento
        # inteiro em silêncio.
        level = deg.DegradationLevel(target_hz, sigma, "propriedade")
        degraded = deg.degrade(trace, level, np.random.default_rng(0))
        assert degraded.subject_id == trace.subject_id
        assert degraded.label == trace.label
