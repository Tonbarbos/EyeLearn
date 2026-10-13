"""Testes da persistência: credenciais e migrações.

As tabelas ainda não estão definidas -- o esquema vai seguir o do projeto
anterior. O que se testa aqui é o que vale para qualquer esquema: segredo
nunca em texto claro, PIN com limite de tentativas, migração atômica e
recusa de banco mais novo que o programa.
"""

from __future__ import annotations

import sqlite3

import pytest

from eyelearn.storage import auth, db


class TestHashSecret:
    def test_roundtrip(self):
        stored = auth.hash_secret("senha-do-prof")
        assert auth.verify_secret("senha-do-prof", stored)

    def test_wrong_secret_is_rejected(self):
        stored = auth.hash_secret("senha-do-prof")
        assert not auth.verify_secret("senha-do-pro", stored)

    def test_secret_is_not_stored_in_clear(self):
        stored = auth.hash_secret("2580")
        assert "2580" not in stored
        assert stored.startswith(f"{auth.SCHEME}$")

    def test_same_secret_gets_different_salts(self):
        # Sem sal próprio, dois alunos com o mesmo PIN teriam o mesmo hash, e
        # quem abrisse o banco veria quem divide PIN com quem.
        assert auth.hash_secret("2580") != auth.hash_secret("2580")

    def test_non_ascii_secret(self):
        stored = auth.hash_secret("coração-ção")
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
