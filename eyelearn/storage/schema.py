"""Esquema do banco, como lista de migrações.

Segue o banco do projeto anterior (EyeLearn-Apollo, em MySQL) onde ele ainda
serve, e se afasta dele onde ele contrariava este projeto:

- ``Alunos`` vira ``alunos``, com escola, série e turma passando para a tabela
  ``turmas`` -- no antigo eram texto livre repetido em cada aluno, e "5A" e
  "5º A" viravam duas turmas.
- ``Sessoes`` vira ``sessoes``, uma por gravação, com a exclusão em cascata
  que o antigo já tinha: apagar o aluno apaga o que se gravou dele.
- **``Diagnosticos`` não existe aqui.** O antigo gravava "Possível TDAH" e
  "Possível Dislexia" na sessão; este sistema não diagnostica, e não ter onde
  gravar um rótulo é a forma mais firme de garantir isso.
- **``genero`` saiu.** Nenhuma parte do pipeline usa, e dado pessoal que não
  serve a nada não se coleta (LGPD, art. 6º, III). Data de nascimento ficou,
  opcional: a base de treino é de 9 a 10 anos, e o professor precisa saber
  quando a criança está fora dessa faixa.
- **Há login.** O antigo não tinha nenhum: o aluno escolhia o nome numa lista
  e o botão "Professor" abria o painel direto.

Toda migração nova entra **no fim** da lista. Editar uma que já foi aplicada
não tem efeito nos bancos existentes -- eles não a rodam de novo.
"""

from __future__ import annotations

_NOW = "(strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"

MIGRATIONS: tuple[str, ...] = (
    # 1 -- esquema inicial.
    f"""
    CREATE TABLE professores (
        id          INTEGER PRIMARY KEY,
        usuario     TEXT NOT NULL UNIQUE COLLATE NOCASE
                    CHECK (length(trim(usuario)) > 0),
        nome        TEXT NOT NULL CHECK (length(trim(nome)) > 0),
        senha_hash  TEXT NOT NULL,
        criado_em   TEXT NOT NULL DEFAULT {_NOW}
    );

    CREATE TABLE turmas (
        id            INTEGER PRIMARY KEY,
        professor_id  INTEGER NOT NULL
                      REFERENCES professores(id) ON DELETE CASCADE,
        nome          TEXT NOT NULL CHECK (length(trim(nome)) > 0),
        escola        TEXT,
        serie         TEXT,
        criada_em     TEXT NOT NULL DEFAULT {_NOW},
        UNIQUE (professor_id, nome)
    );

    CREATE TABLE alunos (
        id               INTEGER PRIMARY KEY,
        turma_id         INTEGER NOT NULL
                         REFERENCES turmas(id) ON DELETE CASCADE,
        -- Código pseudônimo: é o que vai no arquivo de sessão, no lugar do
        -- nome. A correspondência código-nome existe só neste banco.
        codigo           TEXT NOT NULL UNIQUE,
        nome_completo    TEXT NOT NULL CHECK (length(trim(nome_completo)) > 0),
        data_nascimento  TEXT,
        pin_hash         TEXT NOT NULL,
        criado_em        TEXT NOT NULL DEFAULT {_NOW},
        -- Duas crianças com o mesmo nome na mesma turma seriam indistinguíveis
        -- na tela de escolha do celular.
        UNIQUE (turma_id, nome_completo)
    );

    CREATE TABLE sessoes (
        id           INTEGER PRIMARY KEY,
        aluno_id     INTEGER NOT NULL
                     REFERENCES alunos(id) ON DELETE CASCADE,
        tarefa       TEXT NOT NULL,
        iniciada_em  TEXT NOT NULL,
        -- O JSON da sessão como chegou do celular. Guardar inteiro, e não
        -- desmontado em colunas, mantém o formato versionado num lugar só:
        -- quem lê é eyelearn.session, que já valida a versão.
        dados        TEXT NOT NULL CHECK (json_valid(dados)),
        observacoes  TEXT,
        importada_em TEXT NOT NULL DEFAULT {_NOW},
        -- A mesma gravação importada duas vezes contaria duas vezes na média
        -- da turma.
        UNIQUE (aluno_id, tarefa, iniciada_em)
    );

    CREATE INDEX sessoes_por_aluno ON sessoes (aluno_id);
    CREATE INDEX alunos_por_turma ON alunos (turma_id);
    """,
)
