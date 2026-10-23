"""O pacote da turma, cifrado, dentro do link que vai para as famílias.

A atividade é dever de casa: celular não entra na escola. O professor manda no
grupo dos responsáveis um link e um código de turma; em casa, o responsável
abre o link, digita o código uma vez, e a criança escolhe o nome, digita o PIN
e faz as atividades pendentes.

**Não há servidor com dado de turma.** O pacote vai no próprio link, depois
do ``#``::

    https://<site do aplicativo>/#t=<pacote>

O que vem depois do ``#`` (o fragmento) não é enviado ao servidor pelo
navegador: o site que serve o aplicativo entrega só o aplicativo e nunca vê
nome de aluno. O pacote é cifrado com AES-256-GCM, com chave derivada do
código da turma por PBKDF2-SHA256: um link encaminhado para fora do grupo,
sem o código, não abre.

Formato do pacote, em base64url sem preenchimento::

    versão (1 byte) | sal (16) | nonce (12) | texto cifrado + etiqueta GCM

O texto claro é um JSON compacto -- cabe num link de uns 4 KB para uma turma
de 30. O lado Dart (``mobile/eyelearn_core/lib/src/class_package.dart``) abre
o mesmo formato, e a suíte dos dois lados usa o mesmo arquivo de exemplo.

O que a cifra **não** protege: quem tem o link e o código -- qualquer
família do grupo -- vê os nomes de exibição ("Ana S.") e os hashes dos PINs
da turma. É o mesmo que um responsável já vê no grupo de WhatsApp da turma; o
nome completo, a data de nascimento e as sessões não vão no pacote.
"""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import string
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PACKAGE_VERSION = 1
SALT_BYTES = 16
NONCE_BYTES = 12
KEY_BYTES = 32

#: Iterações do PBKDF2 sobre o código da turma. O código tem 8 caracteres de
#: um alfabeto de 31 (cerca de 40 bits), e cada tentativa custa estas
#: iterações. Mais que isso pesaria no celular mais lento, que deriva a chave
#: em JavaScript.
KDF_ITERATIONS = 50_000

#: Dados associados da cifra: amarram o texto cifrado a este uso.
AAD = b"eyelearn-turma"

#: Prefixo do fragmento no link.
FRAGMENT_KEY = "t"

ACCESS_CODE_LENGTH = 8


class PackageError(ValueError):
    """Pacote corrompido, de versão desconhecida ou código errado."""


def normalize_code(code: str) -> str:
    """Código da turma como digitado: sem hífen nem espaço, em maiúsculas."""
    allowed = set(string.ascii_uppercase + string.digits)
    return "".join(c for c in code.upper() if c in allowed)


def format_code(code: str) -> str:
    """``K7Q2XP4M`` -> ``K7Q2-XP4M``, para ler e ditar."""
    code = normalize_code(code)
    return f"{code[:4]}-{code[4:]}" if len(code) == ACCESS_CODE_LENGTH else code


def seal(payload: dict[str, Any], code: str, *, salt: bytes | None = None,
         nonce: bytes | None = None) -> str:
    """Cifra o pacote e devolve o texto que vai no link.

    ``salt`` e ``nonce`` só são fixados por quem gera o arquivo de exemplo da
    suíte Dart; em uso, saem aleatórios a cada exportação.
    """
    salt = secrets.token_bytes(SALT_BYTES) if salt is None else salt
    nonce = secrets.token_bytes(NONCE_BYTES) if nonce is None else nonce
    plain = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sealed = AESGCM(_key(code, salt)).encrypt(nonce, plain, AAD)
    blob = bytes([PACKAGE_VERSION]) + salt + nonce + sealed
    return base64.urlsafe_b64encode(blob).rstrip(b"=").decode("ascii")


def open_sealed(text: str, code: str) -> dict[str, Any]:
    """O inverso de :func:`seal`. Usado pelos testes e para conferir o link."""
    try:
        blob = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except ValueError as error:
        raise PackageError("link corrompido") from error
    if len(blob) < 1 + SALT_BYTES + NONCE_BYTES + 16 or blob[0] != PACKAGE_VERSION:
        raise PackageError("link corrompido ou de outra versão")
    salt = blob[1 : 1 + SALT_BYTES]
    nonce = blob[1 + SALT_BYTES : 1 + SALT_BYTES + NONCE_BYTES]
    try:
        plain = AESGCM(_key(code, salt)).decrypt(
            nonce, blob[1 + SALT_BYTES + NONCE_BYTES :], AAD
        )
    except Exception as error:  # InvalidTag: código errado ou link alterado
        raise PackageError("código da turma não confere") from error
    return json.loads(plain.decode("utf-8"))


def link(base_url: str, sealed: str) -> str:
    return f"{base_url.split('#')[0]}#{FRAGMENT_KEY}={sealed}"


def _key(code: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac(
        "sha256", normalize_code(code).encode("ascii"), salt, KDF_ITERATIONS,
        dklen=KEY_BYTES,
    )
