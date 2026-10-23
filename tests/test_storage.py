"""Testes da persistência: credenciais e migrações.

Segredo nunca em texto claro, PIN com limite de tentativas, migração atômica,
recusa de banco mais novo que o programa -- e, no repositório, o isolamento
entre professores e a exclusão em cascata que atende à LGPD.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import pytest

from eyelearn.storage import auth, db, package
from eyelearn.storage.schema import MIGRATIONS as SCHEMA
from eyelearn.storage.store import (
    CODE_ALPHABET,
    CODE_LENGTH,
    ROSTER_FORMAT,
    ROSTER_FORMAT_VERSION,
    AccountLockedError,
    ActivityMismatchError,
    NotFoundError,
    Store,
    display_names,
)
from tests.test_session import make_payload


class TestHashSecret:
    def test_roundtrip(self):
        stored = auth.hash_password("senha-do-prof")
        assert auth.verify_secret("senha-do-prof", stored)

    def test_wrong_secret_is_rejected(self):
        stored = auth.hash_password("senha-do-prof")
        assert not auth.verify_secret("senha-do-pro", stored)

    def test_secret_is_not_stored_in_clear(self):
        stored = auth.hash_password("2580")
        assert "2580" not in stored
        assert stored.startswith(f"{auth.SCHEME}$")

    def test_same_secret_gets_different_salts(self):
        # Sem sal próprio, dois alunos com o mesmo PIN teriam o mesmo hash, e
        # quem abrisse o banco veria quem divide PIN com quem.
        assert auth.hash_password("2580") != auth.hash_password("2580")

    def test_non_ascii_secret(self):
        stored = auth.hash_password("coração-ção")
        assert auth.verify_secret("coração-ção", stored)

    @pytest.mark.parametrize(
        "stored",
        [
            "",
            "texto-claro",
            "scrypt-v1$zz$00",
            "scrypt-v1$00",
            "md5$00$00",
            "scrypt-v1$00$00$00",
        ],
    )
    def test_malformed_hash_is_false_not_an_error(self, stored):
        # Registro corrompido não pode derrubar a tela de login, nem abrir.
        assert auth.verify_secret("qualquer", stored) is False


class TestPasswordRules:
    def test_accepts_reasonable_password(self):
        auth.check_password("professora2026")

    def test_rejects_short(self):
        with pytest.raises(auth.CredentialError):
            auth.check_password("a" * (auth.MIN_PASSWORD_LENGTH - 1))

    def test_minimum_length_is_inclusive(self):
        auth.check_password("a" * auth.MIN_PASSWORD_LENGTH)

    @pytest.mark.parametrize("password", [" professora", "professora "])
    def test_rejects_surrounding_spaces(self, password):
        # Espaço colado sem querer viraria senha que a pessoa nunca acerta.
        with pytest.raises(auth.CredentialError):
            auth.check_password(password)


class TestPinRules:
    @pytest.mark.parametrize("pin", ["2580", "0719", "9031"])
    def test_accepts(self, pin):
        auth.check_pin(pin)

    @pytest.mark.parametrize("pin", ["123", "12345", "12a4", "", "１２３４", "12³4"])
    def test_rejects_wrong_shape(self, pin):
        with pytest.raises(auth.CredentialError):
            auth.check_pin(pin)

    @pytest.mark.parametrize("pin", ["0000", "7777"])
    def test_rejects_repeated_digit(self, pin):
        with pytest.raises(auth.CredentialError):
            auth.check_pin(pin)

    @pytest.mark.parametrize("pin", ["1234", "6789", "4321", "9876", "0123"])
    def test_rejects_sequences(self, pin):
        with pytest.raises(auth.CredentialError):
            auth.check_pin(pin)

    def test_generated_pins_pass_the_rules(self):
        for _ in range(200):
            pin = auth.generate_pin()
            auth.check_pin(pin)
            assert len(pin) == auth.PIN_LENGTH


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


class TestAttemptLimiter:
    def make(self):
        clock = FakeClock()
        return auth.AttemptLimiter(max_failures=3, base_lockout_seconds=60, clock=clock), clock

    def test_not_locked_below_the_limit(self):
        limiter, _ = self.make()
        limiter.record_failure("ana")
        limiter.record_failure("ana")
        assert not limiter.is_locked("ana")

    def test_locks_at_the_limit(self):
        limiter, _ = self.make()
        for _ in range(3):
            limiter.record_failure("ana")
        assert limiter.is_locked("ana")
        assert limiter.seconds_locked("ana") == pytest.approx(60)

    def test_lock_expires(self):
        limiter, clock = self.make()
        for _ in range(3):
            limiter.record_failure("ana")
        clock.now += 60.01
        assert not limiter.is_locked("ana")

    def test_lockout_doubles(self):
        # Dobrar é o que torna as dez mil combinações inviáveis: a soma dos
        # bloqueios cresce exponencialmente com as rodadas.
        limiter, clock = self.make()
        for expected in (60, 120, 240):
            for _ in range(3):
                limiter.record_failure("ana")
            assert limiter.seconds_locked("ana") == pytest.approx(expected)
            clock.now += expected + 1

    def test_success_resets(self):
        limiter, clock = self.make()
        for _ in range(3):
            limiter.record_failure("ana")
        clock.now += 61
        limiter.record_success("ana")
        for _ in range(3):
            limiter.record_failure("ana")
        assert limiter.seconds_locked("ana") == pytest.approx(60)

    def test_keys_are_independent(self):
        # O erro de uma criança não pode bloquear a colega.
        limiter, _ = self.make()
        for _ in range(3):
            limiter.record_failure("ana")
        assert not limiter.is_locked("bruno")

    def test_unknown_key_is_not_locked(self):
        limiter, _ = self.make()
        assert limiter.seconds_locked("ninguem") == 0.0


MIGRATIONS = [
    "CREATE TABLE a (id INTEGER PRIMARY KEY);",
    "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER NOT NULL REFERENCES a(id));",
]


@pytest.fixture
def conn(tmp_path):
    connection = db.connect(tmp_path / "eyelearn.db")
    yield connection
    connection.close()


def tables(connection) -> set[str]:
    rows = connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    return {row["name"] for row in rows}


class TestConnect:
    def test_foreign_keys_are_on(self, conn):
        assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1

    def test_file_database_uses_wal(self, conn):
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"

    def test_memory_database_opens(self):
        connection = db.connect(":memory:")
        assert db.schema_version(connection) == 0
        connection.close()

    def test_rows_are_addressable_by_name(self, conn):
        assert conn.execute("SELECT 1 AS um").fetchone()["um"] == 1


class TestMigrate:
    def test_fresh_database_gets_every_migration(self, conn):
        assert db.migrate(conn, MIGRATIONS) == 2
        assert {"a", "b"} <= tables(conn)

    def test_is_idempotent(self, conn):
        db.migrate(conn, MIGRATIONS)
        assert db.migrate(conn, MIGRATIONS) == 2

    def test_applies_only_what_is_missing(self, conn):
        db.migrate(conn, MIGRATIONS[:1])
        conn.execute("INSERT INTO a (id) VALUES (7)")
        conn.commit()
        assert db.migrate(conn, MIGRATIONS) == 2
        # Os dados da versão anterior sobrevivem.
        assert conn.execute("SELECT id FROM a").fetchone()["id"] == 7

    def test_survives_reopening(self, tmp_path):
        path = tmp_path / "eyelearn.db"
        first = db.connect(path)
        db.migrate(first, MIGRATIONS)
        first.close()
        second = db.connect(path)
        assert db.schema_version(second) == 2
        second.close()

    def test_refuses_newer_database(self, conn):
        db.migrate(conn, MIGRATIONS)
        with pytest.raises(db.SchemaTooNewError, match="versão 2"):
            db.migrate(conn, MIGRATIONS[:1])

    def test_failed_migration_leaves_nothing_behind(self, conn):
        # A segunda instrução falha depois de a primeira já ter criado a
        # tabela: sem atomicidade o banco ficaria meio migrado e com a versão
        # antiga, e a próxima abertura tentaria criar a tabela de novo.
        broken = MIGRATIONS[:1] + ["CREATE TABLE c (id INTEGER); SELEC quebrado;"]
        with pytest.raises(sqlite3.Error):
            db.migrate(conn, broken)
        assert db.schema_version(conn) == 1
        assert "c" not in tables(conn)
        assert not conn.in_transaction

    def test_foreign_keys_are_enforced_after_migration(self, conn):
        db.migrate(conn, MIGRATIONS)
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute("INSERT INTO b (id, a_id) VALUES (1, 99)")


class TestPinHash:
    def test_roundtrip(self):
        assert auth.verify_secret("2580", auth.hash_pin("2580"))

    def test_wrong_pin(self):
        assert not auth.verify_secret("2581", auth.hash_pin("2580"))

    def test_carries_its_iterations(self):
        # O lado Dart lê as iterações do próprio hash; um valor fixo nos dois
        # lados divergiria na primeira mudança.
        stored = auth.hash_pin("2580", iterations=1234)
        assert stored.split("$")[1] == "1234"
        assert auth.verify_secret("2580", stored)

    def test_matches_the_standard_pbkdf2(self):
        # Vetor independente da nossa função: é o que o Dart vai reproduzir.
        salt = bytes(range(16))
        stored = auth.hash_pin("2580", iterations=1000, salt=salt)
        expected = hashlib.pbkdf2_hmac("sha256", b"2580", salt, 1000, 32).hex()
        assert stored == f"pbkdf2-sha256$1000${salt.hex()}${expected}"

    @pytest.mark.parametrize(
        "stored",
        ["pbkdf2-sha256$0$00$00", "pbkdf2-sha256$-5$00$00", "pbkdf2-sha256$x$00$00",
         "pbkdf2-sha256$99999999999$00$00", "pbkdf2-sha256$10$00"],
    )
    def test_malformed_is_false(self, stored):
        assert auth.verify_secret("2580", stored) is False


class TestSchema:
    def test_applies_cleanly(self, conn):
        assert db.migrate(conn, SCHEMA) == len(SCHEMA)
        assert {"professores", "turmas", "alunos", "sessoes"} <= tables(conn)

    def test_has_no_place_for_a_diagnosis(self, conn):
        # O banco anterior tinha uma tabela Diagnosticos com "Possível TDAH".
        # Este sistema não diagnostica, e não ter onde gravar o rótulo é a
        # garantia mais firme disso.
        db.migrate(conn, SCHEMA)
        columns = {
            column["name"]
            for table in tables(conn)
            for column in conn.execute(f"PRAGMA table_info({table})")
        }
        for name in tables(conn) | columns:
            assert "diagn" not in name.lower(), name
        assert "genero" not in columns

    def test_session_payload_must_be_json(self, conn):
        db.migrate(conn, SCHEMA)
        conn.execute(
            "INSERT INTO professores (usuario, nome, senha_hash) VALUES ('p', 'P', 'x')"
        )
        conn.execute("INSERT INTO turmas (professor_id, nome) VALUES (1, 'T')")
        conn.execute(
            "INSERT INTO alunos (turma_id, codigo, nome_completo, pin_hash)"
            " VALUES (1, 'AAAAAA', 'Ana', 'x')"
        )
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO sessoes (aluno_id, tarefa, iniciada_em, dados)"
                " VALUES (1, 'text', 'agora', 'não é json')"
            )


@pytest.fixture
def store(tmp_path):
    clock = FakeClock()
    opened = Store(
        db.connect(tmp_path / "painel.db"),
        limiter=auth.AttemptLimiter(max_failures=3, clock=clock),
    )
    opened.clock = clock
    yield opened
    opened.close()


@pytest.fixture
def teacher(store):
    return store.create_teacher("helena", "Helena Prado", "senha-boa-123")


@pytest.fixture
def classroom(store, teacher):
    return store.create_class(teacher, "5º A", school="EMEF Centro", grade="5º ano")


class TestTeachers:
    def test_starts_empty(self, store):
        assert not store.has_teachers()

    def test_login(self, store, teacher):
        assert store.authenticate("helena", "senha-boa-123") == teacher

    def test_username_is_case_insensitive(self, store, teacher):
        assert store.authenticate("  Helena ", "senha-boa-123") == teacher

    def test_wrong_password(self, store, teacher):
        assert store.authenticate("helena", "senha-errada") is None

    def test_unknown_user(self, store, teacher):
        assert store.authenticate("ninguem", "senha-boa-123") is None

    def test_password_is_not_stored_in_clear(self, store, teacher):
        raw = store.connection.execute("SELECT senha_hash FROM professores").fetchone()[0]
        assert "senha-boa-123" not in raw

    def test_duplicate_username(self, store, teacher):
        with pytest.raises(auth.CredentialError, match="já existe"):
            store.create_teacher("HELENA", "Outra", "outra-senha-1")

    def test_weak_password_refused(self, store):
        with pytest.raises(auth.CredentialError):
            store.create_teacher("joao", "João", "curta")

    def test_locks_after_failures(self, store, teacher):
        for _ in range(3):
            store.authenticate("helena", "errada!!")
        with pytest.raises(AccountLockedError):
            store.authenticate("helena", "senha-boa-123")
        store.clock.now += 61
        assert store.authenticate("helena", "senha-boa-123") == teacher

    def test_change_password(self, store, teacher):
        store.change_password(teacher, "senha-boa-123", "senha-nova-456")
        assert store.authenticate("helena", "senha-nova-456") == teacher
        assert store.authenticate("helena", "senha-boa-123") is None

    def test_change_password_needs_the_current_one(self, store, teacher):
        with pytest.raises(auth.CredentialError):
            store.change_password(teacher, "chute", "senha-nova-456")


class TestStudents:
    def test_add_returns_pin_once(self, store, teacher, classroom):
        new = store.add_student(teacher, classroom.id, "Ana Luiza Souza", "2016-03-09")
        auth.check_pin(new.pin)
        assert len(new.student.code) == CODE_LENGTH
        assert set(new.student.code) <= set(CODE_ALPHABET)
        raw = store.connection.execute("SELECT pin_hash FROM alunos").fetchone()[0]
        assert new.pin not in raw.split("$")
        assert auth.verify_secret(new.pin, raw)

    def test_chosen_pin(self, store, teacher, classroom):
        assert store.add_student(teacher, classroom.id, "Bruno", pin="2580").pin == "2580"

    def test_obvious_pin_refused(self, store, teacher, classroom):
        with pytest.raises(auth.CredentialError):
            store.add_student(teacher, classroom.id, "Bruno", pin="1234")

    def test_same_name_twice_in_a_class(self, store, teacher, classroom):
        store.add_student(teacher, classroom.id, "Ana  Souza")
        with pytest.raises(ValueError, match="nesta turma"):
            store.add_student(teacher, classroom.id, "Ana Souza")

    def test_birth_date_is_validated(self, store, teacher, classroom):
        with pytest.raises(ValueError):
            store.add_student(teacher, classroom.id, "Bruno", birth_date="31/02/2016")

    def test_listed_by_name(self, store, teacher, classroom):
        for name in ("Caio", "Ana", "Bruno"):
            store.add_student(teacher, classroom.id, name)
        names = [s.full_name for s in store.students(teacher, classroom.id)]
        assert names == ["Ana", "Bruno", "Caio"]

    def test_reset_pin(self, store, teacher, classroom):
        new = store.add_student(teacher, classroom.id, "Ana", pin="2580")
        assert store.reset_pin(teacher, new.student.id, "9031") == "9031"
        raw = store.connection.execute("SELECT pin_hash FROM alunos").fetchone()[0]
        assert auth.verify_secret("9031", raw)
        assert not auth.verify_secret("2580", raw)


class TestIsolationBetweenTeachers:
    """Um professor não vê nem altera o que é de outro."""

    @pytest.fixture
    def other(self, store):
        return store.create_teacher("marcos", "Marcos", "outra-senha-1")

    def test_classes_are_separate(self, store, teacher, classroom, other):
        assert store.classes(other) == []
        assert store.classes(teacher) == [classroom]

    @pytest.mark.parametrize(
        "operation",
        [
            lambda s, t, c, a: s.students(t, c),
            lambda s, t, c, a: s.add_student(t, c, "Intruso"),
            lambda s, t, c, a: s.sessions(t, c),
            lambda s, t, c, a: s.class_package(t, c),
            lambda s, t, c, a: s.share_link(t, c),
            lambda s, t, c, a: s.create_activity(t, c, "text", date.today()),
            lambda s, t, c, a: s.delete_class(t, c),
            lambda s, t, c, a: s.delete_student(t, a),
            lambda s, t, c, a: s.reset_pin(t, a),
            lambda s, t, c, a: s.import_session(t, make_payload(code=s_code(s, a))),
        ],
    )
    def test_other_teacher_is_refused(self, store, teacher, classroom, other, operation):
        student = store.add_student(teacher, classroom.id, "Ana").student
        with pytest.raises(NotFoundError):
            operation(store, other, classroom.id, student.id)
        # E nada mudou.
        assert store.students(teacher, classroom.id) == [student]


def s_code(store, student_id):
    return store.connection.execute(
        "SELECT codigo FROM alunos WHERE id = ?", (student_id,)
    ).fetchone()[0]


class TestSessions:
    def test_import_and_read_back(self, store, teacher, classroom):
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        assert store.import_session(teacher, make_payload(code=code))
        [session] = store.sessions(teacher, classroom.id)
        assert session.participant_code == code

    def test_reimport_is_ignored(self, store, teacher, classroom):
        # A mesma gravação contada duas vezes puxaria a média da turma.
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        assert store.import_session(teacher, make_payload(code=code))
        assert not store.import_session(teacher, make_payload(code=code))
        assert len(store.sessions(teacher, classroom.id)) == 1

    def test_unknown_code(self, store, teacher, classroom):
        with pytest.raises(NotFoundError):
            store.import_session(teacher, make_payload(code="ZZZZZZ"))

    def test_invalid_payload(self, store, teacher, classroom):
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        payload = make_payload(code=code)
        payload["format_version"] = 99
        with pytest.raises(ValueError):
            store.import_session(teacher, payload)

    def test_import_files_reports_each_outcome(self, store, teacher, classroom, tmp_path):
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        folder = tmp_path / "recebidas"
        folder.mkdir()
        (folder / "boa.json").write_text(json.dumps(make_payload(code=code)))
        (folder / "repetida.json").write_text(json.dumps(make_payload(code=code)))
        (folder / "outra.json").write_text(json.dumps(make_payload(code="QQQQQQ")))
        (folder / "quebrada.json").write_text("{")
        report = store.import_files(teacher, sorted(folder.glob("*.json")))
        assert report.imported == ["boa.json"]
        assert report.duplicates == ["repetida.json"]
        assert report.unknown_codes == ["QQQQQQ"]
        assert report.unreadable == ["quebrada.json"]

    def test_deleting_a_student_erases_their_sessions(self, store, teacher, classroom):
        # Pedido de eliminação (LGPD, art. 18): não pode sobrar sessão órfã.
        new = store.add_student(teacher, classroom.id, "Ana")
        store.import_session(teacher, make_payload(code=new.student.code))
        store.delete_student(teacher, new.student.id)
        assert store.connection.execute("SELECT count(*) FROM sessoes").fetchone()[0] == 0

    def test_deleting_a_class_erases_everything_in_it(self, store, teacher, classroom):
        new = store.add_student(teacher, classroom.id, "Ana")
        store.import_session(teacher, make_payload(code=new.student.code))
        store.delete_class(teacher, classroom.id)
        for table in ("turmas", "alunos", "sessoes"):
            assert store.connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 0


class TestDisplayNames:
    def test_first_name_and_initial(self):
        assert display_names(["Ana Luiza Souza", "Bruno"]) == ["Ana S.", "Bruno"]

    def test_collisions_fall_back_to_full_name(self):
        names = ["Ana Souza", "Ana Silva", "Bruno Lima"]
        assert display_names(names) == ["Ana Souza", "Ana Silva", "Bruno L."]

    def test_lowercase_surname(self):
        assert display_names(["joão da silva"]) == ["joão S."]


class TestOpen:
    def test_creates_the_folder(self, tmp_path):
        path = tmp_path / "nao" / "existe" / "eyelearn.db"
        opened = Store.open(path)
        opened.close()
        assert path.exists()

    def test_reopening_keeps_the_data(self, tmp_path):
        path = tmp_path / "eyelearn.db"
        first = Store.open(path)
        first.create_teacher("helena", "Helena", "senha-boa-123")
        first.close()
        second = Store.open(path)
        assert second.has_teachers()
        second.close()


TODAY = date(2026, 10, 20)


class TestPackageCipher:
    PAYLOAD = {"class_name": "5º A", "students": [["ABC234", "Ana S.", "x", "y"]]}

    def test_roundtrip(self):
        sealed = package.seal(self.PAYLOAD, "K7Q2XP4M")
        assert package.open_sealed(sealed, "K7Q2XP4M") == self.PAYLOAD

    def test_code_is_forgiving_about_case_and_hyphen(self):
        sealed = package.seal(self.PAYLOAD, "K7Q2XP4M")
        assert package.open_sealed(sealed, " k7q2-xp4m ") == self.PAYLOAD

    def test_wrong_code(self):
        sealed = package.seal(self.PAYLOAD, "K7Q2XP4M")
        with pytest.raises(package.PackageError, match="código"):
            package.open_sealed(sealed, "K7Q2XP4N")

    def test_tampering_is_detected(self):
        # GCM autentica: um bit trocado no link não abre um pacote alterado.
        sealed = package.seal(self.PAYLOAD, "K7Q2XP4M")
        flipped = sealed[:-5] + ("A" if sealed[-5] != "A" else "B") + sealed[-4:]
        with pytest.raises(package.PackageError):
            package.open_sealed(flipped, "K7Q2XP4M")

    @pytest.mark.parametrize("text", ["", "!!!", "AAAA"])
    def test_garbage(self, text):
        with pytest.raises(package.PackageError):
            package.open_sealed(text, "K7Q2XP4M")

    def test_names_are_not_readable_in_the_link(self):
        sealed = package.seal({"nome": "Ana Luiza Souza"}, "K7Q2XP4M")
        import base64

        raw = base64.urlsafe_b64decode(sealed + "=" * (-len(sealed) % 4))
        assert b"Ana" not in raw

    def test_each_seal_differs(self):
        # Sal e nonce novos a cada vez: o mesmo pacote cifrado duas vezes não
        # se repete, e um nonce nunca é reaproveitado com a mesma chave.
        assert package.seal(self.PAYLOAD, "K7Q2XP4M") != package.seal(self.PAYLOAD, "K7Q2XP4M")

    def test_format_code(self):
        assert package.format_code("k7q2xp4m") == "K7Q2-XP4M"
        assert package.normalize_code("ç-k7") == "K7"


class TestHomework:
    def test_create_and_list_by_due_date(self, store, teacher, classroom):
        later = store.create_activity(teacher, classroom.id, "text", TODAY + timedelta(7),
                                      today=TODAY)
        sooner = store.create_activity(teacher, classroom.id, "syllables",
                                       TODAY + timedelta(2), today=TODAY)
        assert store.activities(teacher, classroom.id) == [sooner, later]
        assert sooner.opens_on == TODAY

    def test_due_is_end_of_day_local(self, store, teacher, classroom):
        activity = store.create_activity(teacher, classroom.id, "text", TODAY, today=TODAY)
        local = activity.due_at
        assert (local.hour, local.minute, local.second) == (23, 59, 59)
        assert local.tzinfo is not None

    def test_rejects_past_due(self, store, teacher, classroom):
        with pytest.raises(ValueError, match="passou"):
            store.create_activity(teacher, classroom.id, "text", TODAY - timedelta(1),
                                  today=TODAY)

    def test_rejects_due_before_opening(self, store, teacher, classroom):
        with pytest.raises(ValueError, match="antes"):
            store.create_activity(teacher, classroom.id, "text", TODAY + timedelta(1),
                                  opens=TODAY + timedelta(3), today=TODAY)

    def test_rejects_unknown_task(self, store, teacher, classroom):
        with pytest.raises(ValueError, match="tarefa"):
            store.create_activity(teacher, classroom.id, "desenho", TODAY, today=TODAY)

    def test_delete(self, store, teacher, classroom):
        activity = store.create_activity(teacher, classroom.id, "text", TODAY, today=TODAY)
        store.delete_activity(teacher, activity.id)
        assert store.activities(teacher, classroom.id) == []

    def test_other_teacher_cannot_delete(self, store, teacher, classroom):
        activity = store.create_activity(teacher, classroom.id, "text", TODAY, today=TODAY)
        other = store.create_teacher("marcos", "Marcos", "outra-senha-1")
        with pytest.raises(NotFoundError):
            store.delete_activity(other, activity.id)
        assert store.activities(teacher, classroom.id) == [activity]

    def test_session_is_linked_to_its_activity(self, store, teacher, classroom):
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        activity = store.create_activity(teacher, classroom.id, "text", TODAY, today=TODAY)
        payload = make_payload(code=code) | {"activity_code": activity.code}
        assert store.import_session(teacher, payload)
        assert store.completed_activity_codes(teacher, classroom.id) == {
            activity.code: {code}
        }

    def test_activity_of_another_class_is_refused(self, store, teacher, classroom):
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        other = store.create_class(teacher, "5º B")
        foreign = store.create_activity(teacher, other.id, "text", TODAY, today=TODAY)
        payload = make_payload(code=code) | {"activity_code": foreign.code}
        with pytest.raises(ActivityMismatchError):
            store.import_session(teacher, payload)

    def test_activity_of_another_task_is_refused(self, store, teacher, classroom):
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        activity = store.create_activity(teacher, classroom.id, "syllables", TODAY,
                                         today=TODAY)
        payload = make_payload(code=code, task="text") | {"activity_code": activity.code}
        with pytest.raises(ActivityMismatchError):
            store.import_session(teacher, payload)

    def test_import_report_counts_wrong_activity(self, store, teacher, classroom, tmp_path):
        code = store.add_student(teacher, classroom.id, "Ana").student.code
        path = tmp_path / "s.json"
        path.write_text(json.dumps(make_payload(code=code) | {"activity_code": "NAOEXISTE"}))
        report = store.import_files(teacher, [path])
        assert report.wrong_activity == ["s.json"]
        assert report.imported == []

    def test_deleting_the_class_deletes_its_activities(self, store, teacher, classroom):
        store.create_activity(teacher, classroom.id, "text", TODAY, today=TODAY)
        store.delete_class(teacher, classroom.id)
        assert store.connection.execute("SELECT count(*) FROM atividades").fetchone()[0] == 0


class TestClassPackage:
    def test_carries_only_what_home_needs(self, store, teacher, classroom):
        store.add_student(teacher, classroom.id, "Ana Luiza Souza", "2016-03-09", pin="2580")
        store.create_activity(teacher, classroom.id, "text", TODAY + timedelta(3),
                              today=TODAY)
        pack = store.class_package(teacher, classroom.id)
        assert pack["format"] == ROSTER_FORMAT
        assert pack["format_version"] == ROSTER_FORMAT_VERSION
        [[code, name, salt, key]] = pack["students"]
        assert name == "Ana S."
        text = json.dumps(pack, ensure_ascii=False)
        assert "Luiza" not in text and "2016" not in text
        [[_, task, opens, due]] = pack["activities"]
        assert task == "text" and opens == TODAY.isoformat()

    def test_compact_pin_rebuilds_the_hash(self, store, teacher, classroom):
        # O aplicativo remonta "pbkdf2-sha256$it$sal$chave" a partir do pacote.
        store.add_student(teacher, classroom.id, "Ana", pin="2580")
        pack = store.class_package(teacher, classroom.id)
        [[_, _, salt, key]] = pack["students"]
        import base64

        def unb64(text):
            return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)).hex()

        rebuilt = f"pbkdf2-sha256${pack['pin_iterations']}${unb64(salt)}${unb64(key)}"
        assert auth.verify_secret("2580", rebuilt)

    def test_long_closed_activities_are_left_out(self, store, teacher, classroom):
        store.create_activity(teacher, classroom.id, "text", TODAY, today=TODAY)
        later = datetime.combine(TODAY + timedelta(30), datetime.min.time(), UTC)
        assert store.class_package(teacher, classroom.id, now=later)["activities"] == []
        soon = datetime.combine(TODAY + timedelta(5), datetime.min.time(), UTC)
        assert len(store.class_package(teacher, classroom.id, now=soon)["activities"]) == 1

    def test_link_opens_with_the_code(self, store, teacher, classroom):
        store.add_student(teacher, classroom.id, "Ana")
        shared = store.share_link(teacher, classroom.id, base_url="https://exemplo.org/app/")
        assert shared.url.startswith("https://exemplo.org/app/#t=")
        sealed = shared.url.split("#t=", 1)[1]
        assert package.open_sealed(sealed, shared.access_code)["class_name"] == "5º A"

    def test_code_is_stable_until_renewed(self, store, teacher, classroom):
        first = store.access_code(teacher, classroom.id)
        assert store.access_code(teacher, classroom.id) == first
        renewed = store.new_access_code(teacher, classroom.id)
        assert renewed != first and len(renewed) == package.ACCESS_CODE_LENGTH

    def test_renewed_code_locks_old_links(self, store, teacher, classroom):
        old = store.share_link(teacher, classroom.id)
        store.new_access_code(teacher, classroom.id)
        sealed = old.url.split("#t=", 1)[1]
        new_code = store.access_code(teacher, classroom.id)
        with pytest.raises(package.PackageError):
            package.open_sealed(sealed, new_code)

    def test_link_size_for_a_full_class(self, store, teacher, classroom):
        # 35 alunos e 6 atividades: o link precisa caber numa mensagem de
        # WhatsApp e no endereço de qualquer navegador.
        for index in range(35):
            store.add_student(teacher, classroom.id, f"Aluno Número{index:02d} Silva")
        for offset in range(6):
            store.create_activity(teacher, classroom.id, "text", TODAY + timedelta(offset),
                                  today=TODAY)
        assert len(store.share_link(teacher, classroom.id).url) < 8000


class TestUpgradeFromOlderVersions:
    def test_existing_classes_work_after_upgrade(self, tmp_path):
        # Banco criado na versão 1, com turma: abre na versão atual, ganha
        # identificador e passa a ter código de acesso e atividades de casa.
        path = tmp_path / "antigo.db"
        connection = db.connect(path)
        db.migrate(connection, SCHEMA[:1])
        connection.execute(
            "INSERT INTO professores (usuario, nome, senha_hash) VALUES (?, ?, ?)",
            ("helena", "Helena", auth.hash_password("senha-boa-123")),
        )
        connection.execute("INSERT INTO turmas (professor_id, nome) VALUES (1, '5º A')")
        connection.commit()
        connection.close()

        upgraded = Store.open(path)
        teacher = upgraded.authenticate("helena", "senha-boa-123")
        [classroom] = upgraded.classes(teacher)
        assert len(upgraded.class_package(teacher, classroom.id)["class_uid"]) == 16
        upgraded.create_activity(teacher, classroom.id, "text", date.today())
        assert upgraded.share_link(teacher, classroom.id).access_code
        upgraded.close()

    def test_version_2_activities_still_read(self, tmp_path):
        # Atividades de QR da versão 2 gravavam instante, não dia.
        path = tmp_path / "v2.db"
        connection = db.connect(path)
        db.migrate(connection, SCHEMA[:2])
        connection.execute(
            "INSERT INTO professores (usuario, nome, senha_hash) VALUES (?, ?, ?)",
            ("helena", "Helena", auth.hash_password("senha-boa-123")),
        )
        connection.execute(
            "INSERT INTO turmas (professor_id, nome, uid) VALUES (1, 'A', 'u1')"
        )
        connection.execute(
            "INSERT INTO atividades (turma_id, codigo, tarefa, aberta_em, expira_em)"
            " VALUES (1, 'X', 'text', '2026-10-13T10:00:00+00:00',"
            " '2026-10-13T10:15:00+00:00')"
        )
        connection.commit()
        connection.close()
        upgraded = Store.open(path)
        teacher = upgraded.authenticate("helena", "senha-boa-123")
        [activity] = upgraded.activities(teacher, 1)
        assert activity.opens_on == date(2026, 10, 13)
        upgraded.close()


class TestPackageFixture:
    """O pacote de exemplo que a suíte Dart abre (scripts/make_roster_fixture.py)."""

    FIXTURE = (
        Path(__file__).resolve().parent.parent
        / "mobile/eyelearn_core/assets/class_package_example.json"
    )

    def load(self):
        return json.loads(self.FIXTURE.read_text(encoding="utf-8"))

    def test_opens_with_its_code(self):
        fixture = self.load()
        assert package.open_sealed(fixture["fragment"], fixture["code"]) == fixture["expected"]

    def test_is_in_the_current_format(self):
        expected = self.load()["expected"]
        assert expected["format"] == ROSTER_FORMAT
        assert expected["format_version"] == ROSTER_FORMAT_VERSION

    def test_pins_match(self):
        import base64

        fixture = self.load()
        expected = fixture["expected"]

        def unb64(text):
            return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)).hex()

        for code, _, salt, key in expected["students"]:
            stored = f"pbkdf2-sha256${expected['pin_iterations']}${unb64(salt)}${unb64(key)}"
            assert auth.verify_secret(fixture["pins_for_tests"][code], stored)
