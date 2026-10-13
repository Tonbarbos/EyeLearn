"""Operações do painel sobre o banco: professores, turmas, alunos, sessões.

Toda operação sobre turma, aluno ou sessão recebe o professor que a pede e
confere que o registro é dele. O banco fica num computador que pode ser da
escola e servir a mais de um professor, e um não pode ver os alunos do outro.
"""

from __future__ import annotations

import functools
import json
import os
import secrets
import sqlite3
import sys
from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from eyelearn.session import Session, session_from_dict
from eyelearn.storage import auth, db
from eyelearn.storage.schema import MIGRATIONS

#: Alfabeto do código do aluno: sem 0/O, 1/I/L, que se confundem quando o
#: professor lê o código em voz alta ou o copia de um papel.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 6

ROSTER_FORMAT = "eyelearn-turma"
ROSTER_FORMAT_VERSION = 1


@functools.cache
def _dummy_password_hash() -> str:
    """Hash de referência para quando o usuário não existe.

    Verificar contra ele gasta o mesmo tempo que verificar contra um hash real:
    sem isso, a demora da resposta diria a quem tenta se o usuário existe.
    """
    return auth.hash_password(secrets.token_hex(16))


class NotFoundError(LookupError):
    """O registro não existe, ou não pertence a este professor.

    Os dois casos dão o mesmo erro de propósito: distinguir diria a um
    professor que o aluno de código tal existe na turma de outro.
    """


class AccountLockedError(RuntimeError):
    def __init__(self, seconds: float) -> None:
        super().__init__(
            f"muitas tentativas erradas; tente de novo em {int(seconds) + 1} s"
        )
        self.seconds = seconds


@dataclass(frozen=True)
class Teacher:
    id: int
    username: str
    name: str


@dataclass(frozen=True)
class Classroom:
    id: int
    name: str
    school: str | None
    grade: str | None


@dataclass(frozen=True)
class Student:
    id: int
    class_id: int
    code: str
    full_name: str
    birth_date: str | None


@dataclass(frozen=True)
class NewStudent:
    """Aluno recém-cadastrado, com o PIN em claro.

    É a única vez que o PIN aparece legível: o painel mostra ao professor para
    ele entregar à criança, e depois só existe o hash.
    """

    student: Student
    pin: str


@dataclass
class ImportReport:
    imported: list[str] = field(default_factory=list)
    duplicates: list[str] = field(default_factory=list)
    unknown_codes: list[str] = field(default_factory=list)
    unreadable: list[str] = field(default_factory=list)


def default_database_path() -> Path:
    """Onde o banco fica, por sistema: na pasta de dados do usuário."""
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
        return base / "EyeLearn" / "eyelearn.db"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "EyeLearn" / "eyelearn.db"
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "eyelearn" / "eyelearn.db"


def display_names(full_names: list[str]) -> list[str]:
    """Nome que aparece na tela de escolha do celular.

    Primeiro nome e inicial do último ("Ana Luiza Souza" -> "Ana S."): o
    suficiente para a criança se achar, sem levar o nome completo para o
    aparelho. Onde dois colegas colidiriam, os dois ficam com o nome completo
    -- o banco já garante que o nome completo é único na turma.
    """

    def short(name: str) -> str:
        parts = name.split()
        if len(parts) == 1:
            return parts[0]
        return f"{parts[0]} {parts[-1][0].upper()}."

    shorts = [short(name) for name in full_names]
    return [
        " ".join(name.split()) if shorts.count(abbreviated) > 1 else abbreviated
        for name, abbreviated in zip(full_names, shorts, strict=True)
    ]


