"""Leitura da base ETDD70.

ETDD70 (Dostálová et al., 2024) é a base principal do projeto: registros de
rastreamento ocular de 70 estudantes tchecos de 9 e 10 anos, 35 com diagnóstico
de dislexia, em três tarefas de leitura. Está publicada no Zenodo sob
https://doi.org/10.5281/zenodo.13332134.

A base não é redistribuída neste repositório. O download fica a cargo de quem
executa o pipeline, e o caminho da pasta extraída entra por configuração. O
módulo é tolerante quanto ao layout: o mapeamento de colunas é explícito em
:class:`ColumnMap`, de modo que uma mudança de nome de coluna na base não exige
alterar o código de leitura.

**O formato real** (conferido nos arquivos do Zenodo, registro 13332134), que
:func:`load_etdd70` lê sem configuração:

- um arquivo por participante e tarefa,
  ``data/Subject_<id>_T<n>_<Tarefa>_raw.csv``, com as tarefas
  ``T1_Syllables``, ``T4_Meaningful_Text`` e ``T5_Pseudo_Text``;
- colunas ``time``, ``gaze_x_left``, ``gaze_y_left``, ``gaze_x_right``,
  ``gaze_y_right`` (e pupila, não usada);
- tempo em **microssegundos** -- o intervalo entre amostras é 4000 a 250 Hz.
  A definição da base no pymovements declara milissegundos; os dados dizem
  outra coisa, e quem vale são os dados;
- olhar em pixels de uma tela de 1680 x 1050, origem no canto superior
  esquerdo, com **0 marcando amostra perdida** em vez de célula vazia;
- rótulos em ``dyslexia_class_label.csv``: ``subject_id``, ``class_id``,
  ``label`` (``dyslexic`` / ``non-dyslexic``);
- o zip traz uma pasta ``__MACOSX`` com arquivos ``._*`` de mesmo nome, que
  não são CSV e precisam ser ignorados.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

from eyelearn.signal import preprocess
from eyelearn.trace import DYSLEXIC, TYPICAL, GazeTrace


@dataclass(frozen=True)
class ColumnMap:
    """Nomes das colunas no arquivo de gravação.

    Attributes:
        time: coluna de tempo.
        x: coordenada horizontal.
        y: coordenada vertical.
        time_unit: ``"s"`` ou ``"ms"``. A base distribui o tempo em
            milissegundos; o pipeline trabalha em segundos.
    """

    time: str = "time"
    x: str = "x"
    y: str = "y"
    time_unit: str = "ms"
    #: Colunas do segundo olho, quando a gravação é binocular. Com elas, a
    #: posição é a média dos dois olhos onde ambos foram rastreados, e a do
    #: olho que sobrou onde só um foi.
    x_other: str | None = None
    y_other: str | None = None
    #: Se a coordenada exatamente zero marca amostra perdida, como no ETDD70.
    zero_is_missing: bool = False

    def __post_init__(self) -> None:
        if self.time_unit not in ("s", "ms", "us"):
            raise ValueError(
                f"time_unit deve ser 's', 'ms' ou 'us', recebido {self.time_unit!r}"
            )
        if (self.x_other is None) != (self.y_other is None):
            raise ValueError("x_other e y_other andam juntos")


#: Colunas do ETDD70: binocular, tempo em microssegundos, zero como perda.
ETDD70_COLUMNS = ColumnMap(
    time="time",
    x="gaze_x_left",
    y="gaze_y_left",
    x_other="gaze_x_right",
    y_other="gaze_y_right",
    time_unit="us",
    zero_is_missing=True,
)


@dataclass(frozen=True)
class ScreenGeometry:
    """Geometria do aparato de gravação, necessária para converter em graus.

    Os valores padrão descrevem um monitor de 24 polegadas a 60 cm, montagem
    típica de laboratório. Confira os números na documentação da base antes de
    rodar o experimento: um erro aqui escala todas as características espaciais
    por um fator constante.
    """

    width_px: int = 1920
    height_px: int = 1080
    width_cm: float = 53.1
    viewing_distance_cm: float = 60.0


#: Geometria do ETDD70.
#:
#: Resolução de 1680 x 1050, conferida no tamanho das imagens de estímulo, e
#: distância de 65 cm, o meio da faixa de 60 a 70 cm que o artigo informa
#: (é o valor que o pymovements adota). **A largura física da tela não é
#: publicada.** 47,4 cm é a de um monitor de 22 polegadas em 16:10, o tamanho
#: em que essa resolução é nativa -- uma suposição, registrada como tal.
#:
#: O efeito de errar este número é limitado: todas as medidas espaciais
#: mudam pelo mesmo fator, o que a padronização do modelo absorve. O que não
#: absorve é o que está em graus fixos -- o limiar de velocidade do I-VT
#: (30 °/s) e o ruído da curva de degradação. Um erro de 10% na largura
#: desloca esses dois em 10%.
ETDD70_GEOMETRY = ScreenGeometry(
    width_px=1680, height_px=1050, width_cm=47.4, viewing_distance_cm=65.0
)

#: Nome da tarefa no arquivo -> nome no projeto (o mesmo do aplicativo).
ETDD70_TASKS = {
    "T1_Syllables": "syllables",
    "T4_Meaningful_Text": "text",
    "T5_Pseudo_Text": "pseudotext",
}

_ETDD70_FILENAME = re.compile(
    r"Subject_(?P<subject>\d+)_(?P<task>T\d_[A-Za-z_]+?)_raw\.csv$"
)

#: Extrai o identificador do participante e a tarefa de nomes como
#: ``S07_text.csv`` ou ``subject07/syllables.csv``.
_FILENAME_PATTERN = re.compile(r"(?P<subject>[Ss]?\d+)[_/-](?P<task>[A-Za-z_]+)")


@dataclass
class ETDD70Dataset:
    """Coleção de gravações carregadas da base.

    Attributes:
        traces: percursos em graus de ângulo visual.
        geometry: geometria usada na conversão.
    """

    traces: list[GazeTrace] = field(default_factory=list)
    geometry: ScreenGeometry = field(default_factory=ScreenGeometry)

    def __len__(self) -> int:
        return len(self.traces)

    @property
    def subjects(self) -> list[str]:
        """Identificadores dos participantes, sem repetição e em ordem."""
        return sorted({trace.subject_id for trace in self.traces})

    def labels_by_subject(self) -> dict[str, int]:
        """Rótulo de cada participante.

        Raises:
            ValueError: se um participante aparecer com rótulos divergentes,
                sinal de erro no arquivo de rótulos.
        """
        mapping: dict[str, int] = {}
        for trace in self.traces:
            if trace.label is None:
                continue
            existing = mapping.setdefault(trace.subject_id, trace.label)
            if existing != trace.label:
                raise ValueError(
                    f"participante {trace.subject_id} aparece com rótulos "
                    f"divergentes: {existing} e {trace.label}"
                )
        return mapping

    def filter_by_quality(
        self,
        min_valid_ratio: float = 0.75,
        bounds_deg: tuple[float, float] | None = None,
    ) -> ETDD70Dataset:
        """Descarta gravações com perda excessiva de rastreamento.

        Gravação com muita amostra perdida não produz características
        confiáveis, e mantê-la adiciona ruído de rótulo ao treino.
        """
        if not 0.0 <= min_valid_ratio <= 1.0:
            raise ValueError("min_valid_ratio deve estar entre 0 e 1")
        kept = [
            trace
            for trace in self.traces
            if preprocess.valid_sample_ratio(trace, bounds_deg) >= min_valid_ratio
        ]
        return ETDD70Dataset(traces=kept, geometry=self.geometry)


def load_recording(
    path: Path | str,
    subject_id: str,
    task: str,
    label: int | None = None,
    columns: ColumnMap | None = None,
    geometry: ScreenGeometry | None = None,
) -> GazeTrace:
    """Carrega uma gravação e converte as coordenadas em graus.

    Args:
        path: arquivo CSV ou TSV da gravação.
        subject_id: identificador do participante.
        task: nome da tarefa.
        label: rótulo de classe, quando conhecido.
        columns: mapeamento de colunas.
        geometry: geometria do aparato.

    Returns:
        O percurso correspondente, com o tempo em segundos e as coordenadas em
        graus de ângulo visual.

    Raises:
        FileNotFoundError: se o arquivo não existir.
        KeyError: se faltar alguma das colunas esperadas.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"gravação não encontrada: {path}")

    columns = columns or ColumnMap()
    geometry = geometry or ScreenGeometry()

    separator = "\t" if path.suffix.lower() in (".tsv", ".txt") else ","
    frame = pd.read_csv(path, sep=separator)

    expected = {columns.time, columns.x, columns.y}
    if columns.x_other is not None:
        expected |= {columns.x_other, columns.y_other}
    missing = expected - set(frame.columns)
    if missing:
        raise KeyError(
            f"colunas ausentes em {path.name}: {sorted(missing)}; "
            f"disponíveis: {sorted(frame.columns)}"
        )

    t = frame[columns.time].to_numpy(dtype=float)
    t = t / {"s": 1.0, "ms": 1e3, "us": 1e6}[columns.time_unit]

    def eye(x_name: str, y_name: str) -> tuple[np.ndarray, np.ndarray]:
        x = frame[x_name].to_numpy(dtype=float)
        y = frame[y_name].to_numpy(dtype=float)
        if columns.zero_is_missing:
            lost = (x == 0) | (y == 0)
            x, y = np.where(lost, np.nan, x), np.where(lost, np.nan, y)
        return x, y

    x_px, y_px = eye(columns.x, columns.y)
    if columns.x_other is not None:
        x_other, y_other = eye(columns.x_other, columns.y_other)
        # Média onde os dois olhos valem; o olho que sobrou onde só um vale.
        # nanmean avisaria nas linhas em que os dois se perderam -- que ficam
        # NaN, como devem.
        both = np.stack([x_px, x_other]), np.stack([y_px, y_other])
        counts = np.sum(~np.isnan(both[0]), axis=0)
        with np.errstate(invalid="ignore"):
            x_px = np.where(counts > 0, np.nansum(both[0], axis=0) / counts, np.nan)
            y_px = np.where(counts > 0, np.nansum(both[1], axis=0) / counts, np.nan)

    x_deg, y_deg = preprocess.pixels_to_degrees(
        x_px,
        y_px,
        geometry.width_px,
        geometry.height_px,
        geometry.width_cm,
        geometry.viewing_distance_cm,
    )

    # Amostras fora de ordem quebram a invariante do percurso. A base pode
    # trazer repetições de carimbo de tempo quando o rastreador duplica um
    # quadro; a primeira ocorrência é mantida.
    order = np.argsort(t, kind="stable")
    t, x_deg, y_deg = t[order], x_deg[order], y_deg[order]
    unique = np.concatenate(([True], np.diff(t) > 0))

    return GazeTrace(
        t=t[unique],
        x=x_deg[unique],
        y=y_deg[unique],
        subject_id=subject_id,
        task=task,
        label=label,
    )


