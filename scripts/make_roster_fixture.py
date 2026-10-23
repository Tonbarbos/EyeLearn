"""Gera o pacote de turma de exemplo que a suíte Dart abre.

O link que o professor manda às famílias é cifrado pelo Python e aberto pelo
Dart, no navegador. Se os dois lados divergirem em qualquer detalhe --
derivação da chave, ordem dos bytes, dados associados da cifra, formato
compacto dos PINs --, nenhuma família consegue abrir a turma, e nenhum teste
de um lado só perceberia. Este arquivo é a fronteira entre os dois.

O arquivo leva, além do pacote cifrado, o código da turma, os PINs em claro e
o conteúdo esperado. É fixture: alunos fictícios. Sal e nonce são fixos para
o arquivo não mudar a cada execução.

Também gera a turma da pré-visualização no navegador, que é o mesmo pacote.

Uso::

    python scripts/make_roster_fixture.py
"""

from __future__ import annotations

import json
import sys
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from eyelearn.storage import package  # noqa: E402
from eyelearn.storage.store import Store  # noqa: E402

FIXTURE = REPOSITORY_ROOT / "mobile/eyelearn_core/assets/class_package_example.json"
DEMO = REPOSITORY_ROOT / "mobile" / "eyelearn_app" / "assets" / "demo_class.json"

STUDENTS = [
    ("Ana Luiza Souza", "2580"),
    ("Bruno Lima", "9031"),
    ("João da Silva", "4719"),
    ("Ana Souza Prado", "0862"),
]

#: Dia de referência do exemplo. A pré-visualização usa este dia como "hoje",
#: para as atividades aparecerem com os mesmos estados em qualquer data.
TODAY = date(2026, 10, 21)

CODE = "K7Q2XP4M"


def main() -> int:
    store = Store.open(":memory:")
    teacher = store.create_teacher("exemplo", "Professora Exemplo", "senha-de-exemplo")
    classroom = store.create_class(teacher, "5º A (exemplo)")
    pins = {}
    for name, pin in STUDENTS:
        new = store.add_student(teacher, classroom.id, name, pin=pin)
        pins[new.student.code] = pin

    # Uma atividade encerrada, duas abertas e uma que ainda não começou: os
    # quatro estados que o aplicativo mostra.
    opens = TODAY - timedelta(days=6)
    store.create_activity(teacher, classroom.id, "syllables", TODAY - timedelta(days=2),
                          opens=opens, today=opens)
    store.create_activity(teacher, classroom.id, "text", TODAY + timedelta(days=3),
                          opens=opens, today=opens)
    store.create_activity(teacher, classroom.id, "pseudotext", TODAY + timedelta(days=6),
                          opens=opens, today=opens)
    store.create_activity(teacher, classroom.id, "text", TODAY + timedelta(days=12),
                          opens=TODAY + timedelta(days=5), today=opens)

    now = datetime.combine(TODAY, datetime.min.time(), UTC)
    payload = store.class_package(teacher, classroom.id, now=now)
    store.close()

    sealed = package.seal(payload, CODE, salt=bytes(range(16)), nonce=bytes(range(12)))
    fixture = {
        "fragment": sealed,
        "code": package.format_code(CODE),
        "today": TODAY.isoformat(),
        "pins_for_tests": pins,
        "expected": payload,
    }
    text = json.dumps(fixture, ensure_ascii=False, indent=2) + "\n"
    for path in (FIXTURE, DEMO):
        path.write_text(text, encoding="utf-8")
        print(f"escrito: {path.relative_to(REPOSITORY_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
