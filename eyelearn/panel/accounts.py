"""Login do professor e cadastro de turmas e alunos.

As regras ficam em :mod:`eyelearn.storage`; aqui é só a tela. O que este
módulo cuida é do que a tela decide: o PIN do aluno aparece **uma vez**, logo
depois do cadastro, e não há botão que o mostre de novo -- quem esqueceu gera
outro.
"""

from __future__ import annotations

import json
from datetime import date, datetime
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QComboBox,
    QDialog,
    QFileDialog,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QStackedWidget,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from eyelearn.panel import theme
from eyelearn.storage.auth import CredentialError
from eyelearn.storage.store import (
    AccountLockedError,
    Classroom,
    Store,
    Teacher,
)


def parse_birth_date(text: str) -> date | None:
    """Data de nascimento como o professor digita: ``dd/mm/aaaa``, ou vazio.

    Raises:
        ValueError: com mensagem para a tela, se a data não existir ou estiver
            no futuro.
    """
    text = text.strip()
    if not text:
        return None
    try:
        parsed = datetime.strptime(text, "%d/%m/%Y").date()
    except ValueError as error:
        raise ValueError("data de nascimento no formato dd/mm/aaaa") from error
    if parsed > date.today():
        raise ValueError("a data de nascimento está no futuro")
    return parsed


def format_birth_date(iso: str | None) -> str:
    return date.fromisoformat(iso).strftime("%d/%m/%Y") if iso else "—"


def _error_label() -> QLabel:
    label = QLabel("")
    label.setWordWrap(True)
    label.setStyleSheet(f"color: #A32317; background: {theme.CORAL_SOFT};"
                        "border-radius: 10px; padding: 8px 12px;")
    label.hide()
    return label


def _show_error(label: QLabel, message: str) -> None:
    label.setText(message)
    label.show()


def _ghost(text: str) -> QPushButton:
    button = QPushButton(text)
    button.setProperty("variant", "ghost")
    return button


