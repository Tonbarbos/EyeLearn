"""Testes da importação de sessões e da comparação intraturma.

A comparação intraturma é o que o professor vê. Um defeito aqui não aparece
como erro: aparece como uma criança destacada que não devia estar, ou uma que
devia e não está.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from eyelearn.features.reading import FEATURE_NAMES
from eyelearn.session import (
    PEDAGOGICAL_SUGGESTIONS,
    SESSION_FORMAT_VERSION,
    compare_within_class,
    load_session,
    load_sessions,
    session_from_dict,
    suggestions_for,
)


def make_payload(
    code: str = "A01",
    task: str = "text",
    started_at: str = "2026-10-12T14:30:00Z",
    valid_ratio: float = 0.95,
    sampling_rate: float = 28.0,
    overrides: dict[str, float] | None = None,
    training_data: str = "etdd70",
) -> dict:
    """Monta o JSON que o aplicativo grava."""
    features = {name: 1.0 for name in FEATURE_NAMES}
    features.update(overrides or {})
    return {
        "format_version": SESSION_FORMAT_VERSION,
        "participant_code": code,
        "task": task,
        "started_at": started_at,
        "duration_seconds": 42.5,
        "sampling_rate_hz": sampling_rate,
        "valid_sample_ratio": valid_ratio,
        "features": features,
        "score": 0.4,
        "model": {"score_kind": "probability", "training_data": training_data},
    }


def write_session(directory: Path, name: str, payload: dict) -> Path:
    path = directory / name
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


class TestLoadSession:
    def test_reads_every_field(self, tmp_path: Path):
        path = write_session(tmp_path, "s.json", make_payload())
        session = load_session(path)

        assert session.participant_code == "A01"
        assert session.task == "text"
        assert session.duration_seconds == pytest.approx(42.5)
        assert session.sampling_rate_hz == pytest.approx(28.0)
        assert set(session.features) == set(FEATURE_NAMES)

    def test_rejects_unknown_format_version(self):
        payload = make_payload()
        payload["format_version"] = 999
        with pytest.raises(ValueError, match="versão de sessão"):
            session_from_dict(payload)

    def test_rejects_missing_features(self):
        payload = make_payload()
        del payload["features"]["regression_ratio"]
        with pytest.raises(ValueError, match="regression_ratio"):
            session_from_dict(payload)

    def test_missing_file_is_reported(self, tmp_path: Path):
        with pytest.raises(FileNotFoundError, match="não encontrada"):
            load_session(tmp_path / "ausente.json")


class TestQuality:
    def test_accepts_a_good_recording(self):
        session = session_from_dict(make_payload(valid_ratio=0.95, sampling_rate=28.0))
        assert session.has_usable_quality

    def test_rejects_excessive_sample_loss(self):
        session = session_from_dict(make_payload(valid_ratio=0.4))
        assert not session.has_usable_quality

    def test_rejects_low_sampling_rate(self):
        session = session_from_dict(make_payload(sampling_rate=8.0))
        assert not session.has_usable_quality

    def test_flags_a_synthetic_model(self):
        # O painel precisa avisar: uma pontuação de modelo sintético não diz
        # nada sobre leitura.
        session = session_from_dict(make_payload(training_data="synthetic"))
        assert session.trained_on_synthetic_data

    def test_does_not_flag_a_real_model(self):
        session = session_from_dict(make_payload(training_data="etdd70"))
        assert not session.trained_on_synthetic_data


class TestLoadDirectory:
    def test_reads_every_session(self, tmp_path: Path):
        for index in range(3):
            write_session(
                tmp_path, f"s{index}.json", make_payload(code=f"A{index:02d}")
            )
        assert len(load_sessions(tmp_path)) == 3

    def test_skips_unreadable_files_without_losing_the_rest(self, tmp_path: Path):
        # O professor pode ter recebido uma dúzia de sessões por canais
        # diferentes; perder as boas por causa de uma ruim seria o pior
        # resultado possível.
        write_session(tmp_path, "boa.json", make_payload(code="A01"))
        (tmp_path / "quebrada.json").write_text("{isso não é json", encoding="utf-8")
        write_session(tmp_path, "outra.json", make_payload(code="A02"))

        sessions = load_sessions(tmp_path)
        assert {s.participant_code for s in sessions} == {"A01", "A02"}

    def test_skips_future_format_versions(self, tmp_path: Path):
        payload = make_payload(code="A09")
        payload["format_version"] = 42
        write_session(tmp_path, "futura.json", payload)
        write_session(tmp_path, "atual.json", make_payload(code="A01"))

        sessions = load_sessions(tmp_path)
        assert [s.participant_code for s in sessions] == ["A01"]

    def test_missing_directory_is_reported(self, tmp_path: Path):
        with pytest.raises(FileNotFoundError, match="não encontrado"):
            load_sessions(tmp_path / "ausente")


class TestClassComparison:
    def build(self, durations: list[float], task: str = "text"):
        return [
            session_from_dict(
                make_payload(
                    code=f"A{index:02d}",
                    task=task,
                    overrides={"fixation_duration_mean": duration},
                )
            )
            for index, duration in enumerate(durations)
        ]

    def test_z_scores_are_centred_on_the_class(self):
        sessions = self.build([0.20, 0.25, 0.30])
        comparison = compare_within_class(sessions, "text")

        column = comparison.feature_names.index("fixation_duration_mean")
        assert comparison.z_scores[:, column].mean() == pytest.approx(0.0, abs=1e-12)

    def test_identifies_who_is_above_the_class(self):
        sessions = self.build([0.20, 0.21, 0.22, 0.23, 0.45])
        comparison = compare_within_class(sessions, "text")

        z = comparison.for_participant("A04")["fixation_duration_mean"]
        assert z > 1.5

    def test_constant_feature_gives_zero_not_infinity(self):
        # Turma inteira igual numa característica: nenhum desvio. Dividir por
        # zero daria infinito, que percorreria o painel inteiro como "muito
        # acima da turma".
        sessions = self.build([0.25, 0.25, 0.25])
        comparison = compare_within_class(sessions, "text")

        assert np.all(np.isfinite(comparison.z_scores))
        column = comparison.feature_names.index("fixation_duration_mean")
        assert np.all(comparison.z_scores[:, column] == 0.0)

    def test_excludes_low_quality_recordings_by_default(self):
        # Uma captura ruim distorce a média da turma, e é contra a média da
        # turma que todos os outros são medidos.
        sessions = self.build([0.20, 0.25, 0.30])
        sessions.append(
            session_from_dict(
                make_payload(
                    code="A99",
                    valid_ratio=0.2,
                    overrides={"fixation_duration_mean": 9.0},
                )
            )
        )
        comparison = compare_within_class(sessions, "text")
        assert "A99" not in comparison.participant_codes

    def test_can_include_low_quality_when_asked(self):
        sessions = self.build([0.20, 0.25, 0.30])
        sessions.append(session_from_dict(make_payload(code="A99", valid_ratio=0.2)))
        comparison = compare_within_class(
            sessions, "text", include_low_quality=True
        )
        assert "A99" in comparison.participant_codes

    def test_keeps_only_the_latest_recording_per_participant(self):
        # A criança pode repetir a tarefa; a última é a que vale.
        sessions = [
            session_from_dict(
                make_payload(
                    code="A01",
                    started_at="2026-10-12T14:00:00Z",
                    overrides={"fixation_duration_mean": 0.90},
                )
            ),
            session_from_dict(
                make_payload(
                    code="A01",
                    started_at="2026-10-12T15:00:00Z",
                    overrides={"fixation_duration_mean": 0.25},
                )
            ),
            session_from_dict(make_payload(code="A02")),
            session_from_dict(make_payload(code="A03")),
        ]
        comparison = compare_within_class(sessions, "text")

        assert comparison.participant_codes.count("A01") == 1
        column = comparison.feature_names.index("fixation_duration_mean")
        row = comparison.participant_codes.index("A01")
        # Com a gravação antiga, A01 seria um valor extremo; com a recente, não.
        assert abs(comparison.z_scores[row, column]) < 1.5

    def test_separates_the_tasks(self):
        # Comparar leitura de sílabas com leitura de texto não faz sentido: as
        # características têm escalas diferentes nas duas.
        sessions = self.build([0.20, 0.25, 0.30], task="text")
        sessions += self.build([0.60, 0.65, 0.70], task="syllables")

        text = compare_within_class(sessions, "text")
        assert len(text.participant_codes) == 3
        assert text.class_mean[
            text.feature_names.index("fixation_duration_mean")
        ] == pytest.approx(0.25)

    def test_rejects_a_class_too_small_to_compare(self):
        # Com dois participantes o escore z de cada um é mecanicamente ±1 -- um
        # número que pareceria significar algo e não significaria nada.
        sessions = self.build([0.20, 0.30])
        with pytest.raises(ValueError, match="pelo menos 3"):
            compare_within_class(sessions, "text")

    def test_unknown_participant_is_reported(self):
        comparison = compare_within_class(self.build([0.2, 0.25, 0.3]), "text")
        with pytest.raises(KeyError, match="A99"):
            comparison.for_participant("A99")

    def test_outliers_lists_the_distinguishing_features(self):
        sessions = self.build([0.20, 0.21, 0.22, 0.23, 0.50])
        comparison = compare_within_class(sessions, "text")

        outliers = comparison.outliers(threshold=1.5)
        assert "A04" in outliers
        assert "fixation_duration_mean" in outliers["A04"]

    def test_outliers_rejects_a_non_positive_threshold(self):
        comparison = compare_within_class(self.build([0.2, 0.25, 0.3]), "text")
        with pytest.raises(ValueError, match="threshold"):
            comparison.outliers(threshold=0.0)


class TestPedagogicalSuggestions:
    def test_suggests_only_for_features_above_the_class(self):
        sessions = [
            session_from_dict(
                make_payload(
                    code=f"A{index:02d}",
                    overrides={"fixation_duration_mean": duration},
                )
            )
            for index, duration in enumerate([0.20, 0.21, 0.22, 0.23, 0.50])
        ]
        comparison = compare_within_class(sessions, "text")

        assert suggestions_for(comparison, "A04")
        # Quem está abaixo da média não precisa de adaptação nenhuma.
        assert not suggestions_for(comparison, "A00")

    def test_every_suggestion_names_an_actual_feature(self):
        assert set(PEDAGOGICAL_SUGGESTIONS) <= set(FEATURE_NAMES)

    def test_no_suggestion_states_a_diagnosis(self):
        # O sistema descreve o padrão observado e sugere adaptação; não atribui
        # rótulo diagnóstico. Este teste é o que impede uma redação futura de
        # atravessar essa linha sem discussão.
        forbidden = (
            "dislexia",
            "disléxic",
            "diagnóstic",
            "transtorno",
            "déficit",
            "distúrbio",
            "patolog",
        )
        for name, text in PEDAGOGICAL_SUGGESTIONS.items():
            lowered = text.lower()
            for word in forbidden:
                assert word not in lowered, f"{name}: {word}"

    def test_every_suggestion_describes_before_it_prescribes(self):
        # Primeiro o que foi observado, depois o que fazer -- para que o
        # professor possa discordar da leitura, e não só da sugestão.
        for name, text in PEDAGOGICAL_SUGGESTIONS.items():
            assert "Pode ajudar:" in text, name
            assert text.index("Pode ajudar:") > 40, name

    def test_every_suggestion_compares_with_the_class(self):
        for name, text in PEDAGOGICAL_SUGGESTIONS.items():
            assert "turma" in text.lower(), name


class TestCrossLanguageFormat:
    """O JSON que o Dart escreve tem de ser legível aqui.

    Fecha a fronteira de linguagem na direção contrária à dos vetores de ouro:
    ali o Dart consome o que o Python produz, aqui o Python consome o que o Dart
    produz. O arquivo é gerado por
    ``mobile/eyelearn_core/tool/emit_session_fixture.dart`` e commitado; sem
    ele, o formato de sessão seria afirmado por cada lado isoladamente, e um
    campo renomeado em um deles só apareceria quando um professor tentasse
    importar uma sessão de verdade.
    """

    FIXTURE = (
        Path(__file__).resolve().parent.parent
        / "mobile"
        / "eyelearn_core"
        / "assets"
        / "session_example.json"
    )

    def test_the_fixture_is_committed(self):
        assert self.FIXTURE.exists(), (
            "rode: cd mobile/eyelearn_core && "
            "dart run tool/emit_session_fixture.dart"
        )

    def test_python_reads_the_dart_output(self):
        session = load_session(self.FIXTURE)
        assert session.participant_code == "EXEMPLO01"
        assert session.task == "text"
        assert set(session.features) == set(FEATURE_NAMES)

    def test_the_dart_output_passes_the_quality_check(self):
        assert load_session(self.FIXTURE).has_usable_quality

    def test_the_dart_output_carries_model_provenance(self):
        session = load_session(self.FIXTURE)
        assert session.model.get("score_kind") in ("probability", "decision")
        assert "training_data" in session.model

    def test_the_dart_output_carries_no_raw_gaze_or_image(self):
        # A mesma afirmação que session_test.dart faz do lado Dart, verificada
        # no arquivo que realmente atravessa.
        raw = self.FIXTURE.read_text(encoding="utf-8").lower()
        for forbidden in ("base64", "jpeg", "image", "samples", "student_name"):
            assert forbidden not in raw, forbidden


class TestDemoData:
    def test_flag_is_read(self):
        payload = make_payload() | {"demo_data": True}
        assert session_from_dict(payload).demo_data

    def test_absent_means_real(self):
        assert not session_from_dict(make_payload()).demo_data
