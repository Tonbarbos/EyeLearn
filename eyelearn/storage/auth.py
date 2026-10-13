"""Credenciais: senha do professor e PIN do aluno.

Nada aqui guarda segredo em texto claro. Senha e PIN viram um hash scrypt com
sal próprio, e a verificação compara em tempo constante.

**O PIN de quatro dígitos não é protegido pelo hash.** São dez mil
combinações: quem tiver o arquivo do banco testa todas em segundos, com
qualquer função de hash. O que protege o PIN é o limite de tentativas na tela
(:class:`AttemptLimiter`), e o que protege o arquivo é ele ficar no aparelho do
professor. O hash existe para que o PIN não apareça legível para quem abrir o
banco por curiosidade -- não contra quem quiser descobri-lo.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass, field

#: Parâmetros do scrypt. n=2**14 custa cerca de 50 ms num notebook comum:
#: imperceptível no login, caro o bastante para atrapalhar tentativa em massa.
SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1
SALT_BYTES = 16
KEY_BYTES = 32

#: Identificador do formato, gravado junto do hash. Se um dia os parâmetros
#: mudarem, hashes antigos continuam verificáveis pelo prefixo.
SCHEME = "scrypt-v1"

MIN_PASSWORD_LENGTH = 8
PIN_LENGTH = 4


class CredentialError(ValueError):
    """Senha ou PIN fora das regras."""


def hash_secret(secret: str) -> str:
    """Hash de uma senha ou PIN, no formato ``scrypt-v1$sal$hash`` (hex)."""
    salt = secrets.token_bytes(SALT_BYTES)
    key = _derive(secret, salt)
    return f"{SCHEME}${salt.hex()}${key.hex()}"


def verify_secret(secret: str, stored: str) -> bool:
    """Confere um segredo contra o hash guardado, em tempo constante.

    Devolve ``False`` para hash malformado em vez de lançar: um registro
    corrompido não pode virar porta de entrada nem derrubar a tela de login.
    """
    try:
        scheme, salt_hex, key_hex = stored.split("$")
        if scheme != SCHEME:
            return False
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(key_hex)
    except ValueError:
        return False
    return hmac.compare_digest(_derive(secret, salt), expected)


def check_password(password: str) -> None:
    """Regras mínimas para a senha do professor."""
    if len(password) < MIN_PASSWORD_LENGTH:
        raise CredentialError(
            f"a senha precisa de pelo menos {MIN_PASSWORD_LENGTH} caracteres"
        )
    if password.strip() != password:
        raise CredentialError("a senha não pode começar nem terminar com espaço")


def check_pin(pin: str) -> None:
    """Regras do PIN do aluno: quatro dígitos, nada óbvio demais."""
    # str.isdigit aceita dígitos de largura total e sobrescritos ("１２３４",
    # "²"), que escapariam da checagem de sequência abaixo.
    if len(pin) != PIN_LENGTH or not all(c in "0123456789" for c in pin):
        raise CredentialError(f"o PIN precisa ter exatamente {PIN_LENGTH} dígitos")
    if len(set(pin)) == 1:
        raise CredentialError("o PIN não pode ser um dígito repetido")
    if pin in "0123456789" or pin in "9876543210":
        raise CredentialError("o PIN não pode ser uma sequência")


def generate_pin() -> str:
    """PIN aleatório que passa em :func:`check_pin`.

    O professor pode deixar o sistema escolher: PIN escolhido por criança tende
    a ser o aniversário ou 1234.
    """
    while True:
        pin = f"{secrets.randbelow(10**PIN_LENGTH):0{PIN_LENGTH}d}"
        try:
            check_pin(pin)
        except CredentialError:
            continue
        return pin


def _derive(secret: str, salt: bytes) -> bytes:
    return hashlib.scrypt(
        secret.encode("utf-8"),
        salt=salt,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        dklen=KEY_BYTES,
    )


@dataclass
class AttemptLimiter:
    """Bloqueio temporário depois de tentativas erradas seguidas.

    É o que de fato protege o PIN. Cinco erros seguidos bloqueiam aquele login
    por um minuto, e cada novo bloqueio dobra o tempo: suficiente para uma
    criança que errou o próprio PIN tentar de novo logo, e inviável para quem
    tenta as dez mil combinações.
    """

    max_failures: int = 5
    base_lockout_seconds: float = 60.0
    clock: Callable[[], float] = time.monotonic
    _failures: dict[str, int] = field(default_factory=dict)
    _lockouts: dict[str, int] = field(default_factory=dict)
    _locked_until: dict[str, float] = field(default_factory=dict)

    def seconds_locked(self, key: str) -> float:
        remaining = self._locked_until.get(key, 0.0) - self.clock()
        return max(0.0, remaining)

    def is_locked(self, key: str) -> bool:
        return self.seconds_locked(key) > 0

    def record_failure(self, key: str) -> None:
        count = self._failures.get(key, 0) + 1
        self._failures[key] = count
        if count >= self.max_failures:
            lockouts = self._lockouts.get(key, 0)
            self._locked_until[key] = self.clock() + self.base_lockout_seconds * (
                2**lockouts
            )
            self._lockouts[key] = lockouts + 1
            self._failures[key] = 0

    def record_success(self, key: str) -> None:
        self._failures.pop(key, None)
        self._lockouts.pop(key, None)
        self._locked_until.pop(key, None)
