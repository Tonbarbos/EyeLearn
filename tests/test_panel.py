"""Testes do painel do professor.

Só a parte que não é widget: o gráfico é construído sobre uma figura do
matplotlib, que se verifica sem abrir janela e sem servidor gráfico. A montagem
dos widgets fica de fora -- exercitá-la exigiria Qt e um display, e o que ela
faz é posicionar o que estes testes já cobrem.

A afirmação que mais importa aqui não é visual: **o painel descreve, não
diagnostica.** Os testes abaixo tratam disso como requisito verificável, não
como intenção.
"""

from __future__ import annotations

import matplotlib

# Backend sem janela: o teste roda na integração contínua, onde não há display.
matplotlib.use("Agg")

import pytest  # noqa: E402
from matplotlib.figure import Figure  # noqa: E402

from eyelearn.features.reading import FEATURE_NAMES  # noqa: E402
from eyelearn.panel import theme  # noqa: E402
from eyelearn.panel.charts import (  # noqa: E402
    HIGHLIGHT_THRESHOLD,
    PRESENTED_FEATURES,
    describe_direction,
    z_score_figure,
)
from eyelearn.session import compare_within_class, session_from_dict  # noqa: E402
from tests.test_session import make_payload  # noqa: E402


def build_class(durations: list[float], task: str = "text"):
    """Turma sintética em que toda característica apresentada varia.

    Variar só uma deixaria as outras cinco com desvio zero na turma, barra de
    comprimento nulo e teste que não verifica nada -- foi o que a primeira
    versão deste arquivo fazia.
    """
    return [
        session_from_dict(
            make_payload(
                code=f"A{index:02d}",
                task=task,
                overrides={
                    "fixation_duration_mean": duration,
                    "fixation_rate": 3.0 + index * 0.21,
                    "regression_ratio": 0.08 + index * 0.035,
                    "saccade_amplitude_mean": 2.6 - index * 0.14,
                    "line_sweep_rate": 0.18 + index * 0.012,
                    "reading_time": 28.0 + index * 1.7,
                },
            )
        )
        for index, duration in enumerate(durations)
    ]


@pytest.fixture
def comparison():
    # A05 é o destoante: bem acima do resto da turma.
    return compare_within_class(
        build_class([0.20, 0.21, 0.22, 0.23, 0.24, 0.52]), "text"
    )


class TestPresentedFeatures:
    def test_every_presented_feature_exists(self):
        # Um nome errado aqui não quebraria nada: a característica sumiria do
        # gráfico em silêncio, e o professor veria menos do que deveria.
        for name, _ in PRESENTED_FEATURES:
            assert name in FEATURE_NAMES, name

    def test_labels_are_in_plain_language(self):
        # O professor não lê "regression_ratio". O rótulo é o que ele vê.
        for name, label in PRESENTED_FEATURES:
            assert label != name
            assert "_" not in label, label

    def test_presents_fewer_features_than_the_model_uses(self):
        # O modelo usa catorze; o painel mostra as que têm leitura pedagógica.
        # As demais descrevem o sinal e encheriam o gráfico sem informar.
        assert len(PRESENTED_FEATURES) < len(FEATURE_NAMES)

    def test_labels_are_unique(self):
        labels = [label for _, label in PRESENTED_FEATURES]
        assert len(set(labels)) == len(labels)


