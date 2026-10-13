"""O texto do QR de entrada na atividade.

O professor abre a atividade no painel e projeta o QR. O celular só deixa a
criança entrar se ler esse QR: quem consegue ler a tela do professor está na
sala. Não há rede, localização nem Bluetooth envolvidos.

Formato, em texto curto para caber num QR pequeno (versão 5, legível de longe)::

    EYELEARN1.<turma>.<atividade>.<tarefa>.<expira>.<assinatura>

- ``turma``: identificador público da turma, o mesmo da lista no celular;
- ``atividade``: código da atividade, que volta na sessão gravada;
- ``tarefa``: ``syllables``, ``text`` ou ``pseudotext``;
- ``expira``: instante de expiração, em segundos desde 1970 (UTC);
- ``assinatura``: HMAC-SHA256 do restante com a chave da turma, 16 bytes em
  base64url.

A chave da turma vai para o celular dentro da lista da turma. Sem ela não se
fabrica um QR válido, nem se estende o prazo de um QR antigo. O que a
assinatura **não** impede: uma foto do QR enviada a quem está fora da sala
funciona até a atividade expirar. Por isso o prazo é curto, e o professor
encerra a entrada quando todos entraram.

O lado Dart (``mobile/eyelearn_core/lib/src/activity.dart``) confere o mesmo
formato, e a suíte dos dois lados usa o mesmo arquivo de exemplo.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import re
from dataclasses import dataclass
from datetime import UTC, datetime

PREFIX = "EYELEARN1"
TASKS = ("syllables", "text", "pseudotext")
MAC_BYTES = 16

_FIELD = re.compile(r"^[A-Za-z0-9]+$")


class TicketError(ValueError):
    """QR que não é de atividade, de outra turma, adulterado ou vencido."""


@dataclass(frozen=True)
class Ticket:
    class_uid: str
    activity_code: str
    task: str
    expires_at: datetime


def issue(class_uid: str, key_hex: str, activity_code: str, task: str,
          expires_at: datetime) -> str:
    """Monta o texto do QR."""
    if task not in TASKS:
        raise ValueError(f"tarefa desconhecida: {task!r}")
    for value in (class_uid, activity_code):
        if not _FIELD.match(value):
            raise ValueError(f"campo com caractere inválido: {value!r}")
    body = f"{PREFIX}.{class_uid}.{activity_code}.{task}.{int(expires_at.timestamp())}"
    return f"{body}.{_mac(key_hex, body)}"


def verify(text: str, class_uid: str, key_hex: str, now: datetime,
           grace_seconds: int = 120) -> Ticket:
    """Confere o QR contra a turma e o relógio.

    ``grace_seconds`` tolera relógio de celular um pouco adiantado em relação
    ao do computador do professor.

    Raises:
        TicketError: com a razão, para a tela.
    """
    parts = text.strip().split(".")
    if len(parts) != 6 or parts[0] != PREFIX:
        raise TicketError("não é um QR de atividade do EyeLearn")
    _, uid, code, task, expires, mac = parts
    if uid != class_uid:
        raise TicketError("este QR é de outra turma")
    body = ".".join(parts[:5])
    if not hmac.compare_digest(mac, _mac(key_hex, body)):
        raise TicketError("QR inválido")
    if task not in TASKS or not expires.isdigit():
        raise TicketError("QR inválido")
    expires_at = datetime.fromtimestamp(int(expires), UTC)
    if (now - expires_at).total_seconds() > grace_seconds:
        raise TicketError("a entrada nesta atividade já fechou")
    return Ticket(uid, code, task, expires_at)


def _mac(key_hex: str, body: str) -> str:
    digest = hmac.new(bytes.fromhex(key_hex), body.encode("ascii"), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest[:MAC_BYTES]).rstrip(b"=").decode("ascii")
