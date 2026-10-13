"""Abre o painel, desenha e fecha.

Existe para a integração contínua. O gráfico e a comparação são verificados
sem Qt em `tests/test_panel.py`; o que falta é saber se a janela monta -- um
widget mal encaixado ou uma propriedade de estilo inválida só aparecem quando
alguém abre a janela de verdade.

Uso::

    xvfb-run -a python scripts/smoke_panel.py PASTA
"""

from __future__ import annotations

import sys
from pathlib import Path

from PyQt6.QtCore import QTimer
from PyQt6.QtWidgets import QApplication

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.panel.main_window import PanelWindow  # noqa: E402


def main(argv: list[str]) -> int:
    folder = Path(argv[1]) if len(argv) > 1 else None

    app = QApplication(argv[:1])
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