def load_dataset(
    root: Path | str,
    labels: dict[str, int] | Path | str,
    pattern: str = "**/*.csv",
    columns: ColumnMap | None = None,
    geometry: ScreenGeometry | None = None,
) -> ETDD70Dataset:
    """Carrega todas as gravações sob um diretório.

    Args:
        root: pasta raiz da base extraída.
        labels: mapa ``{participante: rótulo}`` ou caminho de um CSV com as
            colunas ``subject`` e ``label`` -- esta aceitando ``0``/``1`` ou os
            textos ``typical``/``dyslexic``.
        pattern: glob dos arquivos de gravação.
        columns: mapeamento de colunas.
        geometry: geometria do aparato.

    Returns:
        A base carregada.

    Raises:
        FileNotFoundError: se a raiz não existir ou o glob não casar nada.
    """
    root = Path(root)
    if not root.is_dir():
        raise FileNotFoundError(f"diretório da base não encontrado: {root}")

    label_map = labels if isinstance(labels, dict) else read_labels(labels)
    # O zip do ETDD70 traz metadados do macOS (__MACOSX/._arquivo.csv) com o
    # mesmo nome dos dados; não são CSV.
    files = sorted(
        f for f in root.glob(pattern)
        if "__MACOSX" not in f.parts and not f.name.startswith("._")
    )
    if not files:
        raise FileNotFoundError(f"nenhum arquivo casou {pattern!r} em {root}")

    traces = []
    for file in files:
        subject_id, task = parse_identity(file.relative_to(root))
        traces.append(
            load_recording(
                file,
                subject_id=subject_id,
                task=task,
                label=label_map.get(subject_id),
                columns=columns,
                geometry=geometry,
            )
        )

    return ETDD70Dataset(traces=traces, geometry=geometry or ScreenGeometry())


