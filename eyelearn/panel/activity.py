"""Dever de casa e o link da turma.

Celular não entra na escola, então a leitura é feita em casa. Nesta janela o
professor cria as atividades (tarefa, início e prazo), vê quem já entregou, e
pega o link e o código que vão para as famílias.

O link leva a turma cifrada (ver :mod:`eyelearn.storage.package`) e muda a cada
vez que as atividades ou os alunos mudam: é preciso mandar de novo. O código
fica o mesmo até o professor pedir outro.
"""

from __future__ import annotations

from datetime import date, timedelta

from PyQt6.QtCore import QDate, QSettings, Qt
from PyQt6.QtWidgets import (
    QApplication,
    QComboBox,
    QDateEdit,
    QDialog,
    QFrame,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from eyelearn.panel import theme
from eyelearn.storage import package
from eyelearn.storage.store import DEFAULT_APP_URL, Activity, Store, Teacher

TASK_LABELS = {
    "syllables": "Sílabas",
    "text": "Texto com sentido",
    "pseudotext": "Pseudotexto",
}

#: Onde o painel guarda o endereço do aplicativo web, se o professor trocar.
SETTINGS = ("EyeLearn", "painel")


def _qdate(value: date) -> QDate:
    return QDate(value.year, value.month, value.day)


def _pydate(value: QDate) -> date:
    return date(value.year(), value.month(), value.day())


def parents_message(class_name: str, link: str) -> str:
    """Texto para o grupo das famílias. O código vai separado, de propósito."""
    return (
        f"Atividade de leitura do EyeLearn ({class_name}).\n\n"
        "Abra o link no celular, digite o código da turma que a professora "
        "mandou à parte, e deixe a criança escolher o nome e digitar o PIN. "
        "São poucos minutos, num lugar com boa luz, com o celular apoiado na "
        "mesa. A câmera é usada só no aparelho: nenhuma imagem sai dele.\n\n"
        f"{link}"
    )


class HomeworkDialog(QDialog):
    def __init__(
        self,
        store: Store,
        teacher: Teacher,
        class_id: int,
        class_name: str,
        parent: QWidget | None = None,
        today: date | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Atividades e link da turma")
        self.setStyleSheet(theme.stylesheet())
        self.resize(820, 640)
        self.store = store
        self.teacher = teacher
        self.class_id = class_id
        self.class_name = class_name
        self.today = today or date.today()
        self.settings = QSettings(*SETTINGS)
        self.last_link: str | None = None

        root = QVBoxLayout(self)
        root.setContentsMargins(22, 20, 22, 20)
        root.setSpacing(12)

        title = QLabel(class_name)
        title.setProperty("role", "title")
        root.addWidget(title)

        root.addWidget(self._build_table(), stretch=1)
        root.addWidget(self._build_form())

        self.error = QLabel("")
        self.error.setWordWrap(True)
        self.error.setStyleSheet(
            f"color: #A32317; background: {theme.CORAL_SOFT};"
            "border-radius: 10px; padding: 8px 12px;"
        )
        self.error.hide()
        root.addWidget(self.error)

        root.addWidget(self._build_link())
        self.refresh()

    # -- construção ---------------------------------------------------------

    def _build_table(self) -> QWidget:
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Tarefa", "Início", "Prazo", "Entregues"])
        self.table.verticalHeader().hide()
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.ResizeMode.Stretch
        )
        return self.table

    def _build_form(self) -> QWidget:
        card = QFrame()
        card.setProperty("card", "true")
        layout = QHBoxLayout(card)
        layout.setContentsMargins(14, 12, 14, 12)

        self.task_box = QComboBox()
        for task, label in TASK_LABELS.items():
            self.task_box.addItem(label, task)
        self.task_box.setCurrentIndex(1)
        layout.addWidget(self.task_box, stretch=1)

        self.opens_edit = QDateEdit(_qdate(self.today))
        self.opens_edit.setCalendarPopup(True)
        self.opens_edit.setDisplayFormat("dd/MM/yyyy")
        self.due_edit = QDateEdit(_qdate(self.today + timedelta(days=7)))
        self.due_edit.setCalendarPopup(True)
        self.due_edit.setDisplayFormat("dd/MM/yyyy")
        layout.addWidget(QLabel("de"))
        layout.addWidget(self.opens_edit)
        layout.addWidget(QLabel("até"))
        layout.addWidget(self.due_edit)

        add = QPushButton("Criar atividade")
        add.clicked.connect(self.add_activity)
        layout.addWidget(add)

        remove = QPushButton("Apagar")
        remove.setProperty("variant", "ghost")
        remove.clicked.connect(self.ask_delete_activity)
        layout.addWidget(remove)
        return card

    def _build_link(self) -> QWidget:
        card = QFrame()
        card.setProperty("card", "true")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(10)

        label = QLabel("LINK DA TURMA")
        label.setProperty("role", "label")
        layout.addWidget(label)

        code_row = QHBoxLayout()
        code_row.addWidget(QLabel("Código da turma:"))
        self.code_label = QLabel("")
        self.code_label.setStyleSheet(
            "font-size: 22px; font-weight: 700; letter-spacing: 2px;"
        )
        self.code_label.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )
        code_row.addWidget(self.code_label)
        code_row.addStretch()
        copy_code = QPushButton("Copiar código")
        copy_code.setProperty("variant", "ghost")
        copy_code.clicked.connect(lambda: self.copy(self.code_label.text()))
        code_row.addWidget(copy_code)
        new_code = QPushButton("Trocar código")
        new_code.setProperty("variant", "ghost")
        new_code.clicked.connect(self.ask_new_code)
        code_row.addWidget(new_code)
        layout.addLayout(code_row)

        url_row = QHBoxLayout()
        url_row.addWidget(QLabel("Endereço do aplicativo:"))
        self.app_url = QLineEdit(str(self.settings.value("app_url", DEFAULT_APP_URL)))
        self.app_url.editingFinished.connect(
            lambda: self.settings.setValue("app_url", self.app_url.text().strip())
        )
        url_row.addWidget(self.app_url, stretch=1)
        layout.addLayout(url_row)

        buttons = QHBoxLayout()
        copy_message = QPushButton("Copiar mensagem com o link")
        copy_message.clicked.connect(self.copy_message)
        buttons.addWidget(copy_message)
        copy_link = QPushButton("Copiar só o link")
        copy_link.setProperty("variant", "ghost")
        copy_link.clicked.connect(lambda: self.copy(self.make_link()))
        buttons.addWidget(copy_link)
        buttons.addStretch()
        layout.addLayout(buttons)

        hint = QLabel(
            "Mande a mensagem com o link no grupo das famílias e o código à "
            "parte (bilhete na agenda, ou outra mensagem). Sem o código o link "
            "não abre. Sempre que criar ou apagar atividade, ou mudar alunos, "
            "mande o link de novo; o código continua o mesmo."
        )
        hint.setProperty("role", "muted")
        hint.setWordWrap(True)
        layout.addWidget(hint)
        return card

    # -- estado -------------------------------------------------------------

    def refresh(self) -> None:
        self.activities = self.store.activities(self.teacher, self.class_id)
        done = self.store.completed_activity_codes(self.teacher, self.class_id)
        total = len(self.store.students(self.teacher, self.class_id))
        self.table.setRowCount(0)
        for activity in self.activities:
            row = self.table.rowCount()
            self.table.insertRow(row)
            task = QTableWidgetItem(TASK_LABELS.get(activity.task, activity.task))
            task.setData(Qt.ItemDataRole.UserRole, activity.id)
            self.table.setItem(row, 0, task)
            opens = activity.opens_on.strftime("%d/%m/%Y")
            self.table.setItem(row, 1, QTableWidgetItem(opens))
            closed = activity.due_at.date() < self.today
            due = activity.due_at.strftime("%d/%m/%Y") + (" (encerrada)" if closed else "")
            self.table.setItem(row, 2, QTableWidgetItem(due))
            self.table.setItem(
                row, 3, QTableWidgetItem(f"{len(done.get(activity.code, ()))} de {total}")
            )
        self.code_label.setText(
            package.format_code(self.store.access_code(self.teacher, self.class_id))
        )

    def base_url(self) -> str:
        return self.app_url.text().strip() or DEFAULT_APP_URL

    def selected_activity(self) -> int | None:
        rows = self.table.selectionModel().selectedRows()
        if not rows:
            return None
        return self.table.item(rows[0].row(), 0).data(Qt.ItemDataRole.UserRole)

    # -- ações --------------------------------------------------------------

    def add_activity(self) -> Activity | None:
        self.error.hide()
        try:
            activity = self.store.create_activity(
                self.teacher,
                self.class_id,
                self.task_box.currentData(),
                due=_pydate(self.due_edit.date()),
                opens=_pydate(self.opens_edit.date()),
                today=self.today,
            )
        except ValueError as error:
            self.error.setText(str(error).capitalize() + ".")
            self.error.show()
            return None
        self.refresh()
        return activity

    def ask_delete_activity(self) -> None:
        activity_id = self.selected_activity()
        if activity_id is None:
            return
        answer = QMessageBox.question(
            self,
            "Apagar atividade",
            "Apagar esta atividade? Ela some do aplicativo quando as famílias "
            "abrirem o link novo; sessões já importadas continuam no painel.",
        )
        if answer == QMessageBox.StandardButton.Yes:
            self.store.delete_activity(self.teacher, activity_id)
            self.refresh()

    def ask_new_code(self) -> None:
        answer = QMessageBox.question(
            self,
            "Trocar código",
            "Trocar o código da turma? Os links já enviados deixam de abrir, e "
            "todas as famílias vão precisar do link e do código novos.",
        )
        if answer == QMessageBox.StandardButton.Yes:
            self.store.new_access_code(self.teacher, self.class_id)
            self.refresh()

    def make_link(self) -> str:
        shared = self.store.share_link(self.teacher, self.class_id, self.base_url())
        self.last_link = shared.url
        return shared.url

    def copy_message(self) -> None:
        self.copy(parents_message(self.class_name, self.make_link()))

    def copy(self, text: str) -> None:
        QApplication.clipboard().setText(text)
