"""Janela do painel do professor.

Só montagem de widgets: o cálculo está em :mod:`eyelearn.session` e o gráfico
em :mod:`eyelearn.panel.charts`, ambos verificáveis sem abrir janela.

Dois modos. Com banco (o normal), o professor entra com usuário e senha, vê os
alunos pelo nome e importa as sessões para a turma. Sem banco, abre uma pasta de
sessões soltas, identificadas só pelo código -- é o modo de demonstração.

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
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from eyelearn.panel import charts, theme
from eyelearn.panel.accounts import StudentsDialog
from eyelearn.panel.activity import HomeworkDialog
from eyelearn.session import (
    ClassComparison,
    Session,
    compare_within_class,
    load_sessions,
    suggestions_for,
)
from eyelearn.storage.store import ImportReport, Store, Teacher

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

    def __init__(
        self,
        folder: Path | None = None,
        *,
        store: Store | None = None,
        teacher: Teacher | None = None,
    ) -> None:
        super().__init__()
        if (store is None) != (teacher is None):
            raise ValueError("store e teacher andam juntos")
        self.setWindowTitle("EyeLearn — painel do professor")
        self.resize(1280, 820)
        self.setStyleSheet(theme.stylesheet())

        self._store = store
        self._teacher = teacher
        #: Código -> nome completo. Vazio no modo de demonstração, em que a
        #: lista mostra só o código.
        self._names: dict[str, str] = {}
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

        if store is not None:
            self._refresh_classes()
        elif folder is not None:
            self.load_folder(folder)
        else:
            self._recompute()

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

        self._folder_label = QLabel(
            f"Prof. {self._teacher.name}" if self._teacher else "Nenhuma turma carregada"
        )
        self._folder_label.setObjectName("heroSub")
        layout.addWidget(self._folder_label)
        return bar

    def _build_toolbar(self) -> QWidget:
        bar = QWidget()
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)

        if self._store is None:
            self._open_button = QPushButton("Abrir sessões…")
            self._open_button.clicked.connect(self._choose_folder)
            layout.addWidget(self._open_button)
        else:
            self._class_box = QComboBox()
            self._class_box.currentIndexChanged.connect(lambda _: self.load_class())
            layout.addWidget(self._class_box)

            self._activity_button = QPushButton("Atividades e link…")
            self._activity_button.clicked.connect(self._open_activity)
            layout.addWidget(self._activity_button)

            self._import_button = QPushButton("Importar sessões…")
            self._import_button.setProperty("variant", "ghost")
            self._import_button.clicked.connect(self._choose_session_files)
            layout.addWidget(self._import_button)

            students = QPushButton("Alunos e turmas…")
            students.setProperty("variant", "ghost")
            students.clicked.connect(self._open_students)
            layout.addWidget(students)

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
        """Modo de demonstração: lê as sessões de uma pasta, sem banco."""
        sessions = load_sessions(folder)
        self._folder_label.setText(f"{folder.name} · {len(sessions)} sessões")
        self._set_sessions(sessions)

    # -- modo com banco -----------------------------------------------------

    def _refresh_classes(self, select: int | None = None) -> None:
        current = self._class_box.currentData() if select is None else select
        self._class_box.blockSignals(True)
        self._class_box.clear()
        for classroom in self._store.classes(self._teacher):
            self._class_box.addItem(classroom.name, classroom.id)
        index = self._class_box.findData(current)
        self._class_box.setCurrentIndex(max(index, 0))
        self._class_box.blockSignals(False)
        self._import_button.setEnabled(self._class_box.count() > 0)
        self._activity_button.setEnabled(self._class_box.count() > 0)
        self.load_class()

    def load_class(self) -> None:
        """Carrega as sessões e os nomes da turma escolhida."""
        class_id = self._class_box.currentData()
        if class_id is None:
            self._names = {}
            self._set_sessions([])
            return
        self._names = {
            s.code: s.full_name for s in self._store.students(self._teacher, class_id)
        }
        self._set_sessions(self._store.sessions(self._teacher, class_id))

    def import_files(self, paths: list[Path]) -> ImportReport:
        report = self._store.import_files(self._teacher, paths)
        self.load_class()
        return report

    def _choose_session_files(self) -> None:
        chosen, _ = QFileDialog.getOpenFileNames(
            self, "Sessões exportadas do celular", "", "Sessão EyeLearn (*.json)"
        )
        if not chosen:
            return
        report = self.import_files([Path(path) for path in chosen])
        QMessageBox.information(self, "Importação", describe_import(report))

    def _open_activity(self) -> None:
        HomeworkDialog(
            self._store,
            self._teacher,
            self._class_box.currentData(),
            self._class_box.currentText(),
            parent=self,
        ).exec()

    def _open_students(self) -> None:
        dialog = StudentsDialog(
            self._store, self._teacher, self._class_box.currentData(), parent=self
        )
        dialog.exec()
        self._refresh_classes(select=dialog.class_id)

    def display_name(self, code: str) -> str:
        return self._names.get(code, code)

    # -- comum aos dois modos ----------------------------------------------

    def _set_sessions(self, sessions: list[Session]) -> None:
        self._sessions = sessions
        demo = any(s.demo_data for s in self._sessions)
        synthetic = any(s.trained_on_synthetic_data for s in self._sessions)
        self._synthetic_banner.setVisible(demo or synthetic)
        if demo:
            self._synthetic_banner.setText(
                "Turma de demonstração: os percursos do olhar foram gerados por "
                "computador, não vêm de crianças lendo. Os números abaixo servem "
                "para experimentar o painel, não para orientar decisão nenhuma."
            )
        elif synthetic:
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
            self._render_empty(self._empty_message())
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

        for code in sorted(comparison.participant_codes, key=self.display_name):
            item = QListWidgetItem(
                f"{self.display_name(code)}      "
                f"{'•  observar' if code in flagged else ''}".rstrip()
            )
            item.setData(Qt.ItemDataRole.UserRole, code)
            self._class_list.addItem(item)

        for session in discarded:
            item = QListWidgetItem(
                f"{self.display_name(session.participant_code)}      captura ruim"
            )
            item.setForeground(Qt.GlobalColor.gray)
            item.setData(Qt.ItemDataRole.UserRole, None)
            self._class_list.addItem(item)

        if self._class_list.count():
            self._class_list.setCurrentRow(0)

    # -- apresentação -------------------------------------------------------

    def _empty_message(self) -> str:
        if self._store is None:
            return "Abra uma pasta com sessões exportadas do celular."
        if self._class_box.count() == 0:
            return (
                "Nenhuma turma ainda. Em “Alunos e turmas”, crie a turma, "
                "cadastre os alunos; depois, em “Atividades e link”, crie o dever "
                "de casa e mande o link às famílias."
            )
        return (
            "Nenhuma sessão desta turma ainda. Depois da atividade, importe os "
            "arquivos que as famílias mandaram em “Importar sessões”."
        )

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
        name = self._names.get(code)
        header.addWidget(_label(name or f"Participante {code}", "title"))
        if name:
            header.addWidget(_label(code, "muted"))
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


def describe_import(report: ImportReport) -> str:
    """O resultado da importação, em frases para o professor."""
    lines = [f"{len(report.imported)} sessão(ões) importada(s)."]
    if report.duplicates:
        lines.append(f"{len(report.duplicates)} já estavam no banco e foram ignoradas.")
    if report.unknown_codes:
        codes = ", ".join(sorted(set(report.unknown_codes)))
        lines.append(
            f"{len(report.unknown_codes)} de código que não é de aluno seu ({codes}): "
            "confira se o link enviado às famílias é desta turma."
        )
    if report.wrong_activity:
        lines.append(
            f"{len(report.wrong_activity)} de atividade que não é desta turma ou "
            "desta tarefa, e não foram importadas: "
            + ", ".join(report.wrong_activity)
        )
    if report.unreadable:
        lines.append(
            f"{len(report.unreadable)} arquivo(s) ilegível(is): "
            + ", ".join(report.unreadable)
        )
    return "\n".join(lines)