class TestZScoreFigure:
    def test_draws_one_bar_per_presented_feature(self, comparison):
        figure = z_score_figure(comparison, "A05")
        axes = figure.axes[0]
        # As barras são patches arredondados; as linhas de referência e o zero
        # entram como linhas, não como patches.
        assert len(axes.patches) == len(PRESENTED_FEATURES)

    def test_labels_every_axis_entry(self, comparison):
        figure = z_score_figure(comparison, "A05")
        drawn = [t.get_text() for t in figure.axes[0].get_yticklabels()]
        assert drawn == [label for _, label in PRESENTED_FEATURES]

    def test_axis_is_centred_on_zero(self, comparison):
        # A grandeza tem polaridade: um eixo deslocado faria "acima" e
        # "abaixo" parecerem assimétricos quando não são.
        low, high = z_score_figure(comparison, "A05").axes[0].get_xlim()
        assert low == pytest.approx(-high)

    def test_reuses_the_figure_it_is_given(self, comparison):
        # O painel redesenha na mesma figura a cada troca de aluno; criar uma
        # nova deixaria telas do Qt para trás.
        figure = Figure()
        assert z_score_figure(comparison, "A05", figure=figure) is figure

    def test_redrawing_does_not_accumulate_bars(self, comparison):
        figure = Figure()
        z_score_figure(comparison, "A05", figure=figure)
        z_score_figure(comparison, "A01", figure=figure)
        assert len(figure.axes[0].patches) == len(PRESENTED_FEATURES)

    def test_unknown_participant_is_reported(self, comparison):
        with pytest.raises(KeyError, match="A99"):
            z_score_figure(comparison, "A99")

    def test_outliers_get_an_outline(self, comparison):
        # Destaque que sobrevive ao daltonismo e à impressão em preto: quem
        # passa do limiar ganha contorno, não só outra cor.
        figure = z_score_figure(comparison, "A05")
        outlined = [
            patch
            for patch in figure.axes[0].patches
            if patch.get_linewidth() > 0
        ]
        assert outlined, "o destoante não recebeu contorno"

    def test_typical_participant_has_no_outline(self, comparison):
        figure = z_score_figure(comparison, "A02")
        assert all(
            patch.get_linewidth() == 0 for patch in figure.axes[0].patches
        )

    def test_renders_to_an_image(self, comparison, tmp_path):
        # Verifica o caminho inteiro de desenho, que é onde um valor infinito
        # ou um limite degenerado apareceria.
        path = tmp_path / "grafico.png"
        z_score_figure(comparison, "A05").savefig(path)
        assert path.stat().st_size > 5000


class TestColourChoices:
    def test_above_and_below_use_different_hues(self):
        assert theme.ABOVE_CLASS != theme.BELOW_CLASS

    @staticmethod
    def hue(colour: str) -> float:
        """Matiz em graus. Vermelho é 0, verde fica em torno de 120 a 160."""
        import colorsys

        red, green, blue = (
            int(colour[index : index + 2], 16) / 255 for index in (1, 3, 5)
        )
        return colorsys.rgb_to_hsv(red, green, blue)[0] * 360

    def test_neither_pole_is_red_or_green(self):
        # Verde e vermelho transformariam o painel num semáforo diagnóstico.
        # Estar acima da turma em duração de fixação é uma observação, não um
        # defeito, e a cor não pode dizer o contrário.
        #
        # A verificação é por matiz, não por comparação crua de componentes:
        # o âmbar do painel tem vermelho alto e seria reprovado por engano.
        for colour in (theme.ABOVE_CLASS, theme.BELOW_CLASS):
            angle = self.hue(colour)
            distance_to_red = min(angle, 360 - angle)
            assert distance_to_red > 25, f"{colour} está perto do vermelho"
            assert not 95 < angle < 175, f"{colour} está no verde"

    def test_the_chart_pair_is_not_the_status_palette(self):
        # As cores de estado (verde de bom, coral de erro) ficam reservadas
        # para qualidade de captura, e nunca viram série do gráfico.
        assert theme.ABOVE_CLASS not in (theme.GREEN, theme.CORAL)
        assert theme.BELOW_CLASS not in (theme.GREEN, theme.CORAL)


class TestDescribeDirection:
    def test_describes_without_judging(self):
        # A diferença entre descrever e julgar é o que separa este painel de
        # um instrumento diagnóstico.
        phrases = [
            describe_direction(value) for value in (-3.0, -0.2, 0.0, 0.4, 3.0)
        ]
        for phrase in phrases:
            lowered = phrase.lower()
            for word in ("ruim", "pior", "risco", "alerta", "grave", "déficit"):
                assert word not in lowered, phrase

    def test_names_the_side_of_the_class(self):
        assert "acima" in describe_direction(HIGHLIGHT_THRESHOLD + 0.1)
        assert "abaixo" in describe_direction(-HIGHLIGHT_THRESHOLD - 0.1)

    def test_within_the_class_is_not_called_out(self):
        assert describe_direction(0.0) == "dentro da turma"
        assert describe_direction(HIGHLIGHT_THRESHOLD - 0.01) == "dentro da turma"

    def test_threshold_matches_the_comparison_default(self):
        # O gráfico e a lista de destacados têm de concordar sobre quem está
        # fora da faixa, ou o professor veria uma criança marcada na lista e
        # sem contorno nenhum no gráfico.
        from eyelearn.session import compare_within_class as _compare

        sessions = build_class([0.20, 0.21, 0.22, 0.23, 0.24, 0.52])
        flagged = _compare(sessions, "text").outliers(HIGHLIGHT_THRESHOLD)
        assert "A05" in flagged
