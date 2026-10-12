"""Testes da leitura da base.

A base ETDD70 não é redistribuída no repositório, e a integração contínua não
faz download. Os testes montam arquivos no formato esperado em diretório
temporário: é o contrato de leitura que está sob teste, não o conteúdo da base.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from eyelearn.data import etdd70
from eyelearn.trace import DYSLEXIC, TYPICAL


def write_recording(
    path: Path,
    n: int = 100,
    time_unit: str = "ms",
    x_px: float = 960.0,
) -> Path:
    """Escreve uma gravação sintética no formato da base."""
    path.parent.mkdir(parents=True, exist_ok=True)
    step = 4.0 if time_unit == "ms" else 0.004
    pd.DataFrame(
        {
            "time": np.arange(n) * step,
            "x": np.full(n, x_px),
            "y": np.full(n, 540.0),
        }
    ).to_csv(path, index=False)
    return path


class TestLoadRecording:
    def test_converts_milliseconds_to_seconds(self, tmp_path: Path):
        path = write_recording(tmp_path / "S01_text.csv", n=100)
        trace = etdd70.load_recording(path, subject_id="S01", task="text")
        assert trace.duration == pytest.approx(0.396)
        assert trace.sampling_rate == pytest.approx(250.0)

    def test_accepts_seconds_when_declared(self, tmp_path: Path):
        path = write_recording(tmp_path / "S01_text.csv", n=100, time_unit="s")
        trace = etdd70.load_recording(
            path,
            subject_id="S01",
            task="text",
            columns=etdd70.ColumnMap(time_unit="s"),
        )
        assert trace.duration == pytest.approx(0.396)

    def test_screen_centre_becomes_the_origin(self, tmp_path: Path):
        path = write_recording(tmp_path / "S01_text.csv", x_px=960.0)
        trace = etdd70.load_recording(path, subject_id="S01", task="text")
        assert np.allclose(trace.x, 0.0)
        assert np.allclose(trace.y, 0.0)

    def test_carries_metadata_through(self, tmp_path: Path):
        path = write_recording(tmp_path / "S01_text.csv")
        trace = etdd70.load_recording(
            path, subject_id="S01", task="syllables", label=DYSLEXIC
        )
        assert trace.subject_id == "S01"
        assert trace.task == "syllables"
        assert trace.label == DYSLEXIC

    def test_sorts_and_deduplicates_timestamps(self, tmp_path: Path):
        # O rastreador pode duplicar um quadro, e um carimbo repetido quebraria
        # a invariante de tempo estritamente crescente do percurso.
        path = tmp_path / "S01_text.csv"
        pd.DataFrame(
            {"time": [8.0, 0.0, 4.0, 4.0], "x": [1.0, 2.0, 3.0, 4.0], "y": [0.0] * 4}
        ).to_csv(path, index=False)

        trace = etdd70.load_recording(path, subject_id="S01", task="text")
        assert np.all(np.diff(trace.t) > 0)
        assert len(trace) == 3

    def test_reports_missing_columns_with_what_is_available(self, tmp_path: Path):
        path = tmp_path / "S01_text.csv"
        pd.DataFrame({"t": [0.0], "gaze_x": [1.0], "gaze_y": [2.0]}).to_csv(
            path, index=False
        )
        with pytest.raises(KeyError, match="gaze_x"):
            etdd70.load_recording(path, subject_id="S01", task="text")

    def test_column_names_are_configurable(self, tmp_path: Path):
        # Uma mudança de nome de coluna na base não deve exigir alterar código.
        path = tmp_path / "S01_text.csv"
        pd.DataFrame(
            {"t": [0.0, 4.0], "gaze_x": [960.0, 960.0], "gaze_y": [540.0, 540.0]}
        ).to_csv(path, index=False)

        trace = etdd70.load_recording(
            path,
            subject_id="S01",
            task="text",
            columns=etdd70.ColumnMap(time="t", x="gaze_x", y="gaze_y"),
        )
        assert len(trace) == 2

    def test_missing_file_is_reported(self, tmp_path: Path):
        with pytest.raises(FileNotFoundError, match="não encontrada"):
            etdd70.load_recording(tmp_path / "ausente.csv", subject_id="S01", task="text")

    def test_rejects_unknown_time_unit(self):
        with pytest.raises(ValueError, match="time_unit"):
            etdd70.ColumnMap(time_unit="minutos")


class TestReadLabels:
    def test_accepts_numeric_labels(self, tmp_path: Path):
        path = tmp_path / "labels.csv"
        pd.DataFrame({"subject": ["S01", "S02"], "label": [0, 1]}).to_csv(
            path, index=False
        )
        assert etdd70.read_labels(path) == {"S01": TYPICAL, "S02": DYSLEXIC}

    def test_accepts_textual_labels(self, tmp_path: Path):
        path = tmp_path / "labels.csv"
        pd.DataFrame(
            {"subject": ["S01", "S02"], "label": ["typical", "dyslexic"]}
        ).to_csv(path, index=False)
        assert etdd70.read_labels(path) == {"S01": TYPICAL, "S02": DYSLEXIC}

    def test_is_case_insensitive(self, tmp_path: Path):
        path = tmp_path / "labels.csv"
        pd.DataFrame({"subject": ["S01"], "label": ["Dyslexic"]}).to_csv(
            path, index=False
        )
        assert etdd70.read_labels(path) == {"S01": DYSLEXIC}

    def test_unknown_label_is_rejected_not_silently_dropped(self, tmp_path: Path):
        # Um rótulo descartado em silêncio removeria o participante do treino
        # sem aviso.
        path = tmp_path / "labels.csv"
        pd.DataFrame({"subject": ["S01"], "label": ["talvez"]}).to_csv(
            path, index=False
        )
        with pytest.raises(ValueError, match="não reconhecido"):
            etdd70.read_labels(path)

    def test_missing_columns_are_reported(self, tmp_path: Path):
        path = tmp_path / "labels.csv"
        pd.DataFrame({"participant": ["S01"], "group": [1]}).to_csv(path, index=False)
        with pytest.raises(KeyError, match="label"):
            etdd70.read_labels(path)


class TestParseIdentity:
    @pytest.mark.parametrize(
        ("path", "expected"),
        [
            ("S07_text.csv", ("S07", "text")),
            ("S07_pseudotext.csv", ("S07", "pseudotext")),
            ("07_syllables.csv", ("07", "syllables")),
            ("S07/text.csv", ("S07", "text")),
        ],
    )
    def test_extracts_subject_and_task(self, path: str, expected: tuple[str, str]):
        assert etdd70.parse_identity(Path(path)) == expected

    def test_falls_back_to_folder_name(self):
        assert etdd70.parse_identity(Path("participante/leitura.csv")) == (
            "participante",
            "leitura",
        )


class TestLoadDataset:
    @pytest.fixture
    def dataset_root(self, tmp_path: Path) -> Path:
        for subject in ("S01", "S02"):
            for task in ("text", "syllables"):
                write_recording(tmp_path / f"{subject}_{task}.csv")
        return tmp_path

    def test_loads_every_recording(self, dataset_root: Path):
        dataset = etdd70.load_dataset(
            dataset_root, labels={"S01": TYPICAL, "S02": DYSLEXIC}
        )
        assert len(dataset) == 4
        assert dataset.subjects == ["S01", "S02"]

    def test_attaches_labels_by_subject(self, dataset_root: Path):
        dataset = etdd70.load_dataset(
            dataset_root, labels={"S01": TYPICAL, "S02": DYSLEXIC}
        )
        assert dataset.labels_by_subject() == {"S01": TYPICAL, "S02": DYSLEXIC}

    def test_unlabelled_subject_has_no_label(self, dataset_root: Path):
        dataset = etdd70.load_dataset(dataset_root, labels={"S01": TYPICAL})
        assert all(
            trace.label is None for trace in dataset.traces if trace.subject_id == "S02"
        )

    def test_contradictory_labels_are_reported(self, dataset_root: Path):
        dataset = etdd70.load_dataset(dataset_root, labels={"S01": TYPICAL})
        # Simula um arquivo de rótulos inconsistente.
        dataset.traces[0] = dataset.traces[0].__class__(
            t=dataset.traces[0].t,
            x=dataset.traces[0].x,
            y=dataset.traces[0].y,
            subject_id="S01",
            task="text",
            label=DYSLEXIC,
        )
        dataset.traces[1] = dataset.traces[1].__class__(
            t=dataset.traces[1].t,
            x=dataset.traces[1].x,
            y=dataset.traces[1].y,
            subject_id="S01",
            task="syllables",
            label=TYPICAL,
        )
        with pytest.raises(ValueError, match="rótulos"):
            dataset.labels_by_subject()

    def test_missing_root_is_reported(self, tmp_path: Path):
        with pytest.raises(FileNotFoundError, match="não encontrado"):
            etdd70.load_dataset(tmp_path / "ausente", labels={})

    def test_empty_match_is_reported(self, tmp_path: Path):
        # Falhar alto evita um treino sobre zero gravação, que produziria
        # métricas sem significado em vez de um erro.
        with pytest.raises(FileNotFoundError, match="nenhum arquivo"):
            etdd70.load_dataset(tmp_path, labels={}, pattern="**/*.tsv")


class TestQualityFilter:
    def test_drops_recordings_with_too_much_loss(self, tmp_path: Path):
        good = write_recording(tmp_path / "S01_text.csv", n=100)
        dataset = etdd70.load_dataset(tmp_path, labels={"S01": TYPICAL})

        damaged = dataset.traces[0]
        x = damaged.x.copy()
        x[:60] = np.nan
        dataset.traces.append(damaged.with_coordinates(x, damaged.y.copy()))

        filtered = dataset.filter_by_quality(min_valid_ratio=0.75)
        assert len(filtered) == 1
        assert good.exists()

    def test_keeps_everything_when_the_bar_is_zero(self, tmp_path: Path):
        write_recording(tmp_path / "S01_text.csv")
        dataset = etdd70.load_dataset(tmp_path, labels={"S01": TYPICAL})
        assert len(dataset.filter_by_quality(min_valid_ratio=0.0)) == len(dataset)

    def test_rejects_ratio_outside_the_unit_interval(self, tmp_path: Path):
        write_recording(tmp_path / "S01_text.csv")
        dataset = etdd70.load_dataset(tmp_path, labels={"S01": TYPICAL})
        with pytest.raises(ValueError, match="min_valid_ratio"):
            dataset.filter_by_quality(min_valid_ratio=1.5)
