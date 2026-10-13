"""Telas de login e de cadastro do painel, com Qt fora da tela.

Precisa de PyQt6, que o job ``pytest`` da integração contínua não instala: lá
este arquivo é pulado, e quem o roda é o job ``panel``. As regras de negócio
estão testadas sem Qt em ``test_storage.py``; aqui se verifica o que a tela
decide -- mensagens, o PIN mostrado uma vez, e o que vai para o celular.
"""

from __future__ import annotations

import json
import os
from datetime import date, timedelta

import pytest

pytest.importorskip("PyQt6.QtWidgets")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication  # noqa: E402

from eyelearn.panel.accounts import (  # noqa: E402
    LoginDialog,
    StudentsDialog,
    parse_birth_date,
)
from eyelearn.panel.main_window import PanelWindow, describe_import  # noqa: E402
from eyelearn.storage import auth  # noqa: E402
from eyelearn.storage.store import ImportReport, Store  # noqa: E402
from tests.test_session import make_payload  # noqa: E402


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def store(tmp_path):
    opened = Store.open(tmp_path / "painel.db")
    yield opened
    opened.close()


@pytest.fixture
def teacher(store):
    return store.create_teacher("helena", "Helena Prado", "senha-boa-123")


class TestParseBirthDate:
    def test_brazilian_format(self):
        assert parse_birth_date(" 09/03/2016 ") == date(2016, 3, 9)

    def test_empty_is_none(self):
        assert parse_birth_date("") is None

    @pytest.mark.parametrize("text", ["2016-03-09", "31/02/2016", "9/3/16x"])
    def test_rejects(self, text):
        with pytest.raises(ValueError, match="dd/mm/aaaa"):
            parse_birth_date(text)

    def test_rejects_future(self):
        tomorrow = (date.today() + timedelta(days=1)).strftime("%d/%m/%Y")
        with pytest.raises(ValueError, match="futuro"):
            parse_birth_date(tomorrow)


class TestLoginDialog:
    def test_empty_database_opens_on_signup(self, app, store):
        assert LoginDialog(store).pages.currentIndex() == 1

    def test_signup_creates_the_teacher(self, app, store):
        dialog = LoginDialog(store)
        dialog.signup_name.setText("Helena Prado")
        dialog.signup_user.setText("helena")
        dialog.signup_password.setText("senha-boa-123")
        dialog.signup_confirm.setText("senha-boa-123")
        dialog.submit_signup()
        assert dialog.teacher is not None
        assert store.authenticate("helena", "senha-boa-123") == dialog.teacher

    def test_signup_needs_matching_passwords(self, app, store):
        dialog = LoginDialog(store)
        dialog.signup_name.setText("Helena")
        dialog.signup_user.setText("helena")
        dialog.signup_password.setText("senha-boa-123")
        dialog.signup_confirm.setText("senha-boa-124")
        dialog.submit_signup()
        assert dialog.teacher is None
        assert not store.has_teachers()
        assert "iguais" in dialog.signup_error.text()

    def test_existing_database_opens_on_login(self, app, store, teacher):
        assert LoginDialog(store).pages.currentIndex() == 0

    def test_login(self, app, store, teacher):
        dialog = LoginDialog(store)
        dialog.login_user.setText("helena")
        dialog.login_password.setText("senha-boa-123")
        dialog.submit_login()
        assert dialog.teacher == teacher

    def test_wrong_password_does_not_say_which_part_failed(self, app, store, teacher):
        messages = []
        for user in ("helena", "ninguem"):
            dialog = LoginDialog(store)
            dialog.login_user.setText(user)
            dialog.login_password.setText("errada-errada")
            dialog.submit_login()
            assert dialog.teacher is None
            messages.append(dialog.login_error.text())
        assert messages[0] == messages[1]

    def test_lockout_is_reported(self, app, store, teacher):
        dialog = LoginDialog(store)
        dialog.login_user.setText("helena")
        for _ in range(store.limiter.max_failures):
            dialog.login_password.setText("errada-errada")
            dialog.submit_login()
        dialog.login_password.setText("senha-boa-123")
        dialog.submit_login()
        assert dialog.teacher is None
        assert "tentativas" in dialog.login_error.text()


