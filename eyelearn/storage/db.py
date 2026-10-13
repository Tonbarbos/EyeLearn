"""Conexão com o banco e migrações versionadas.

Um arquivo SQLite no computador do professor. Sem servidor: o argumento de
privacidade da seção 4.6 -- nada trafega pela rede -- continua de pé.

As migrações são uma lista de scripts SQL aplicados em ordem, e a versão
aplicada fica em ``PRAGMA user_version``. Abrir um banco antigo com o programa
novo aplica só o que falta; abrir um banco **mais novo** que o programa é
recusado, em vez de o programa antigo escrever num esquema que não conhece.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Sequence
from pathlib import Path


class SchemaTooNewError(RuntimeError):
    """O banco foi criado por uma versão mais nova do programa."""


def connect(path: Path | str) -> sqlite3.Connection:
    """Abre o banco com as opções que o projeto pressupõe.

    ``foreign_keys`` vem desligado por padrão no SQLite, por compatibilidade
    histórica: sem ligá-lo, apagar uma turma deixaria alunos órfãos em
    silêncio.
    """
    connection = sqlite3.connect(str(path))
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    if str(path) != ":memory:":
        connection.execute("PRAGMA journal_mode = WAL")
    return connection


def schema_version(connection: sqlite3.Connection) -> int:
    return int(connection.execute("PRAGMA user_version").fetchone()[0])


def migrate(connection: sqlite3.Connection, migrations: Sequence[str]) -> int:
    """Aplica as migrações que faltam, cada uma na sua transação.

    Returns:
        A versão final do esquema.

    Raises:
        SchemaTooNewError: se o banco estiver adiante das migrações conhecidas.
    """
    current = schema_version(connection)
    if current > len(migrations):
        raise SchemaTooNewError(
            f"o banco está na versão {current} do esquema e este programa só "
            f"conhece até a {len(migrations)}; atualize o EyeLearn"
        )

    for version, script in enumerate(migrations[current:], start=current + 1):
        # executescript faz COMMIT implícito antes de rodar; o BEGIN explícito
        # e o user_version dentro do mesmo script mantêm a migração atômica.
        try:
            connection.executescript(
                f"BEGIN;\n{script}\nPRAGMA user_version = {version};\nCOMMIT;"
            )
        except sqlite3.Error:
            # Um erro no meio do script deixa a transação aberta: sem desfazê-la,
            # metade da migração ficaria gravada no próximo COMMIT de alguém.
            if connection.in_transaction:
                connection.rollback()
            raise

    return schema_version(connection)