def read_labels(path: Path | str) -> dict[str, int]:
    """Lê o arquivo de rótulos.

    Aceita ``0``/``1`` e os textos ``typical``/``dyslexic`` na coluna
    ``label``, por ser comum que o arquivo distribuído traga a classe como
    texto.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"arquivo de rótulos não encontrado: {path}")

    frame = pd.read_csv(path)
    # O arquivo do ETDD70 chama a coluna de subject_id.
    if "subject" not in frame.columns and "subject_id" in frame.columns:
        frame = frame.rename(columns={"subject_id": "subject"})
    missing = {"subject", "label"} - set(frame.columns)
    if missing:
        raise KeyError(f"colunas ausentes em {path.name}: {sorted(missing)}")

    textual = {
        "typical": TYPICAL,
        "control": TYPICAL,
        "non-dyslexic": TYPICAL,
        "0": TYPICAL,
        "dyslexic": DYSLEXIC,
        "dyslexia": DYSLEXIC,
        "1": DYSLEXIC,
    }

    mapping: dict[str, int] = {}
    for subject, label in zip(frame["subject"], frame["label"], strict=True):
        key = str(label).strip().lower()
        if key not in textual:
            raise ValueError(f"rótulo não reconhecido para {subject}: {label!r}")
        mapping[str(subject)] = textual[key]
    return mapping


def parse_identity(relative_path: Path) -> tuple[str, str]:
    """Extrai participante e tarefa do caminho de uma gravação.

    Reconhece primeiro o nome do ETDD70 (``Subject_1003_T4_Meaningful_Text_raw.csv``),
    devolvendo a tarefa com o nome do projeto. Cai para o nome da pasta-mãe
    como participante e o do arquivo como tarefa quando nenhum padrão casa, o
    que cobre layouts do tipo ``S07/text.csv``.
    """
    etdd = _ETDD70_FILENAME.search(relative_path.name)
    if etdd:
        task = etdd.group("task")
        return etdd.group("subject"), ETDD70_TASKS.get(task, task)

    match = _FILENAME_PATTERN.search(relative_path.as_posix())
    if match:
        return match.group("subject"), match.group("task")

    parent = relative_path.parent.name
    return (parent or "unknown"), relative_path.stem


def load_etdd70(root: Path | str, labels: Path | str | None = None) -> ETDD70Dataset:
    """Carrega o ETDD70 como distribuído no Zenodo, sem configuração.

    Args:
        root: pasta onde ``data.zip`` foi extraído (a que contém ``data/``).
        labels: ``dyslexia_class_label.csv``. Sem ele, procura o arquivo em
            ``root`` e na pasta acima.
    """
    root = Path(root)
    if labels is None:
        candidates = [root / "dyslexia_class_label.csv",
                      root.parent / "dyslexia_class_label.csv"]
        labels = next((c for c in candidates if c.exists()), candidates[0])
    return load_dataset(
        root,
        labels=labels,
        pattern="**/*_raw.csv",
        columns=ETDD70_COLUMNS,
        geometry=ETDD70_GEOMETRY,
    )