class TestStudentsDialog:
    def test_starts_without_classes(self, app, store, teacher):
        dialog = StudentsDialog(store, teacher)
        assert dialog.class_id is None
        assert not dialog.add_button.isEnabled()

    def test_create_class_and_student(self, app, store, teacher):
        dialog = StudentsDialog(store, teacher)
        classroom = dialog.create_class("5º A", "EMEF Centro", "5º ano")
        assert dialog.class_id == classroom.id

        dialog.new_name.setText("Ana Luiza Souza")
        dialog.new_birth.setText("09/03/2016")
        pin = dialog.add_student()
        auth.check_pin(pin)
        assert dialog.table.rowCount() == 1
        assert dialog.table.item(0, 0).text() == "Ana Luiza Souza"
        assert dialog.table.item(0, 2).text() == "09/03/2016"
        # O formulário fica limpo para o próximo aluno.
        assert dialog.new_name.text() == ""

    def test_pin_is_not_shown_in_the_table(self, app, store, teacher):
        dialog = StudentsDialog(store, teacher)
        dialog.create_class("5º A")
        dialog.new_name.setText("Ana")
        pin = dialog.add_student()
        cells = [
            dialog.table.item(0, column).text() for column in range(dialog.table.columnCount())
        ]
        assert pin not in cells

    def test_bad_birth_date_keeps_the_form(self, app, store, teacher):
        dialog = StudentsDialog(store, teacher)
        dialog.create_class("5º A")
        dialog.new_name.setText("Ana")
        dialog.new_birth.setText("2016-03-09")
        assert dialog.add_student() is None
        assert dialog.table.rowCount() == 0
        assert dialog.new_name.text() == "Ana"
        assert "dd/mm/aaaa" in dialog.error.text()

    def test_delete_student(self, app, store, teacher):
        dialog = StudentsDialog(store, teacher)
        dialog.create_class("5º A")
        dialog.new_name.setText("Ana")
        dialog.add_student()
        dialog.table.selectRow(0)
        student_id, name = dialog.selected_student()
        assert name == "Ana"
        dialog.delete_student(student_id)
        assert dialog.table.rowCount() == 0

    def test_export_roster(self, app, store, teacher, tmp_path):
        dialog = StudentsDialog(store, teacher)
        dialog.create_class("5º A")
        dialog.new_name.setText("Ana Luiza Souza")
        pin = dialog.add_student()
        path = dialog.export_roster(tmp_path / "turma.json")
        roster = json.loads(path.read_text(encoding="utf-8"))
        [entry] = roster["students"]
        assert entry["display_name"] == "Ana S."
        assert auth.verify_secret(pin, entry["pin_hash"])


class TestPanelWithDatabase:
    @pytest.fixture
    def filled(self, store, teacher):
        classroom = store.create_class(teacher, "5º A")
        codes = {}
        for index, name in enumerate(["Bruno Lima", "Ana Souza", "Caio Reis", "Duda Melo"]):
            code = store.add_student(teacher, classroom.id, name).student.code
            codes[name] = code
            store.import_session(
                teacher,
                make_payload(
                    code=code, overrides={"fixation_duration_mean": 0.2 + index / 50}
                ),
            )
        return codes

    def test_lists_students_by_name(self, app, store, teacher, filled):
        window = PanelWindow(store=store, teacher=teacher)
        items = window._class_list
        names = [items.item(row).text() for row in range(items.count())]
        assert [n.split("  ")[0] for n in names] == sorted(filled)

    def test_unknown_code_falls_back_to_code(self, app, store, teacher, filled):
        window = PanelWindow(store=store, teacher=teacher)
        assert window.display_name("ZZZZZZ") == "ZZZZZZ"

    def test_import_from_the_window(self, app, store, teacher, filled, tmp_path):
        classroom = store.classes(teacher)[0]
        code = store.add_student(teacher, classroom.id, "Eva Prado").student.code
        path = tmp_path / "eva.json"
        path.write_text(json.dumps(make_payload(code=code)))
        window = PanelWindow(store=store, teacher=teacher)
        report = window.import_files([path])
        assert report.imported == ["eva.json"]
        assert len(window._sessions) == 5

    def test_without_classes_explains_what_to_do(self, app, store, teacher):
        window = PanelWindow(store=store, teacher=teacher)
        assert "Alunos e turmas" in window._empty_message()

    def test_store_and_teacher_go_together(self, app, store):
        with pytest.raises(ValueError):
            PanelWindow(store=store)


class TestDescribeImport:
    def test_mentions_every_outcome(self):
        report = ImportReport(
            imported=["a.json"],
            duplicates=["b.json"],
            unknown_codes=["QQQQQQ"],
            unreadable=["c.json"],
        )
        text = describe_import(report)
        assert "1 sessão(ões) importada(s)" in text
        assert "já estavam" in text
        assert "QQQQQQ" in text
        assert "c.json" in text

    def test_clean_import_is_one_line(self):
        assert describe_import(ImportReport(imported=["a.json"])).count("\n") == 0
