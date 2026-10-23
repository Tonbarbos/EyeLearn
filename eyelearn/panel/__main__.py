"""Ponto de entrada do painel.

Uso::

    python -m eyelearn.panel                 # pede login; banco na pasta do usuário
    python -m eyelearn.panel --db ARQUIVO    # outro banco
    python -m eyelearn.panel PASTA           # demonstração: sessões soltas, sem banco
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PyQt6.QtWidgets import QApplication, QDialog

from eyelearn.panel.accounts import LoginDialog
from eyelearn.panel.main_window import PanelWindow
from eyelearn.storage.store import Store, default_database_path


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv if argv is None else argv
    parser = argparse.ArgumentParser(prog="python -m eyelearn.panel")
    parser.add_argument(
        "folder", nargs="?", type=Path,
        help="pasta de sessões para o modo de demonstração, sem banco nem login",
    )
    parser.add_argument(
        "--db", type=Path, default=None,
        help=f"arquivo do banco (padrão: {default_database_path()})",
    )
    args = parser.parse_args(argv[1:])

    app = QApplication(argv[:1])

    if args.folder is not None:
        window = PanelWindow(args.folder)
        window.show()
        return app.exec()

    store = Store.open(args.db)
    try:
        login = LoginDialog(store)
        if login.exec() != QDialog.DialogCode.Accepted or login.teacher is None:
            return 0
        window = PanelWindow(store=store, teacher=login.teacher)
        window.show()
        return app.exec()
    finally:
        store.close()


if __name__ == "__main__":
    raise SystemExit(main())