class LoginDialog(QDialog):
    """Entrada do professor. Sem nenhum professor no banco, abre o cadastro."""

    def __init__(self, store: Store, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("EyeLearn — entrar")
        self.setStyleSheet(theme.stylesheet())
        self.setMinimumWidth(420)
        self.store = store
        self.teacher: Teacher | None = None

        root = QVBoxLayout(self)
        root.setContentsMargins(28, 24, 28, 24)
        root.setSpacing(14)
        title = QLabel("EyeLearn")
        title.setProperty("role", "title")
        root.addWidget(title)

        self.pages = QStackedWidget()
        self.pages.addWidget(self._build_login())
        self.pages.addWidget(self._build_signup())
        root.addWidget(self.pages)
        self.pages.setCurrentIndex(0 if store.has_teachers() else 1)

    # -- entrar ---------------------------------------------------------------

    def _build_login(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)

        subtitle = QLabel("Painel do professor")
        subtitle.setProperty("role", "muted")
        layout.addWidget(subtitle)

        form = QFormLayout()
        self.login_user = QLineEdit()
        self.login_password = QLineEdit()
        self.login_password.setEchoMode(QLineEdit.EchoMode.Password)
        self.login_password.returnPressed.connect(self.submit_login)
        form.addRow("Usuário", self.login_user)
        form.addRow("Senha", self.login_password)
        layout.addLayout(form)

        self.login_error = _error_label()
        layout.addWidget(self.login_error)

        buttons = QHBoxLayout()
        create = _ghost("Criar conta")
        create.clicked.connect(lambda: self.pages.setCurrentIndex(1))
        buttons.addWidget(create)
        buttons.addStretch()
        self.login_button = QPushButton("Entrar")
        self.login_button.setDefault(True)
        self.login_button.clicked.connect(self.submit_login)
        buttons.addWidget(self.login_button)
        layout.addLayout(buttons)
        return page

    def submit_login(self) -> None:
        try:
            teacher = self.store.authenticate(
                self.login_user.text(), self.login_password.text()
            )
        except AccountLockedError as error:
            _show_error(self.login_error, str(error).capitalize() + ".")
            return
        if teacher is None:
            # Mesma mensagem para usuário inexistente e senha errada: dizer
            # qual dos dois falhou diria a quem tenta que o usuário existe.
            _show_error(self.login_error, "Usuário ou senha não conferem.")
            self.login_password.clear()
            return
        self.teacher = teacher
        self.accept()

    # -- criar conta ----------------------------------------------------------

    def _build_signup(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)

        intro = QLabel(
            "Crie a sua conta de professor. Ela fica só neste computador: "
            "não há servidor, e nada é enviado pela rede."
        )
        intro.setProperty("role", "muted")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        form = QFormLayout()
        self.signup_name = QLineEdit()
        self.signup_user = QLineEdit()
        self.signup_password = QLineEdit()
        self.signup_confirm = QLineEdit()
        for field in (self.signup_password, self.signup_confirm):
            field.setEchoMode(QLineEdit.EchoMode.Password)
        self.signup_confirm.returnPressed.connect(self.submit_signup)
        form.addRow("Nome", self.signup_name)
        form.addRow("Usuário", self.signup_user)
        form.addRow("Senha", self.signup_password)
        form.addRow("Repita a senha", self.signup_confirm)
        layout.addLayout(form)

        self.signup_error = _error_label()
        layout.addWidget(self.signup_error)

        buttons = QHBoxLayout()
        back = _ghost("Já tenho conta")
        back.clicked.connect(lambda: self.pages.setCurrentIndex(0))
        buttons.addWidget(back)
        buttons.addStretch()
        self.signup_button = QPushButton("Criar conta")
        self.signup_button.clicked.connect(self.submit_signup)
        buttons.addWidget(self.signup_button)
        layout.addLayout(buttons)
        return page

    def submit_signup(self) -> None:
        if self.signup_password.text() != self.signup_confirm.text():
            _show_error(self.signup_error, "As duas senhas não são iguais.")
            return
        try:
            self.teacher = self.store.create_teacher(
                self.signup_user.text(),
                self.signup_name.text(),
                self.signup_password.text(),
            )
        except CredentialError as error:
            _show_error(self.signup_error, str(error).capitalize() + ".")
            return
        self.accept()


class NewClassDialog(QDialog):
    """Nome, escola e série -- os campos escolares do cadastro antigo."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Nova turma")
        self.setStyleSheet(theme.stylesheet())
        layout = QVBoxLayout(self)
        form = QFormLayout()
        self.name = QLineEdit()
        self.name.setPlaceholderText("5º A")
        self.school = QLineEdit()
        self.grade = QLineEdit()
        self.grade.setPlaceholderText("5º ano")
        form.addRow("Turma", self.name)
        form.addRow("Escola", self.school)
        form.addRow("Série", self.grade)
        layout.addLayout(form)
        buttons = QHBoxLayout()
        buttons.addStretch()
        cancel = _ghost("Cancelar")
        cancel.clicked.connect(self.reject)
        ok = QPushButton("Criar")
        ok.clicked.connect(self.accept)
        buttons.addWidget(cancel)
        buttons.addWidget(ok)
        layout.addLayout(buttons)


class StudentsDialog(QDialog):
    """Turmas e alunos do professor, e a lista que vai para o celular."""

    def __init__(
        self,
        store: Store,
        teacher: Teacher,
        class_id: int | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Alunos e turmas")
        self.setStyleSheet(theme.stylesheet())
        self.resize(820, 600)
        self.store = store
        self.teacher = teacher
        self.last_pin: tuple[str, str] | None = None

        root = QVBoxLayout(self)
        root.setContentsMargins(22, 20, 22, 20)
        root.setSpacing(12)

        top = QHBoxLayout()
        self.class_box = QComboBox()
        self.class_box.currentIndexChanged.connect(lambda _: self.refresh_students())
        top.addWidget(self.class_box, stretch=1)
        new_class = _ghost("Nova turma…")
        new_class.clicked.connect(self.ask_new_class)
        top.addWidget(new_class)
        self.export_button = QPushButton("Exportar lista para o celular…")
        self.export_button.clicked.connect(self.ask_export_roster)
        top.addWidget(self.export_button)
        root.addLayout(top)

        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["Nome", "Código", "Nascimento"])
        self.table.verticalHeader().hide()
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        root.addWidget(self.table, stretch=1)

        row_actions = QHBoxLayout()
        row_actions.addStretch()
        self.reset_button = _ghost("Gerar novo PIN")
        self.reset_button.clicked.connect(self.ask_reset_pin)
        self.delete_button = _ghost("Remover aluno")
        self.delete_button.clicked.connect(self.ask_delete_student)
        row_actions.addWidget(self.reset_button)
        row_actions.addWidget(self.delete_button)
        root.addLayout(row_actions)

        add_card = QFrame()
        add_card.setProperty("card", "true")
        add_layout = QHBoxLayout(add_card)
        add_layout.setContentsMargins(14, 12, 14, 12)
        self.new_name = QLineEdit()
        self.new_name.setPlaceholderText("Nome completo do aluno")
        self.new_birth = QLineEdit()
        self.new_birth.setPlaceholderText("Nascimento dd/mm/aaaa")
        self.new_birth.setFixedWidth(230)
        self.new_birth.returnPressed.connect(self.submit_new_student)
        self.add_button = QPushButton("Cadastrar")
        self.add_button.clicked.connect(self.submit_new_student)
        add_layout.addWidget(self.new_name, stretch=1)
        add_layout.addWidget(self.new_birth)
        add_layout.addWidget(self.add_button)
        root.addWidget(add_card)

        self.error = _error_label()
        root.addWidget(self.error)

        note = QLabel(
            "O PIN aparece uma vez, logo depois do cadastro. Anote e entregue à "
            "criança; se ela esquecer, gere outro. A lista exportada para o "
            "celular leva só o primeiro nome com a inicial, o código e o PIN "
            "em forma ilegível; o nome completo e a data de nascimento ficam aqui."
        )
        note.setProperty("role", "muted")
        note.setWordWrap(True)
        root.addWidget(note)

        self.refresh_classes(select=class_id)

    # -- estado ---------------------------------------------------------------

    @property
    def class_id(self) -> int | None:
        return self.class_box.currentData()

    def refresh_classes(self, select: int | None = None) -> None:
        self.class_box.blockSignals(True)
        self.class_box.clear()
        for classroom in self.store.classes(self.teacher):
            self.class_box.addItem(_class_caption(classroom), classroom.id)
        if select is not None:
            index = self.class_box.findData(select)
            if index >= 0:
                self.class_box.setCurrentIndex(index)
        self.class_box.blockSignals(False)
        self.refresh_students()

    def refresh_students(self) -> None:
        has_class = self.class_id is not None
        for widget in (self.export_button, self.add_button, self.new_name,
                       self.new_birth, self.reset_button, self.delete_button):
            widget.setEnabled(has_class)
        self.table.setRowCount(0)
        if not has_class:
            return
        for student in self.store.students(self.teacher, self.class_id):
            row = self.table.rowCount()
            self.table.insertRow(row)
            name = QTableWidgetItem(student.full_name)
            name.setData(Qt.ItemDataRole.UserRole, student.id)
            self.table.setItem(row, 0, name)
            self.table.setItem(row, 1, QTableWidgetItem(student.code))
            self.table.setItem(row, 2, QTableWidgetItem(format_birth_date(student.birth_date)))

    def selected_student(self) -> tuple[int, str] | None:
        rows = self.table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.table.item(rows[0].row(), 0)
        return item.data(Qt.ItemDataRole.UserRole), item.text()

    # -- ações ----------------------------------------------------------------

    def create_class(self, name: str, school: str = "", grade: str = "") -> Classroom:
        classroom = self.store.create_class(self.teacher, name, school, grade)
        self.refresh_classes(select=classroom.id)
        return classroom

    def ask_new_class(self) -> None:
        dialog = NewClassDialog(self)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        try:
            self.create_class(dialog.name.text(), dialog.school.text(), dialog.grade.text())
        except ValueError as error:
            QMessageBox.warning(self, "Nova turma", str(error).capitalize() + ".")

    def add_student(self) -> str | None:
        """Cadastra com o que está no formulário. Devolve o PIN, ou ``None``."""
        self.error.hide()
        try:
            birth = parse_birth_date(self.new_birth.text())
            new = self.store.add_student(
                self.teacher, self.class_id, self.new_name.text(), birth
            )
        except (ValueError, CredentialError) as error:
            _show_error(self.error, str(error).capitalize() + ".")
            return None
        self.new_name.clear()
        self.new_birth.clear()
        self.refresh_students()
        self.last_pin = (new.student.full_name, new.pin)
        return new.pin

    def submit_new_student(self) -> None:
        pin = self.add_student()
        if pin is not None:
            _show_pin(self, self.last_pin[0], pin)
            self.new_name.setFocus()

    def ask_reset_pin(self) -> None:
        selected = self.selected_student()
        if selected is None:
            return
        student_id, name = selected
        pin = self.store.reset_pin(self.teacher, student_id)
        _show_pin(self, name, pin)

    def ask_delete_student(self) -> None:
        selected = self.selected_student()
        if selected is None:
            return
        student_id, name = selected
        answer = QMessageBox.question(
            self,
            "Remover aluno",
            f"Remover {name}? Todas as sessões gravadas dessa criança serão "
            "apagadas junto, e não há como desfazer.",
        )
        if answer == QMessageBox.StandardButton.Yes:
            self.delete_student(student_id)

    def delete_student(self, student_id: int) -> None:
        self.store.delete_student(self.teacher, student_id)
        self.refresh_students()

    def export_roster(self, path: Path) -> Path:
        roster = self.store.roster(self.teacher, self.class_id)
        path.write_text(json.dumps(roster, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
        return path

    def ask_export_roster(self) -> None:
        caption = self.class_box.currentText().split(" · ")[0]
        suggested = f"turma_{_slug(caption)}.eyelearn.json"
        chosen, _ = QFileDialog.getSaveFileName(
            self, "Exportar lista da turma", suggested, "Lista de turma (*.json)"
        )
        if chosen:
            self.export_roster(Path(chosen))
            QMessageBox.information(
                self,
                "Lista exportada",
                "Envie o arquivo para o celular e abra no EyeLearn. As crianças "
                "vão escolher o próprio nome e digitar o PIN.",
            )


def _show_pin(parent: QWidget, name: str, pin: str) -> None:
    box = QMessageBox(parent)
    box.setWindowTitle("PIN do aluno")
    box.setTextFormat(Qt.TextFormat.RichText)
    box.setText(
        f"PIN de <b>{_escape(name)}</b>:"
        f"<p style='font-size:30px; letter-spacing:8px; font-weight:700'>{pin}</p>"
        "Anote e entregue à criança. Este PIN não aparece de novo."
    )
    box.exec()


def _class_caption(classroom: Classroom) -> str:
    extra = " · ".join(part for part in (classroom.grade, classroom.school) if part)
    return f"{classroom.name} · {extra}" if extra else classroom.name


def _slug(text: str) -> str:
    kept = "".join(c if c.isalnum() else "_" for c in text.lower())
    return "_".join(part for part in kept.split("_") if part) or "turma"


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