class Store:
    """O banco do painel, já migrado."""

    def __init__(
        self,
        connection: sqlite3.Connection,
        limiter: auth.AttemptLimiter | None = None,
    ) -> None:
        self.connection = connection
        db.migrate(connection, MIGRATIONS)
        self.limiter = limiter or auth.AttemptLimiter()

    @classmethod
    def open(cls, path: Path | str | None = None) -> Store:
        path = default_database_path() if path is None else Path(path)
        if str(path) != ":memory:":
            path.parent.mkdir(parents=True, exist_ok=True)
        return cls(db.connect(path))

    def close(self) -> None:
        self.connection.close()

    # -- professores ---------------------------------------------------------

    def has_teachers(self) -> bool:
        """Se já há professor cadastrado. Sem nenhum, o painel abre o cadastro."""
        row = self.connection.execute("SELECT 1 FROM professores LIMIT 1").fetchone()
        return row is not None

    def create_teacher(self, username: str, name: str, password: str) -> Teacher:
        username, name = username.strip(), " ".join(name.split())
        if not username or not name:
            raise auth.CredentialError("usuário e nome são obrigatórios")
        auth.check_password(password)
        try:
            with self.connection:
                cursor = self.connection.execute(
                    "INSERT INTO professores (usuario, nome, senha_hash) VALUES (?, ?, ?)",
                    (username, name, auth.hash_password(password)),
                )
        except sqlite3.IntegrityError as error:
            raise auth.CredentialError(f"o usuário {username!r} já existe") from error
        return Teacher(cursor.lastrowid, username, name)

    def authenticate(self, username: str, password: str) -> Teacher | None:
        """O professor, se usuário e senha conferem; ``None`` se não.

        Raises:
            AccountLockedError: depois de tentativas erradas demais.
        """
        key = username.strip().casefold()
        if self.limiter.is_locked(key):
            raise AccountLockedError(self.limiter.seconds_locked(key))

        row = self.connection.execute(
            "SELECT id, usuario, nome, senha_hash FROM professores WHERE usuario = ?",
            (username.strip(),),
        ).fetchone()
        stored = row["senha_hash"] if row else _dummy_password_hash()
        if auth.verify_secret(password, stored) and row is not None:
            self.limiter.record_success(key)
            return Teacher(row["id"], row["usuario"], row["nome"])

        self.limiter.record_failure(key)
        return None

    def change_password(self, teacher: Teacher, current: str, new: str) -> None:
        row = self.connection.execute(
            "SELECT senha_hash FROM professores WHERE id = ?", (teacher.id,)
        ).fetchone()
        if row is None or not auth.verify_secret(current, row["senha_hash"]):
            raise auth.CredentialError("a senha atual não confere")
        auth.check_password(new)
        with self.connection:
            self.connection.execute(
                "UPDATE professores SET senha_hash = ? WHERE id = ?",
                (auth.hash_password(new), teacher.id),
            )

    # -- turmas --------------------------------------------------------------

    def create_class(
        self,
        teacher: Teacher,
        name: str,
        school: str | None = None,
        grade: str | None = None,
    ) -> Classroom:
        name = " ".join(name.split())
        try:
            with self.connection:
                cursor = self.connection.execute(
                    "INSERT INTO turmas (professor_id, nome, escola, serie)"
                    " VALUES (?, ?, ?, ?)",
                    (teacher.id, name, school or None, grade or None),
                )
        except sqlite3.IntegrityError as error:
            raise ValueError(f"a turma {name!r} já existe ou está sem nome") from error
        return Classroom(cursor.lastrowid, name, school or None, grade or None)

    def classes(self, teacher: Teacher) -> list[Classroom]:
        rows = self.connection.execute(
            "SELECT id, nome, escola, serie FROM turmas WHERE professor_id = ? ORDER BY nome",
            (teacher.id,),
        )
        return [Classroom(r["id"], r["nome"], r["escola"], r["serie"]) for r in rows]

    def delete_class(self, teacher: Teacher, class_id: int) -> None:
        """Apaga a turma, os alunos e as sessões deles."""
        self._own_class(teacher, class_id)
        with self.connection:
            self.connection.execute("DELETE FROM turmas WHERE id = ?", (class_id,))

    # -- alunos --------------------------------------------------------------

    def add_student(
        self,
        teacher: Teacher,
        class_id: int,
        full_name: str,
        birth_date: date | str | None = None,
        pin: str | None = None,
    ) -> NewStudent:
        """Cadastra o aluno. Sem ``pin``, o sistema sorteia um."""
        self._own_class(teacher, class_id)
        full_name = " ".join(full_name.split())
        if not full_name:
            raise ValueError("o nome do aluno é obrigatório")
        pin = auth.generate_pin() if pin is None else pin
        auth.check_pin(pin)
        birth = _iso_date(birth_date)

        for _ in range(20):
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
            try:
                with self.connection:
                    cursor = self.connection.execute(
                        "INSERT INTO alunos (turma_id, codigo, nome_completo, data_nascimento,"
                        " pin_hash) VALUES (?, ?, ?, ?, ?)",
                        (class_id, code, full_name, birth, auth.hash_pin(pin)),
                    )
            except sqlite3.IntegrityError as error:
                if "codigo" in str(error):
                    continue  # colisão de código: sorteia outro
                raise ValueError(f"já há {full_name!r} nesta turma") from error
            student = Student(cursor.lastrowid, class_id, code, full_name, birth)
            return NewStudent(student, pin)
        raise RuntimeError("não foi possível gerar um código único")  # pragma: no cover

    def students(self, teacher: Teacher, class_id: int) -> list[Student]:
        self._own_class(teacher, class_id)
        rows = self.connection.execute(
            "SELECT id, turma_id, codigo, nome_completo, data_nascimento FROM alunos"
            " WHERE turma_id = ? ORDER BY nome_completo",
            (class_id,),
        )
        return [_student(row) for row in rows]

    def reset_pin(self, teacher: Teacher, student_id: int, pin: str | None = None) -> str:
        """Troca o PIN do aluno e devolve o novo, em claro, uma vez."""
        self._own_student(teacher, student_id)
        pin = auth.generate_pin() if pin is None else pin
        auth.check_pin(pin)
        with self.connection:
            self.connection.execute(
                "UPDATE alunos SET pin_hash = ? WHERE id = ?", (auth.hash_pin(pin), student_id)
            )
        return pin

    def delete_student(self, teacher: Teacher, student_id: int) -> None:
        """Apaga o aluno e todas as sessões dele.

        É o que atende ao pedido de eliminação dos dados (LGPD, art. 18, VI):
        não fica sessão órfã com o código da criança.
        """
        self._own_student(teacher, student_id)
        with self.connection:
            self.connection.execute("DELETE FROM alunos WHERE id = ?", (student_id,))

    # -- sessões -------------------------------------------------------------

    def import_session(self, teacher: Teacher, payload: dict[str, Any]) -> bool:
        """Grava a sessão no aluno do código dela.

        Returns:
            ``True`` se gravou, ``False`` se a mesma gravação já estava lá.

        Raises:
            ValueError: se o formato for inválido (validado por
                :func:`eyelearn.session.session_from_dict`).
            NotFoundError: se o código não for de aluno deste professor.
        """
        session = session_from_dict(payload)
        row = self.connection.execute(
            "SELECT a.id FROM alunos a JOIN turmas t ON t.id = a.turma_id"
            " WHERE a.codigo = ? AND t.professor_id = ?",
            (session.participant_code, teacher.id),
        ).fetchone()
        if row is None:
            raise NotFoundError(session.participant_code)
        with self.connection:
            cursor = self.connection.execute(
                "INSERT OR IGNORE INTO sessoes (aluno_id, tarefa, iniciada_em, dados)"
                " VALUES (?, ?, ?, ?)",
                (row["id"], session.task, session.started_at, json.dumps(payload)),
            )
        return cursor.rowcount == 1

    def import_files(self, teacher: Teacher, paths: list[Path]) -> ImportReport:
        """Importa vários arquivos sem parar no primeiro problema.

        Mesma regra de :func:`eyelearn.session.load_sessions`: perder onze
        sessões boas por causa de uma ruim seria o pior resultado. O relatório
        diz o que aconteceu com cada uma.
        """
        report = ImportReport()
        for path in paths:
            try:
                payload = json.loads(Path(path).read_text(encoding="utf-8"))
                if self.import_session(teacher, payload):
                    report.imported.append(Path(path).name)
                else:
                    report.duplicates.append(Path(path).name)
            except NotFoundError as error:
                report.unknown_codes.append(str(error.args[0]))
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                report.unreadable.append(Path(path).name)
        return report

    def sessions(self, teacher: Teacher, class_id: int) -> list[Session]:
        self._own_class(teacher, class_id)
        rows = self.connection.execute(
            "SELECT s.dados FROM sessoes s JOIN alunos a ON a.id = s.aluno_id"
            " WHERE a.turma_id = ? ORDER BY s.iniciada_em",
            (class_id,),
        )
        return [session_from_dict(json.loads(row["dados"])) for row in rows]

    def student_by_code(self, teacher: Teacher, code: str) -> Student:
        row = self.connection.execute(
            "SELECT a.id, a.turma_id, a.codigo, a.nome_completo, a.data_nascimento"
            " FROM alunos a JOIN turmas t ON t.id = a.turma_id"
            " WHERE a.codigo = ? AND t.professor_id = ?",
            (code, teacher.id),
        ).fetchone()
        if row is None:
            raise NotFoundError(code)
        return _student(row)

    # -- lista da turma para o celular ---------------------------------------

    def roster(self, teacher: Teacher, class_id: int) -> dict[str, Any]:
        """A lista que o celular usa para o login do aluno.

        Leva nome de exibição, código e hash do PIN -- nada mais. Data de
        nascimento e nome completo ficam no computador.
        """
        classroom = self._own_class(teacher, class_id)
        students = self.students(teacher, class_id)
        hashes = dict(
            self.connection.execute(
                "SELECT id, pin_hash FROM alunos WHERE turma_id = ?", (class_id,)
            ).fetchall()
        )
        names = display_names([s.full_name for s in students])
        return {
            "format": ROSTER_FORMAT,
            "format_version": ROSTER_FORMAT_VERSION,
            "class_name": classroom.name,
            "exported_at": datetime.now(UTC).isoformat(timespec="seconds"),
            "students": sorted(
                (
                    {"code": s.code, "display_name": name, "pin_hash": hashes[s.id]}
                    for s, name in zip(students, names, strict=True)
                ),
                key=lambda entry: entry["display_name"].casefold(),
            ),
        }

    # -- auxiliares ----------------------------------------------------------

    def _own_class(self, teacher: Teacher, class_id: int) -> Classroom:
        row = self.connection.execute(
            "SELECT id, nome, escola, serie FROM turmas WHERE id = ? AND professor_id = ?",
            (class_id, teacher.id),
        ).fetchone()
        if row is None:
            raise NotFoundError(f"turma {class_id}")
        return Classroom(row["id"], row["nome"], row["escola"], row["serie"])

    def _own_student(self, teacher: Teacher, student_id: int) -> None:
        row = self.connection.execute(
            "SELECT 1 FROM alunos a JOIN turmas t ON t.id = a.turma_id"
            " WHERE a.id = ? AND t.professor_id = ?",
            (student_id, teacher.id),
        ).fetchone()
        if row is None:
            raise NotFoundError(f"aluno {student_id}")


def _student(row: sqlite3.Row) -> Student:
    return Student(
        row["id"], row["turma_id"], row["codigo"], row["nome_completo"], row["data_nascimento"]
    )


def _iso_date(value: date | str | None) -> str | None:
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value.isoformat()
    return date.fromisoformat(value).isoformat()
