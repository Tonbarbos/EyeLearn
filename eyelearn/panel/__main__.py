"""Ponto de entrada do painel.

Uso::

    python -m eyelearn.panel                 # abre vazio
    python -m eyelearn.panel PASTA           # já com uma turma carregada
"""

from __future__ import annotations

import sys
from pathlib import Path

from PyQt6.QtWidgets import QApplication

from eyelearn.panel.main_window import PanelWindow


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv if argv is None else argv
    folder = Path(argv[1]) if len(argv) > 1 else None

    app = QApplication(argv[:1])
    window = PanelWindow(folder)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
