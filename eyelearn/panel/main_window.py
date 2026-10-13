"""Janela do painel do professor.

Só montagem de widgets: o cálculo está em :mod:`eyelearn.session` e o gráfico
em :mod:`eyelearn.panel.charts`, ambos verificáveis sem abrir janela.

O painel **descreve e sugere; não diagnostica**. Não há em lugar nenhum um
rótulo de condição, uma pontuação apresentada como resultado ou um semáforo de
risco. O que ele mostra é onde a leitura de uma criança fica em relação à dos
colegas dela, e que adaptação pedagógica isso sugere.
"""

from __future__ import annotations

from pathlib import Path

from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg
from matplotlib.figure import Figure
from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QComboBox,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from eyelearn.panel import charts, theme
from eyelearn.session import (
    ClassComparison,
    Session,
    compare_within_class,
    load_sessions,
    suggestions_for,
)

TASK_LABELS = {
    "syllables": "Sílabas",
    "text": "Texto com sentido",
    "pseudotext": "Pseudotexto",
}


def _card(*, spacing: int = 12, margins: tuple[int, int, int, int] = (18, 16, 18, 16)):
    """Moldura branca de canto arredondado, com o seu leiaute vertical."""
    frame = QFrame()
    frame.setProperty("card", "true")
    layout = QVBoxLayout(frame)
    layout.setContentsMargins(*margins)
    layout.setSpacing(spacing)
    return frame, layout


def _label(text: str, role: str | None = None, wrap: bool = False) -> QLabel:
    widget = QLabel(text)
    if role:
        widget.setProperty("role", role)
    widget.setWordWrap(wrap)
    return widget


