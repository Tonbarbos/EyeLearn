"""Abre o painel, desenha e fecha.

Existe para a integração contínua. O gráfico e a comparação são verificados
sem Qt em `tests/test_panel.py`; o que falta é saber se a janela monta -- um
widget mal encaixado ou uma propriedade de estilo inválida só aparecem quando
alguém abre a janela de verdade.

Uso::

    xvfb-run -a python scripts/smoke_panel.py PASTA          # sem banco
    xvfb-run -a python scripts/smoke_panel.py --db BANCO     # com login

O banco é o que ``make_demo_class.py --db`` gera, com o login de demonstração.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PyQt6.QtCore import QTimer
from PyQt6.QtWidgets import QApplication

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.panel.accounts import LoginDialog, StudentsDialog  # noqa: E402
from eyelearn.panel.activity import HomeworkDialog  # noqa: E402
from eyelearn.panel.main_window import PanelWindow  # noqa: E402
from eyelearn.storage.store import Store  # noqa: E402


def main(argv: list[str]) -> int:
    app = QApplication(argv[:1])

    if len(argv) > 2 and argv[1] == "--db":
        store = Store.open(argv[2])
        login = LoginDialog(store)
        login.show()
        login.login_user.setText("demo")
        login.login_password.setText("demonstracao")
        login.submit_login()
        if login.teacher is None:
            print("login de demonstração recusado", file=sys.stderr)
            return 1
        window = PanelWindow(store=store, teacher=login.teacher)
        students = StudentsDialog(store, login.teacher, window._class_box.currentData())
        students.show()
        print(f"cadastro abriu: {students.table.rowCount()} alunos")
        class_id = window._class_box.currentData()
        homework = HomeworkDialog(store, login.teacher, class_id, "5º A")
        homework.show()
        homework.add_activity()
        print(f"atividades abriu: link de {len(homework.make_link())} caracteres")
        homework.close()
    else:
        folder = Path(argv[1]) if len(argv) > 1 else None
        window = PanelWindow(folder)
    window.resize(1280, 800)
    window.show()

    def exercise() -> None:
        # Percorre a turma inteira: cada seleção redesenha o gráfico e monta
        # os cartões de novo, que é onde um erro de montagem apareceria.
        for row in range(window._class_list.count()):
            window._class_list.setCurrentRow(row)

        # E as três tarefas, que refazem a comparação do zero.
        for index in range(window._task_box.count()):
            window._task_box.setCurrentIndex(index)

        print(
            f"painel abriu: {window._class_list.count()} itens na lista, "
            f"{window._task_box.count()} tarefas"
        )
        app.quit()

    QTimer.singleShot(1200, exercise)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
