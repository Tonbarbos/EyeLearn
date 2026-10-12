"""Testes da extração de características de leitura."""

from __future__ import annotations

import numpy as np
import pytest

from eyelearn.features import reading
from eyelearn.pipeline import PipelineConfig, trace_to_features
from eyelearn.signal import events, preprocess
from eyelearn.synthetic import reading_trace


def fixation(t_start: float, duration: float, x: float = 0.0, y: float = 0.0):
    return events.Fixation(
        t_start=t_start, t_end=t_start + duration, x=x, y=y, n_samples=10
    )


def saccade(dx: float, dy: float = 0.0, kind: str = "progressive"):
    return events.Saccade(
        t_start=0.0, t_end=0.03, dx=dx, dy=dy, peak_velocity=70.0, kind=kind  # type: ignore[arg-type]
    )


class TestEmptyInput:
    def test_all_features_are_zero_without_events(self):
        features = reading.extract([], [])
        assert set(features) == set(reading.FEATURE_NAMES)
        assert all(value == 0.0 for value in features.values())

    def test_no_feature_is_undefined(self):
        # NaN obrigaria o classificador a imputar, e o valor imputado diria
        # mais sobre a imputação do que sobre o leitor.
        vector = reading.to_vector(reading.extract([], []))
        assert np.all(np.isfinite(vector))


class TestFixationFeatures:
    def test_rate_is_per_second(self):
        fixations = [fixation(index * 1.0, 0.2) for index in range(5)]
        features = reading.extract(fixations, [], reading_time=10.0)
        assert features["fixation_rate"] == pytest.approx(0.5)

    def test_duration_statistics(self):
        fixations = [fixation(0.0, 0.1), fixation(1.0, 0.3), fixation(2.0, 0.2)]
        features = reading.extract(fixations, [], reading_time=3.0)
        assert features["fixation_duration_mean"] == pytest.approx(0.2)
        assert features["fixation_duration_median"] == pytest.approx(0.2)
        assert features["fixation_duration_std"] == pytest.approx(np.std([0.1, 0.3, 0.2]))

    def test_reading_time_inferred_from_fixation_span(self):
        features = reading.extract([fixation(1.0, 0.2), fixation(4.0, 0.3)], [])
        assert features["reading_time"] == pytest.approx(3.3)


class TestRegressionRatio:
    def test_zero_without_regressions(self):
        saccades = [saccade(2.0) for _ in range(4)]
        assert reading.extract([], saccades, 10.0)["regression_ratio"] == 0.0

    def test_measured_against_within_line_saccades_only(self):
        # Três progressivas, uma regressiva e um retorno de linha. O retorno
        # fica fora do denominador: ele é obrigatório em qualquer leitor e, no
        # denominador, diluiria a diferença entre os grupos.
        saccades = [
            saccade(2.0),
            saccade(2.0),
            saccade(-2.0, kind="regressive"),
            saccade(2.0),
            saccade(-14.0, 1.5, kind="line_sweep"),
        ]
        features = reading.extract([], saccades, 10.0)
        assert features["regression_ratio"] == pytest.approx(0.25)

    def test_sweeps_alone_leave_ratio_defined(self):
        saccades = [saccade(-14.0, 1.5, kind="line_sweep")]
        assert reading.extract([], saccades, 10.0)["regression_ratio"] == 0.0

    def test_rises_with_more_regressions(self):
        def ratio(n_regressions: int) -> float:
            trace, _ = reading_trace(
                n_lines=3, fixations_per_line=8, n_regressions=n_regressions
            )
            fixations, saccades = events.detect_events(trace)
            return reading.extract(fixations, saccades)["regression_ratio"]

        ratios = [ratio(n) for n in (0, 2, 4, 6)]
        assert ratios == sorted(ratios)
        assert ratios[0] == 0.0
        assert ratios[-1] > 0.0