class PanelWindow(QWidget):
    """A janela inteira."""

    def __init__(self, folder: Path | None = None) -> None:
        super().__init__()
        self.setWindowTitle("EyeLearn — painel do professor")
        self.resize(1280, 820)
        self.setStyleSheet(theme.stylesheet())

        self._sessions: list[Session] = []
        self._comparison: ClassComparison | None = None
        self._figure = Figure(figsize=(7.2, 4.0), dpi=110)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(self._build_hero())

        body = QWidget()
        body_layout = QVBoxLayout(body)
        body_layout.setContentsMargins(22, 18, 22, 20)
        body_layout.setSpacing(14)
        body_layout.addWidget(self._build_toolbar())
        body_layout.addWidget(self._synthetic_banner)
        body_layout.addWidget(self._build_columns(), stretch=1)
        root.addWidget(body, stretch=1)

        if folder is not None:
            self.load_folder(folder)

    # -- construção ---------------------------------------------------------

    def _build_hero(self) -> QWidget:
        bar = QFrame()
        bar.setObjectName("heroBar")
        bar.setFixedHeight(84)

        layout = QHBoxLayout(bar)
        layout.setContentsMargins(24, 0, 24, 0)

        title = QLabel("EyeLearn")
        title.setObjectName("hero")
        subtitle = QLabel("Painel do professor")
        subtitle.setObjectName("heroSub")

        titles = QVBoxLayout()
        titles.setSpacing(0)
        titles.addWidget(title)
        titles.addWidget(subtitle)
        layout.addLayout(titles)
        layout.addStretch()

        self._folder_label = QLabel("Nenhuma turma carregada")
        self._folder_label.setObjectName("heroSub")
        layout.addWidget(self._folder_label)
        return bar

    def _build_toolbar(self) -> QWidget:
        bar = QWidget()
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)

        self._open_button = QPushButton("Abrir sessões…")
        self._open_button.clicked.connect(self._choose_folder)
        layout.addWidget(self._open_button)

        self._task_box = QComboBox()
        for task_id, label in TASK_LABELS.items():
            self._task_box.addItem(label, task_id)
        self._task_box.setCurrentIndex(1)
        self._task_box.currentIndexChanged.connect(lambda _: self._recompute())
        layout.addWidget(self._task_box)

        layout.addStretch()
        self._summary_label = _label("", "muted")
        layout.addWidget(self._summary_label)

        # O aviso de qualidade vive aqui porque vale para a turma inteira.
        self._synthetic_banner = _label("", "muted", wrap=True)
        self._synthetic_banner.setStyleSheet(
            f"background: {theme.CORAL_SOFT}; color: #A32317;"
            "border-radius: 12px; padding: 11px 14px;"
        )
        self._synthetic_banner.hide()
        return bar

    def _build_columns(self) -> QWidget:
        columns = QWidget()
        layout = QHBoxLayout(columns)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(14)

        left, left_layout = _card(margins=(14, 14, 14, 14))
        left.setFixedWidth(272)
        left_layout.addWidget(_label("TURMA", "label"))
        self._class_list = QListWidget()
        self._class_list.currentItemChanged.connect(
            lambda current, _: self._show_participant(
                current.data(Qt.ItemDataRole.UserRole) if current else None
            )
        )
        left_layout.addWidget(self._class_list, stretch=1)
        layout.addWidget(left)

        right = QScrollArea()
        right.setWidgetResizable(True)
        self._detail = QWidget()
        self._detail_layout = QVBoxLayout(self._detail)
        self._detail_layout.setContentsMargins(0, 0, 4, 0)
        self._detail_layout.setSpacing(14)
        right.setWidget(self._detail)
        layout.addWidget(right, stretch=1)
        return columns

    # -- dados --------------------------------------------------------------

    def _choose_folder(self) -> None:
        chosen = QFileDialog.getExistingDirectory(self, "Pasta com as sessões")
        if chosen:
            self.load_folder(Path(chosen))

    def load_folder(self, folder: Path) -> None:
        """Importa todas as sessões de uma pasta."""
        self._sessions = load_sessions(folder)
        self._folder_label.setText(f"{folder.name} · {len(self._sessions)} sessões")

        synthetic = any(s.trained_on_synthetic_data for s in self._sessions)
        self._synthetic_banner.setVisible(synthetic)
        if synthetic:
            self._synthetic_banner.setText(
                "As sessões desta turma foram pontuadas por um modelo treinado "
                "em dados sintéticos, que não aprendeu nada sobre leitura. Os "
                "números abaixo servem para experimentar o painel, não para "
                "orientar decisão nenhuma."
            )

        self._recompute()

    def _recompute(self) -> None:
        task = self._task_box.currentData()
        self._class_list.clear()
        self._comparison = None

        if not self._sessions:
            self._summary_label.setText("")
            self._render_empty("Abra uma pasta com sessões exportadas do celular.")
            return

        try:
            self._comparison = compare_within_class(self._sessions, task)
        except ValueError as error:
            self._summary_label.setText("")
            self._render_empty(str(error))
            return

        comparison = self._comparison
        flagged = comparison.outliers()
        discarded = [
            s
            for s in self._sessions
            if s.task == task and not s.has_usable_quality
        ]

        self._summary_label.setText(
            f"{len(comparison.participant_codes)} participantes · "
            f"{len(flagged)} para observar · {len(discarded)} fora por qualidade"
        )

        for code in comparison.participant_codes:
            item = QListWidgetItem(
                f"{code}      {'•  observar' if code in flagged else ''}".rstrip()
            )
            item.setData(Qt.ItemDataRole.UserRole, code)
            self._class_list.addItem(item)

        for session in discarded:
            item = QListWidgetItem(f"{session.participant_code}      captura ruim")
            item.setForeground(Qt.GlobalColor.gray)
            item.setData(Qt.ItemDataRole.UserRole, None)
            self._class_list.addItem(item)

        if self._class_list.count():
            self._class_list.setCurrentRow(0)

    # -- apresentação -------------------------------------------------------

    def _clear_detail(self) -> None:
        while self._detail_layout.count():
            item = self._detail_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

    def _render_empty(self, message: str) -> None:
        self._clear_detail()
        card, layout = _card()
        layout.addWidget(_label(message, "muted", wrap=True))
        self._detail_layout.addWidget(card)
        self._detail_layout.addStretch()

    def _show_participant(self, code: str | None) -> None:
        self._clear_detail()
        comparison = self._comparison

        if code is None or comparison is None:
            self._render_empty(
                "Esta gravação não atingiu o mínimo de qualidade e ficou fora "
                "da comparação. Ela aparece na lista para que se saiba que "
                "existe: vale repetir a atividade."
            )
            return

        self._detail_layout.addWidget(self._chart_card(comparison, code))
        self._detail_layout.addWidget(self._suggestion_card(comparison, code))
        self._detail_layout.addStretch()

    def _chart_card(self, comparison: ClassComparison, code: str) -> QWidget:
        card, layout = _card()

        header = QHBoxLayout()
        header.addWidget(_label(f"Participante {code}", "title"))
        header.addStretch()
        header.addWidget(
            _label(TASK_LABELS.get(comparison.task, comparison.task), "muted")
        )
        layout.addLayout(header)

        layout.addWidget(
            _label(
                "Cada barra mostra a que distância da média da turma esta "
                "criança está, em desvios. Entre as linhas tracejadas está a "
                "variação normal da turma; barras com contorno saíram dela.",
                "muted",
                wrap=True,
            )
        )

        charts.z_score_figure(comparison, code, figure=self._figure)
        canvas = FigureCanvasQTAgg(self._figure)
        canvas.setMinimumHeight(330)
        canvas.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        canvas.draw()
        layout.addWidget(canvas)
        return card

    def _suggestion_card(self, comparison: ClassComparison, code: str) -> QWidget:
        card, layout = _card()
        layout.addWidget(_label("SUGESTÕES DE ADAPTAÇÃO", "label"))

        suggestions = suggestions_for(comparison, code)
        if not suggestions:
            layout.addWidget(
                _label(
                    "A leitura desta criança está dentro da variação da turma "
                    "em todas as medidas observadas. Nenhuma adaptação é "
                    "sugerida.",
                    "muted",
                    wrap=True,
                )
            )
            return card

        for text in suggestions:
            row = QFrame()
            row.setStyleSheet(
                f"background: {theme.BRAND_SOFT}; border-radius: 12px;"
            )
            row_layout = QHBoxLayout(row)
            row_layout.setContentsMargins(14, 12, 14, 12)
            row_layout.addWidget(_label(text, wrap=True))
            layout.addWidget(row)

        layout.addWidget(
            _label(
                "Sugestões pedagógicas, não conduta clínica. O sistema descreve "
                "o padrão observado; qualquer avaliação é de profissional "
                "habilitado.",
                "muted",
                wrap=True,
            )
        )
        return card
