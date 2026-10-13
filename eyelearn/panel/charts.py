"""Gráficos do painel do professor.

Separado dos widgets de propósito: aqui é só matplotlib sobre uma
:class:`~eyelearn.session.ClassComparison`, de modo que a figura possa ser
verificada sem abrir janela e sem servidor gráfico.
"""

from __future__ import annotations

from matplotlib.figure import Figure
from matplotlib.patches import FancyBboxPatch

from eyelearn.panel import theme
from eyelearn.session import ClassComparison

#: Características apresentadas ao professor, na ordem do gráfico.
#:
#: Não são todas as catorze que o modelo usa. O painel mostra as que têm
#: leitura pedagógica direta; as demais -- desvios, velocidade de pico,
#: comprimento do percurso -- descrevem o sinal, não o comportamento, e
#: enchariam o gráfico sem dizer nada ao professor.
PRESENTED_FEATURES: tuple[tuple[str, str], ...] = (
    ("fixation_duration_mean", "Tempo em cada palavra"),
    ("fixation_rate", "Paradas por segundo"),
    ("regression_ratio", "Voltas no texto"),
    ("saccade_amplitude_mean", "Tamanho dos saltos"),
    ("line_sweep_rate", "Trocas de linha"),
    ("reading_time", "Tempo total"),
)

#: A partir de quantos desvios a característica é destacada.
#:
#: O mesmo limiar de :meth:`ClassComparison.outliers`. Não é ponto de corte
#: diagnóstico: é o que destaca, numa turma de trinta, as poucas crianças que
#: valem uma observação mais atenta.
HIGHLIGHT_THRESHOLD = 1.5


def z_score_figure(
    comparison: ClassComparison,
    code: str,
    threshold: float = HIGHLIGHT_THRESHOLD,
    figure: Figure | None = None,
) -> Figure:
    """Barras horizontais dos escores z de um participante.

    A forma é barra a partir de uma linha de zero porque a grandeza tem
    polaridade: o que interessa é de que lado da turma a criança está, e
    quanto. Um gráfico de pizza ou de linha não responderia isso.

    A cor é divergente -- âmbar acima da turma, violeta abaixo, cinza no zero
    -- e deliberadamente **não** é verde e vermelho: estar acima da média em
    duração de fixação não é "ruim", é uma observação. Ver
    :data:`eyelearn.panel.theme.ABOVE_CLASS`.

    Cada barra leva o seu próprio valor como rótulo, e a leitura não depende da
    cor: o nome da característica fica de um lado, o número do outro.

    Args:
        comparison: a comparação da turma, já calculada.
        code: participante a apresentar.
        threshold: a partir de quantos desvios a barra é destacada.
        figure: figura a reaproveitar. Redesenhar numa figura existente evita
            recriar a tela do Qt a cada troca de aluno.

    Returns:
        A figura desenhada.

    Raises:
        KeyError: se o participante não estiver na comparação.
    """
    scores = comparison.for_participant(code)

    labels = [label for name, label in PRESENTED_FEATURES if name in scores]
    values = [scores[name] for name, _ in PRESENTED_FEATURES if name in scores]

    figure = figure or Figure(figsize=(7.2, 4.0), dpi=110)
    figure.clear()
    figure.patch.set_facecolor(theme.SURFACE)

    axes = figure.add_subplot(111)
    axes.set_facecolor(theme.SURFACE)

    positions = list(range(len(labels)))
    limit = max(2.4, max((abs(value) for value in values), default=0) * 1.3)

    axes.set_ylim(len(labels) - 0.5, -0.5)
    axes.set_xlim(-limit, limit)

    # Faixa da variação normal da turma, marcada por duas linhas tracejadas em
    # vez de um bloco preenchido: preenchida, ela domina o gráfico e passa a
    # parecer o fundo da área de plotagem em vez de uma referência.
    for edge in (-threshold, threshold):
        axes.axvline(
            edge,
            color=theme.LINE,
            linewidth=1.2,
            linestyle=(0, (4, 4)),
            zorder=1,
        )
    axes.axvline(0, color=theme.ZERO_LINE, linewidth=1.4, zorder=4)

    # Barras de ponta arredondada, ancoradas na linha de zero. O `barh` do
    # matplotlib só desenha canto reto; o FancyBboxPatch arredonda, e o raio é
    # limitado a metade do comprimento para que uma barra curta não vire
    # cápsula.
    height = 0.46
    for index, value in zip(positions, values, strict=True):
        colour = theme.ABOVE_CLASS if value >= 0 else theme.BELOW_CLASS
        length = abs(value)

        if length < 0.04 * limit:
            # Exatamente na média da turma: sem isto a linha fica vazia, e
            # uma linha vazia lê-se como dado faltando em vez de "igual à
            # turma". Um ponto neutro sobre o zero diz o que de fato houve.
            axes.plot(
                [value],
                [index],
                marker="o",
                markersize=7,
                color=theme.ZERO_LINE,
                zorder=3,
            )
            continue

        radius = min(0.055 * limit, length / 2)
        axes.add_patch(
            FancyBboxPatch(
                (min(0.0, value) + radius, index - height / 2),
                length - 2 * radius,
                height,
                boxstyle=f"round,pad={radius},rounding_size={radius}",
                mutation_aspect=limit / max(len(labels), 1) / 2.6,
                facecolor=colour,
                # Destaque sem depender de cor: quem passa do limiar ganha
                # contorno, e o contorno sobrevive à impressão em preto.
                edgecolor=theme.INK if abs(value) >= threshold else "none",
                linewidth=1.3 if abs(value) >= threshold else 0,
                zorder=3,
            )
        )

    axes.set_yticks(positions)
    axes.set_yticklabels(labels, fontsize=10.5, color=theme.INK)
    axes.tick_params(axis="y", length=0, pad=8)
    axes.set_xlabel(
        "desvios em relação à turma",
        fontsize=9.5,
        color=theme.INK_MUTED,
    )
    axes.tick_params(axis="x", labelsize=9, colors=theme.INK_MUTED, length=0, pad=6)

    # Rótulo em cada barra: são seis, e com seis o número em cada uma informa
    # mais do que polui. O texto usa tinta, nunca a cor da série.
    for index, value in zip(positions, values, strict=True):
        offset = limit * 0.04
        axes.text(
            value + (offset if value >= 0 else -offset),
            index,
            f"{value:+.1f}",
            va="center",
            ha="left" if value >= 0 else "right",
            fontsize=9.5,
            fontweight="bold" if abs(value) >= threshold else "normal",
            color=theme.INK if abs(value) >= threshold else theme.INK_MUTED,
        )

    for side in ("top", "right", "left", "bottom"):
        axes.spines[side].set_visible(False)
    axes.grid(False)

    figure.subplots_adjust(left=0.32, right=0.97, top=0.96, bottom=0.16)
    return figure


def describe_direction(value: float, threshold: float = HIGHLIGHT_THRESHOLD) -> str:
    """Frase curta para o valor, sem juízo de valor.

    O painel escreve "acima da turma", nunca "ruim" ou "preocupante": a
    diferença entre descrever e julgar é o que separa este painel de um
    instrumento diagnóstico.
    """
    if abs(value) < threshold:
        return "dentro da turma"
    return "acima da turma" if value > 0 else "abaixo da turma"