class TestSaccadeFeatures:
    def test_amplitude_statistics_use_absolute_distance(self):
        saccades = [saccade(2.0), saccade(-2.0, kind="regressive")]
        features = reading.extract([], saccades, 10.0)
        assert features["saccade_amplitude_mean"] == pytest.approx(2.0)
        assert features["saccade_amplitude_std"] == pytest.approx(0.0)

    def test_progressive_amplitude_ignores_other_kinds(self):
        saccades = [
            saccade(2.0),
            saccade(4.0),
            saccade(-20.0, 1.5, kind="line_sweep"),
        ]
        features = reading.extract([], saccades, 10.0)
        assert features["progressive_amplitude_mean"] == pytest.approx(3.0)

    def test_scanpath_length_sums_all_amplitudes(self):
        saccades = [saccade(3.0), saccade(4.0), saccade(-5.0, kind="regressive")]
        assert reading.extract([], saccades, 10.0)["scanpath_length"] == pytest.approx(12.0)


class TestVectorisation:
    def test_vector_follows_canonical_order(self):
        features = {name: float(index) for index, name in enumerate(reading.FEATURE_NAMES)}
        assert np.array_equal(
            reading.to_vector(features), np.arange(len(reading.FEATURE_NAMES), dtype=float)
        )

    def test_missing_feature_is_reported(self):
        features = reading.extract([], [])
        del features["regression_ratio"]
        with pytest.raises(KeyError, match="regression_ratio"):
            reading.to_vector(features)

    def test_matrix_shape_matches_rows_and_features(self):
        rows = [reading.extract([], []) for _ in range(4)]
        assert reading.to_matrix(rows).shape == (4, len(reading.FEATURE_NAMES))

    def test_empty_matrix_keeps_feature_dimension(self):
        # Preserva a forma para que o código a jusante não precise tratar o
        # caso vazio de maneira especial.
        assert reading.to_matrix([]).shape == (0, len(reading.FEATURE_NAMES))

    def test_feature_names_have_no_duplicates(self):
        assert len(set(reading.FEATURE_NAMES)) == len(reading.FEATURE_NAMES)


class TestSmoothingWindow:
    """A janela de suavização é definida em tempo, não em amostras.

    Fixá-la em amostras fazia a duração efetiva da suavização variar com a taxa
    de amostragem -- 20 ms a 250 Hz, 167 ms a 30 Hz. Como 167 ms atravessam uma
    sacada inteira, o pré-processamento apagava as sacadas justamente nas taxas
    de webcam, que são o objeto do projeto.
    """

    @pytest.mark.parametrize(
        ("rate", "expected"),
        [(250.0, 5), (500.0, 9), (120.0, 3), (100.0, 1), (60.0, 1), (30.0, 1)],
    )
    def test_converts_milliseconds_to_an_odd_sample_count(
        self, rate: float, expected: int
    ):
        assert PipelineConfig(smoothing_ms=20.0).smoothing_window(rate) == expected

    def test_window_is_always_odd(self):
        # Janela par descentraria a média e deslocaria o sinal no tempo.
        config = PipelineConfig(smoothing_ms=20.0)
        for rate in (30.0, 60.0, 120.0, 250.0, 500.0, 1000.0):
            assert config.smoothing_window(rate) % 2 == 1

    def test_degenerate_rate_falls_back_to_identity(self):
        assert PipelineConfig().smoothing_window(0.0) == 1

    def test_smoothing_duration_is_stable_across_rates(self):
        # É a invariante que o defeito violava: onde há suavização, ela cobre
        # aproximadamente a mesma duração em qualquer taxa. Janela 1 é
        # ausência de suavização, não uma janela curta, e fica de fora.
        config = PipelineConfig(smoothing_ms=20.0)
        for rate in (120.0, 250.0, 500.0, 1000.0):
            window = config.smoothing_window(rate)
            assert window > 1, rate
            assert window / rate * 1000.0 == pytest.approx(20.0, abs=6.0), rate

    def test_webcam_rate_still_resolves_separate_fixations(self):
        # O teste de regressão do defeito: a 30 Hz o pipeline detectava uma
        # única fixação onde o percurso tem quatro, porque a suavização de
        # 167 ms tinha apagado as sacadas entre elas.
        #
        # A amplitude de 3 graus evita o limiar exato, documentado em
        # TestWebcamRateLimit: a 2 graus a velocidade da sacada dá exatamente
        # 30 graus por segundo e a detecção passa a depender do último bit.
        trace, spec = reading_trace(
            n_lines=1,
            fixations_per_line=4,
            sampling_rate=30.0,
            saccade_amplitude=3.0,
            jitter_deg=0.0,
        )
        fixations, _ = events.detect_events(
            preprocess.smooth(
                trace, PipelineConfig().smoothing_window(trace.sampling_rate)
            )
        )
        assert len(fixations) == spec.n_fixations


