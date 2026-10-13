"""Gera a lista de turma de exemplo que a suíte Dart verifica.

O PIN é conferido no celular contra o hash que o painel gravou. Se o PBKDF2 do
Dart divergisse do Python em qualquer detalhe -- codificação do PIN, ordem do
sal, tamanho da chave --, nenhuma criança conseguiria entrar, e nenhum teste de
um lado só perceberia. Este arquivo é a fronteira entre os dois.

O arquivo leva, além da lista, os PINs em claro (``pins_for_tests``). É
fixture: os alunos são fictícios, e o formato real exportado pelo painel não
tem esse campo.

Uso::

    python scripts/make_roster_fixture.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.storage.store import Store  # noqa: E402

FIXTURE = REPOSITORY_ROOT / "mobile" / "eyelearn_core" / "assets" / "roster_example.json"

#: A pré-visualização no navegador usa a mesma lista, e mostra os PINs na tela
#: para quem a experimenta. Copiada pelo mesmo motivo do modelo: o pacote Dart
#: puro não declara ativos Flutter.
DEMO_ROSTER = REPOSITORY_ROOT / "mobile" / "eyelearn_app" / "assets" / "demo_roster.json"

STUDENTS = [
    ("Ana Luiza Souza", "2580"),
    ("Bruno Lima", "9031"),
    ("João da Silva", "4719"),
    ("Ana Souza Prado", "0862"),
]


def main() -> int:
    store = Store.open(":memory:")
    teacher = store.create_teacher("exemplo", "Professora Exemplo", "senha-de-exemplo")
    classroom = store.create_class(teacher, "5º A (exemplo)")
    pins = {}
    for name, pin in STUDENTS:
        new = store.add_student(teacher, classroom.id, name, pin=pin)
        pins[new.student.code] = pin
    roster = store.roster(teacher, classroom.id)
    store.close()

    text = (
        json.dumps({"roster": roster, "pins_for_tests": pins}, ensure_ascii=False, indent=2)
        + "\n"
    )
    for path in (FIXTURE, DEMO_ROSTER):
        path.write_text(text, encoding="utf-8")
        print(f"escrito: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
