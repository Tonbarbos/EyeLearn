"""Abrir a atividade e projetar o QR de entrada.

O professor escolhe a tarefa e por quanto tempo a entrada fica aberta; a tela
mostra o QR grande, para projetar, e a contagem regressiva. Fechar a janela
encerra a entrada: quem já entrou continua, quem não entrou precisa de um QR
novo.
"""

from __future__ import annotations

import io
from datetime import UTC, datetime

import segno
from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QPixmap
from PyQt6.QtWidgets import (
    QComboBox,
    QDialog,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSpinBox,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from eyelearn.panel import theme
from eyelearn.storage.store import DEFAULT_ACTIVITY_MINUTES, Activity, Store, Teacher

TASK_LABELS = {
    "syllables": "Sílabas",
    "text": "Texto com sentido",
    "pseudotext": "Pseudotexto",
}


def qr_pixmap(text: str, size: int = 420) -> QPixmap:
    """O QR como imagem, com a margem branca que os leitores precisam."""
    buffer = io.BytesIO()
    segno.make(text, error="m").save(buffer, kind="png", scale=12, border=4)
    pixmap = QPixmap()
    pixmap.loadFromData(buffer.getvalue(), "PNG")
    return pixmap.scaled(size, size, Qt.AspectRatioMode.KeepAspectRatio,
                         Qt.TransformationMode.FastTransformation)


def remaining_text(expires_at: datetime, now: datetime) -> str:
    seconds = int((expires_at - now).total_seconds())
    if seconds <= 0:
        return "Entrada fechada"
    return f"Entrada fecha em {seconds // 60:02d}:{seconds % 60:02d}"


class ActivityDialog(QDialog):
    def __init__(
        self,
        store: Store,
        teacher: Teacher,
        class_id: int,
        class_name: str,
        parent: QWidget | None = None,
        clock=lambda: datetime.now(UTC),
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Atividade")
        self.setStyleSheet(theme.stylesheet())
        self.store = store
        self.teacher = teacher
        self.class_id = class_id
        self.clock = clock
        self.activity: Activity | None = None

        root = QVBoxLayout(self)
        root.setContentsMargins(28, 24, 28, 24)
        root.setSpacing(14)
        title = QLabel(class_name)
        title.setProperty("role", "title")
        root.addWidget(title)

        self.pages = QStackedWidget()
        self.pages.addWidget(self._build_setup())
        self.pages.addWidget(self._build_qr())
        root.addWidget(self.pages)

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)

    def _build_setup(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)

        intro = QLabel(
            "Os alunos entram lendo o QR que vai aparecer aqui. Quem consegue "
            "ler a sua tela está na sala; fora dela, o aplicativo não abre a "
            "atividade."
        )
        intro.setProperty("role", "muted")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        row = QHBoxLayout()
        self.task_box = QComboBox()
        for task, label in TASK_LABELS.items():
            self.task_box.addItem(label, task)
        self.task_box.setCurrentIndex(1)
        row.addWidget(self.task_box, stretch=1)

        self.minutes = QSpinBox()
        self.minutes.setRange(1, 120)
        self.minutes.setValue(DEFAULT_ACTIVITY_MINUTES)
        self.minutes.setSuffix(" min de entrada")
        row.addWidget(self.minutes)
        layout.addLayout(row)

        start = QPushButton("Abrir entrada")
        start.clicked.connect(self.open_activity)
        layout.addWidget(start)
        return page

    def _build_qr(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)

        self.task_label = QLabel("")
        self.task_label.setProperty("role", "title")
        self.task_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.task_label)

        self.qr_label = QLabel()
        self.qr_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.qr_label.setStyleSheet("background: #FFFFFF; border-radius: 18px;")
        layout.addWidget(self.qr_label)

        self.countdown = QLabel("")
        self.countdown.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.countdown.setStyleSheet(f"font-size: 20px; font-weight: 700; color: {theme.INK};")
        layout.addWidget(self.countdown)

        hint = QLabel(
            "No celular: “Ler QR da atividade”. Quando todos tiverem entrado, "
            "encerre a entrada — quem já entrou continua a atividade."
        )
        hint.setProperty("role", "muted")
        hint.setWordWrap(True)
        hint.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(hint)

        close = QPushButton("Encerrar entrada")
        close.clicked.connect(self.close)
        layout.addWidget(close)
        return page

    def open_activity(self) -> Activity:
        self.activity = self.store.open_activity(
            self.teacher,
            self.class_id,
            self.task_box.currentData(),
            minutes=self.minutes.value(),
            now=self.clock(),
        )
        self.task_label.setText(TASK_LABELS[self.activity.task])
        self.qr_label.setPixmap(qr_pixmap(self.activity.qr_text))
        self.pages.setCurrentIndex(1)
        self.tick()
        self.timer.start(1000)
        return self.activity

    def tick(self) -> None:
        if self.activity is None:
            return
        now = self.clock()
        self.countdown.setText(remaining_text(self.activity.expires_at, now))
        if now >= self.activity.expires_at:
            # Vencido, o QR não serve para nada; tirá-lo da tela evita que
            # alguém tente lê-lo e ache que o aplicativo falhou.
            self.timer.stop()
            self.qr_label.clear()
            self.qr_label.setText("Abra uma nova entrada para quem ainda não entrou.")

    def close_entry(self) -> None:
        if self.activity is not None and self.clock() < self.activity.expires_at:
            self.store.close_activity(self.teacher, self.activity, now=self.clock())
        self.timer.stop()

    def closeEvent(self, event) -> None:  # noqa: N802 -- nome do Qt
        self.close_entry()
        super().closeEvent(event)

    def reject(self) -> None:
        self.close_entry()
        super().reject()