class TestWebcamRateLimit:
    """O limite físico do I-VT na taxa de uma câmera comum.

    A 30 Hz uma sacada de leitura ocupa uma amostra só. A velocidade que a
    diferença centrada atribui a essa amostra é a amplitude dividida por dois
    intervalos: 2 graus em 2/30 de segundo dão exatamente 30 graus por segundo,
    que é o limiar do I-VT. A detecção fica equilibrada na fronteira e passa a
    depender do último bit da aritmética.

    Não é defeito a corrigir, é a resolução do método na taxa disponível -- e é
    o tipo de limite que o experimento de degradação existe para medir. Está
    aqui para ficar registrado, e para que ninguém "conserte" o limiar sem
    saber o que está em jogo.
    """

    def test_two_degree_saccade_sits_exactly_on_the_threshold(self):
        trace, _ = reading_trace(
            n_lines=1,
            fixations_per_line=4,
            sampling_rate=30.0,
            saccade_amplitude=2.0,
            jitter_deg=0.0,
        )
        peak = preprocess.velocity(trace).max()
        assert peak == pytest.approx(events.VELOCITY_THRESHOLD, rel=1e-6)

    def test_larger_saccade_clears_the_threshold(self):
        trace, _ = reading_trace(
            n_lines=1,
            fixations_per_line=4,
            sampling_rate=30.0,
            saccade_amplitude=3.0,
            jitter_deg=0.0,
        )
        peak = preprocess.velocity(trace).max()
        assert peak > events.VELOCITY_THRESHOLD * 1.4

    def test_the_same_saccade_is_unambiguous_at_bench_rate(self):
        # A 250 Hz a mesma sacada de 2 graus ocupa várias amostras e a
        # velocidade sobe bem acima do limiar: o limite é da taxa, não da
        # amplitude.
        trace, _ = reading_trace(
            n_lines=1,
            fixations_per_line=4,
            sampling_rate=250.0,
            saccade_amplitude=2.0,
            jitter_deg=0.0,
        )
        assert preprocess.velocity(trace).max() > events.VELOCITY_THRESHOLD * 1.5


class TestPipelineIntegration:
    def test_features_separate_the_two_synthetic_profiles(self):
        # O grupo com mais regressões e fixações mais longas tem de aparecer
        # nas características, ou nenhum classificador a jusante funcionaria.
        typical, _ = reading_trace(
            n_lines=3, fixations_per_line=8, fixation_duration=0.22, n_regressions=1
        )
        atypical, _ = reading_trace(
            n_lines=3, fixations_per_line=8, fixation_duration=0.31, n_regressions=5
        )

        a = trace_to_features(typical)
        b = trace_to_features(atypical)

        assert b["regression_ratio"] > a["regression_ratio"]
        assert b["fixation_duration_mean"] > a["fixation_duration_mean"]

    def test_both_detectors_produce_the_full_feature_set(self):
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6, n_regressions=2)
        for method in ("ivt", "idt"):
            features = trace_to_features(trace, PipelineConfig(method=method))
            assert set(features) == set(reading.FEATURE_NAMES)
            assert np.all(np.isfinite(reading.to_vector(features)))

    def test_reading_time_survives_sample_loss(self):
        # O tempo de tarefa é medido antes do descarte: medi-lo depois
        # encurtaria a tarefa de quem perdeu mais amostras e distorceria todas
        # as taxas.
        trace, _ = reading_trace(n_lines=2, fixations_per_line=6)
        damaged = trace.with_coordinates(trace.x.copy(), trace.y.copy())
        damaged.x[100:200] = np.nan

        intact = trace_to_features(trace)
        lossy = trace_to_features(damaged)
        assert lossy["reading_time"] == pytest.approx(intact["reading_time"])
