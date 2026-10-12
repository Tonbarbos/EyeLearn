"""Testes metamórficos.

Técnica proposta por Chen, Cheung e Yiu (1998) justamente para casos sem
oráculo, e aplicada a classificadores de aprendizado de máquina por Xie et al.
(2011). Em vez de conferir a saída isolada -- que ninguém sabe qual deveria ser
-- verifica-se uma relação conhecida entre a saída de uma entrada e a de uma
entrada transformada.

**Correção em relação à seção 4.4 da metodologia.** O documento enuncia como
relação metamórfica que "espelhar o percurso na horizontal não deve mudar a
classe prevista". Essa relação é falsa para este pipeline, e não por defeito:
o sentido da leitura é informação, não convenção arbitrária. Espelhar o eixo
horizontal troca sacadas progressivas por regressivas, e a proporção de
regressões é uma das características mais discriminantes do conjunto. Medido
neste repositório, o espelhamento leva a proporção de regressões de 0,14 para
0,81 -- a transformação não preserva a classe, ela a destrói.

O espelhamento continua sendo uma relação metamórfica útil, mas como
**inversão** e não como invariância: é o que
:class:`TestHorizontalMirror` verifica. As invariâncias legítimas do pipeline
são a translação espacial, a origem do tempo e o reescalamento conjunto de
coordenadas e limiares.
"""

from __future__ import annotations

import numpy as np
import pytest

from eyelearn.degradation.degrade import add_spatial_noise
from eyelearn.features import reading
from eyelearn.models.train import build_models
from eyelearn.pipeline import PipelineConfig, build_dataset, trace_to_features
from eyelearn.signal import events
from eyelearn.synthetic import reading_trace
from eyelearn.trace import GazeTrace


@pytest.fixture
def trace() -> GazeTrace:
    result, _ = reading_trace(n_lines=3, fixations_per_line=8, n_regressions=4)
    return result


@pytest.fixture(scope="module")
def fitted_model(cohort):
    """Floresta aleatória ajustada à coorte sintética inteira.

    Serve às relações que falam de predição. O ajuste é feito uma vez por
    módulo: as relações metamórficas comparam predições do *mesmo* modelo sobre
    entradas transformadas, e reajustá-lo a cada caso introduziria uma variação
    que não vem da transformação.
    """
    X, y, _ = build_dataset(cohort)
    model = build_models()["random_forest"]
    model.fit(X, y)
    return model


@pytest.fixture
def single_line() -> GazeTrace:
    """Percurso de uma linha, sem retorno de linha.

    Com várias linhas, o espelhamento transforma os retornos de linha em
    sacadas progressivas e a contagem deixa de fechar exatamente. Em uma linha
    só, a troca entre progressivas e regressivas é exata.
    """
    result, _ = reading_trace(n_lines=1, fixations_per_line=10, n_regressions=3)
    return result


class TestSpatialTranslation:
    """Deslocar o percurso inteiro não muda nenhuma característica.

    Toda característica do conjunto é relativa: durações, amplitudes, sentidos
    e proporções. Uma que mudasse com a translação estaria medindo a posição do
    estímulo na tela, não o comportamento do leitor -- e variaria conforme a
    calibração de cada criança.
    """

    @pytest.mark.parametrize(
        ("dx", "dy"),
        [(7.5, 0.0), (0.0, -3.25), (-12.0, 4.5), (0.5, 0.5)],
    )
    def test_features_are_unchanged(self, trace: GazeTrace, dx: float, dy: float):
        original = trace_to_features(trace)
        shifted = trace_to_features(trace.with_coordinates(trace.x + dx, trace.y + dy))

        for name in reading.FEATURE_NAMES:
            assert shifted[name] == pytest.approx(original[name], abs=1e-9), name

    def test_holds_for_both_detectors(self, trace: GazeTrace):
        for method in ("ivt", "idt"):
            config = PipelineConfig(method=method)  # type: ignore[arg-type]
            original = reading.to_vector(trace_to_features(trace, config))
            shifted = reading.to_vector(
                trace_to_features(trace.with_coordinates(trace.x + 9.0, trace.y - 2.0), config)
            )
            assert np.allclose(original, shifted, atol=1e-9)


class TestTimeOrigin:
    """A origem do eixo do tempo não muda nenhuma característica.

    O instante em que a gravação começou é um detalhe do aparato. Uma
    característica sensível a ele dependeria de quando a sessão foi iniciada.
    """

    @pytest.mark.parametrize("offset", [1.0, 60.0, 3600.0])
    def test_features_are_unchanged(self, trace: GazeTrace, offset: float):
        shifted = GazeTrace(
            t=trace.t + offset,
            x=trace.x,
            y=trace.y,
            subject_id=trace.subject_id,
            task=trace.task,
            label=trace.label,
        )
        original = trace_to_features(trace)
        moved = trace_to_features(shifted)

        for name in reading.FEATURE_NAMES:
            assert moved[name] == pytest.approx(original[name], rel=1e-6), name


