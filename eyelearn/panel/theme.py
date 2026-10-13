"""Identidade visual do painel do professor.

Mesma paleta do aplicativo do aluno (`mobile/eyelearn_app/lib/src/ui/theme.dart`),
para que professor e criança reconheçam o mesmo sistema. As duas cópias são
mantidas à mão porque Dart e Python não compartilham constantes; os valores
estão nos dois arquivos e qualquer mudança precisa ir aos dois.

O painel é desktop: densidade maior, texto menor e mais informação por tela do
que no celular. O que não muda é a paleta e o princípio de nunca apresentar
rótulo diagnóstico.
"""

from __future__ import annotations

# --- Paleta, igual à do aplicativo -----------------------------------------

BRAND = "#5B4BE8"
BRAND_DEEP = "#3A2FB0"
BRAND_SOFT = "#EDEAFF"

AMBER = "#FFB23F"
AMBER_SOFT = "#FFF3DE"

GREEN = "#17A673"
GREEN_SOFT = "#E2F6EF"

CORAL = "#F2594B"
CORAL_SOFT = "#FFE9E6"

INK = "#1C2033"
INK_MUTED = "#6B7194"
LINE = "#E6E5F2"

SURFACE = "#FFFFFF"
BACKGROUND = "#F5F4FD"

# --- Cores do gráfico -------------------------------------------------------

#: Par divergente do gráfico de escores z.
#:
#: Âmbar escuro para quem está acima da turma, violeta para quem está abaixo,
#: cinza no zero. **Não** verde e vermelho, que é a escolha óbvia e a errada:
#: estar acima da média em duração de fixação não é "ruim", é uma observação
#: que pode merecer uma adaptação. Verde e vermelho transformariam o painel num
#: semáforo diagnóstico, que é exatamente o que o projeto se compromete a não
#: fazer.
#:
#: O tom do âmbar (``#C27A00``, mais escuro que o da interface) foi escolhido
#: para passar nos critérios de contraste e de separação para daltonismo: ΔE
#: 33,4 em protanopia contra o violeta, e 3:1 contra o branco.
ABOVE_CLASS = "#C27A00"
BELOW_CLASS = BRAND
ZERO_LINE = "#9AA0B8"

# --- Tipografia -------------------------------------------------------------

#: A mesma família da interface do aplicativo, quando instalada no sistema.
#: Qt cai para a fonte padrão quando não encontra, sem quebrar o leiaute.
FONT_FAMILY = "Outfit, Inter, DejaVu Sans, sans-serif"


def stylesheet() -> str:
    """Folha de estilo do Qt para a janela inteira."""
    return f"""
    QWidget {{
        background: {BACKGROUND};
        color: {INK};
        font-family: {FONT_FAMILY};
        font-size: 14px;
    }}

    /* A barra do topo pinta a si e aos filhos: sem o `transparent` nos
       rótulos, eles herdam o fundo global e aparecem como retângulos claros
       sobre o violeta. */
    QFrame#heroBar {{
        background: {BRAND_DEEP};
        border: none;
        border-radius: 0px;
    }}
    QFrame#heroBar QLabel {{
        background: transparent;
    }}
    QLabel#hero {{
        color: #FFFFFF;
        font-size: 26px;
        font-weight: 700;
    }}
    QLabel#heroSub {{
        color: #C9C2F5;
        font-size: 13px;
    }}

    QFrame[card="true"] {{
        background: {SURFACE};
        border: 1px solid {LINE};
        border-radius: 18px;
    }}

    QLabel[role="title"] {{
        font-size: 19px;
        font-weight: 700;
        color: {INK};
    }}
    QLabel[role="label"] {{
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 1px;
        color: {INK_MUTED};
    }}
    QLabel[role="muted"] {{
        color: {INK_MUTED};
    }}
    QLabel[role="stat"] {{
        font-size: 22px;
        font-weight: 700;
        color: {INK};
    }}

    QListWidget {{
        background: {SURFACE};
        border: 1px solid {LINE};
        border-radius: 18px;
        padding: 8px;
        outline: none;
    }}
    QListWidget::item {{
        padding: 11px 12px;
        border-radius: 12px;
        margin-bottom: 3px;
    }}
    QListWidget::item:selected {{
        background: {BRAND_SOFT};
        color: {BRAND_DEEP};
        font-weight: 700;
    }}
    QListWidget::item:hover:!selected {{
        background: {BACKGROUND};
    }}

    QComboBox {{
        background: {SURFACE};
        border: 1px solid {LINE};
        border-radius: 12px;
        padding: 9px 14px;
        min-width: 190px;
    }}
    QComboBox::drop-down {{ border: none; width: 26px; }}
    QComboBox QAbstractItemView {{
        background: {SURFACE};
        border: 1px solid {LINE};
        border-radius: 12px;
        selection-background-color: {BRAND_SOFT};
        selection-color: {BRAND_DEEP};
        padding: 6px;
    }}

    QPushButton {{
        background: {BRAND};
        color: #FFFFFF;
        border: none;
        border-radius: 14px;
        padding: 11px 20px;
        font-weight: 700;
    }}
    QPushButton:hover {{ background: {BRAND_DEEP}; }}
    QPushButton[variant="ghost"] {{
        background: {SURFACE};
        color: {BRAND};
        border: 1px solid {LINE};
    }}
    QPushButton[variant="ghost"]:hover {{ background: {BACKGROUND}; }}

    QScrollArea {{ border: none; background: transparent; }}
    QScrollBar:vertical {{
        background: transparent; width: 10px; margin: 4px;
    }}
    QScrollBar::handle:vertical {{
        background: {LINE}; border-radius: 5px; min-height: 30px;
    }}
    QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
    """