class TestUniformScaling:
    """Reescalar coordenadas e limiares juntos preserva a estrutura detectada.

    Equivale a sentar a criança mais perto ou mais longe da tela: o padrão de
    leitura é o mesmo, medido em outra escala angular. As contagens e durações
    têm de sobreviver; as amplitudes acompanham a escala.
    """

    @pytest.mark.parametrize("factor", [0.5, 2.0, 3.0])
    def test_fixation_count_is_preserved(self, trace: GazeTrace, factor: float):
        scaled = trace.with_coordinates(trace.x * factor, trace.y * factor)

        original = events.ivt(trace)
        rescaled = events.ivt(
            scaled, velocity_threshold=events.VELOCITY_THRESHOLD * factor
        )
        assert len(rescaled) == len(original)

    @pytest.mark.parametrize("factor", [0.5, 2.0])
    def test_amplitudes_follow_the_scale(self, trace: GazeTrace, factor: float):
        scaled = trace.with_coordinates(trace.x * factor, trace.y * factor)

        base = events.saccades_between(trace, events.ivt(trace))
        grown = events.saccades_between(
            scaled,
            events.ivt(scaled, velocity_threshold=events.VELOCITY_THRESHOLD * factor),
        )
        assert np.mean([s.amplitude for s in grown]) == pytest.approx(
            np.mean([s.amplitude for s in base]) * factor, rel=1e-6
        )


class TestHorizontalMirror:
    """Espelhar o eixo horizontal inverte o sentido das sacadas.

    Não é uma invariância -- ver a correção no topo deste módulo -- e sim uma
    inversão exata. Verificá-la é mais forte do que verificar invariância:
    confirma que a classificação de sentido realmente lê o sinal do
    deslocamento, e não apenas que ela ignora alguma coisa.
    """

    def test_progressive_and_regressive_counts_swap(self, single_line: GazeTrace):
        mirrored = single_line.with_coordinates(-single_line.x, single_line.y)

        original = events.saccades_between(single_line, events.ivt(single_line))
        reflected = events.saccades_between(mirrored, events.ivt(mirrored))

        original_kinds = [s.kind for s in original]
        reflected_kinds = [s.kind for s in reflected]

        assert reflected_kinds.count("regressive") == original_kinds.count("progressive")
        assert reflected_kinds.count("progressive") == original_kinds.count("regressive")

    def test_direction_independent_features_survive(self, single_line: GazeTrace):
        # As características que não leem o sentido têm de atravessar o
        # espelhamento intactas. Se uma delas mudar, ela está lendo o sentido
        # sem que o nome diga isso.
        mirrored = single_line.with_coordinates(-single_line.x, single_line.y)
        original = trace_to_features(single_line)
        reflected = trace_to_features(mirrored)

        for name in (
            "fixation_rate",
            "fixation_duration_mean",
            "fixation_duration_std",
            "saccade_rate",
            "saccade_amplitude_mean",
            "reading_time",
            "scanpath_length",
        ):
            assert reflected[name] == pytest.approx(original[name], rel=1e-6), name

    def test_regression_ratio_actually_changes(self, trace: GazeTrace):
        # O contraexemplo que invalida a relação enunciada na seção 4.4.
        mirrored = trace.with_coordinates(-trace.x, trace.y)
        assert trace_to_features(mirrored)["regression_ratio"] > (
            trace_to_features(trace)["regression_ratio"] + 0.3
        )


class TestNoiseRobustness:
    """Ruído pequeno não deve virar a predição.

    Esta é a segunda relação enunciada na seção 4.4, e se sustenta. Um
    classificador que mudasse de classe com 0,1 grau de ruído estaria lendo o
    ruído, e não o padrão de leitura -- e seria inútil em webcam, onde o erro
    de estimativa é da ordem de 0,6 a 1 grau.

    A relação é probabilística: afirma-se um limite para a taxa de inversões,
    não a ausência delas.
    """

    @pytest.mark.parametrize("sigma", [0.05, 0.1])
    def test_small_noise_rarely_flips_the_prediction(
        self, fitted_model, cohort, sigma: float
    ):
        rng = np.random.default_rng(3)
        noisy = [add_spatial_noise(trace, sigma, rng) for trace in cohort]

        X_clean, _, _ = build_dataset(cohort)
        X_noisy, _, _ = build_dataset(noisy)

        flips = np.mean(fitted_model.predict(X_clean) != fitted_model.predict(X_noisy))
        assert flips <= 0.15

    def test_identical_input_gives_identical_output(self, fitted_model, cohort):
        # Determinismo: duas execuções sobre o mesmo percurso têm de coincidir.
        # Sem isso, nenhuma das relações acima seria verificável.
        X, _, _ = build_dataset(cohort)
        assert np.array_equal(fitted_model.predict(X), fitted_model.predict(X))


class TestRegressionMonotonicity:
    """Mais regressões não devem reduzir a evidência de dificuldade.

    Relação sobre o pipeline inteiro, da geração do percurso à característica.
    Ancorada na direção que a literatura de leitura descreve: regressões mais
    frequentes acompanham leitura menos fluente. Uma inversão aqui indicaria
    que a cadeia perdeu o sinal em algum ponto entre o sinal e a característica.
    """

    def test_regression_ratio_increases_with_inserted_regressions(self):
        ratios = []
        for n_regressions in (0, 2, 4, 6, 8):
            trace, _ = reading_trace(
                n_lines=3, fixations_per_line=8, n_regressions=n_regressions
            )
            ratios.append(trace_to_features(trace)["regression_ratio"])

        assert ratios == sorted(ratios)
        assert ratios[-1] > ratios[0]

    def test_longer_fixations_raise_the_mean_duration(self):
        durations = []
        for fixation_duration in (0.18, 0.24, 0.30, 0.36):
            trace, _ = reading_trace(
                n_lines=3, fixations_per_line=8, fixation_duration=fixation_duration
            )
            durations.append(trace_to_features(trace)["fixation_duration_mean"])

        assert durations == sorted(durations)
