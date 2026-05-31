#!/usr/bin/env python3
"""Smoke tests for validate_music_queue_parity_matrix.py."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / ".codex/workspace/validate_music_queue_parity_matrix.py"
REQUIRED_CONTEXTS = (
    "album-playback",
    "user-playlist-playback",
    "apple-music-playlist-playback",
    "local-library-file-track",
    "radio-station-url-track",
    "play-next-play-later-edits",
    "skip-previous-rapid-changes",
)


def write_session(
    root: Path,
    *,
    manual_outcome: str,
    probe_classification: str,
    notes_text: str,
    probe_extra: str = "",
) -> Path:
    session_dir = root / "session"
    session_dir.mkdir()
    (session_dir / "probe.txt").write_text(
        "\n".join(
            [
                "# Music.app Public Queue Surface Probe",
                "excluded_queue_sources: private frameworks; private AppleEvents",
                "player_state=playing",
                "current_track.name=Song A",
                f"classification.outcome={probe_classification}",
                probe_extra,
            ]
        ),
        encoding="utf-8",
    )
    (session_dir / "notes.md").write_text(notes_text, encoding="utf-8")
    (session_dir / "SUMMARY.md").write_text(
        "\n".join(
            [
                "# Music Queue Parity Matrix Summary",
                "",
                "| Context | Manual outcome | Probe classification | Probe output | Visible notes |",
                "| --- | --- | --- | --- | --- |",
                f"| `radio-station-url-track` | `{manual_outcome}` | `{probe_classification}` | `probe.txt` | `notes.md` |",
            ]
        ),
        encoding="utf-8",
    )
    return session_dir


def write_multi_context_session(root: Path, *, outcomes: dict[str, str]) -> Path:
    session_dir = root / "session"
    session_dir.mkdir()
    summary_lines = [
        "# Music Queue Parity Matrix Summary",
        "",
        "| Context | Manual outcome | Probe classification | Probe output | Visible notes |",
        "| --- | --- | --- | --- | --- |",
    ]

    for context, manual_outcome in outcomes.items():
        probe_name = f"probe-{context}.txt"
        notes_name = f"notes-{context}.md"
        probe_classification = "unavailable_no_current_playlist"
        (session_dir / probe_name).write_text(
            "\n".join(
                [
                    "# Music.app Public Queue Surface Probe",
                    "excluded_queue_sources: private frameworks; private AppleEvents",
                    "player_state=playing",
                    "current_track.name=Song A",
                    f"classification.outcome={probe_classification}",
                ]
            ),
            encoding="utf-8",
        )
        (session_dir / notes_name).write_text(completed_notes(rows_match="no"), encoding="utf-8")
        summary_lines.append(
            f"| `{context}` | `{manual_outcome}` | `{probe_classification}` | `{probe_name}` | `{notes_name}` |"
        )

    (session_dir / "SUMMARY.md").write_text("\n".join(summary_lines), encoding="utf-8")
    return session_dir


def completed_notes(*, rows_match: str, full_probe_coverage: str = "yes") -> str:
    return "\n".join(
        [
            "# Visible Music.app Queue Notes",
            "",
            "- Music.app visible Up Next/history UI open: yes",
            "- Public probe rows cover every visible queue/history row: " + full_probe_coverage,
            "- Do visible rows match probe rows by order and identity: " + rows_match,
            "",
            "## Visible Rows",
            "",
            "```text",
            "history | Song A | Artist A",
            "upcoming | Song B | Artist B",
            "```",
        ]
    )


def run_validator(session_dir: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(VALIDATOR), str(session_dir), *args],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def assert_passes(session_dir: Path, *args: str) -> None:
    result = run_validator(session_dir, *args)
    assert result.returncode == 0, result.stderr + result.stdout


def assert_passes_with_output(session_dir: Path, expected: str, *args: str) -> None:
    result = run_validator(session_dir, *args)
    combined = result.stderr + result.stdout
    assert result.returncode == 0, combined
    assert expected in combined, combined


def assert_fails(session_dir: Path, expected: str, *args: str) -> None:
    result = run_validator(session_dir, *args)
    combined = result.stderr + result.stdout
    assert result.returncode != 0, combined
    assert expected in combined, combined


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="unavailable",
            probe_classification="unavailable_no_current_playlist",
            notes_text=completed_notes(rows_match="no"),
        )
        assert_passes(session)

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="unavailable",
            probe_classification="partial_current_playlist_neighbors_only",
            notes_text=completed_notes(rows_match="no"),
            probe_extra="neighbor[1]= |Wrong Song|Wrong Artist|Wrong Album|ABC",
        )
        assert_passes(session)

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="unavailable",
            probe_classification="partial_current_playlist_neighbors_only",
            notes_text=completed_notes(rows_match="yes"),
            probe_extra="neighbor[1]= |Song A|Artist A|Album|ABC",
        )
        assert_fails(session, "unavailable claim must either point to an unavailable probe classification")

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="unavailable",
            probe_classification="unavailable_no_current_playlist",
            notes_text="\n".join(
                [
                    "# Visible Music.app Queue Notes",
                    "",
                    "- Music.app visible Up Next/history UI open: TODO yes/no",
                    "",
                    "## Visible Rows",
                    "",
                    "```text",
                    "TODO paste visible queue rows here",
                    "```",
                ]
            ),
        )
        assert_fails(session, "unavailable claim must include completed visible Music.app queue notes")

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="unavailable",
            probe_classification="unavailable_no_current_playlist",
            notes_text=completed_notes(rows_match="no"),
            probe_extra="player_state=stopped",
        )
        assert_fails(session, "resolved public-surface claim must use an active Music.app playback context")

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="unavailable",
            probe_classification="unavailable_no_current_playlist",
            notes_text=completed_notes(rows_match="no"),
            probe_extra="current_track.error=Music got an error: Can’t get current track.",
        )
        assert_fails(session, "resolved public-surface claim has no readable current track")

    with tempfile.TemporaryDirectory() as tmp:
        session = write_multi_context_session(
            Path(tmp),
            outcomes={"radio-station-url-track": "unavailable"},
        )
        assert_passes(session)
        assert_passes_with_output(session, "- album-playback: missing", "--coverage-report")
        assert_passes_with_output(
            session,
            "- radio-station-url-track: resolved unavailable",
            "--coverage-report",
        )
        assert_passes_with_output(
            session,
            "coverage.summary=resolved:1 pending:0 missing:6",
            "--coverage-report",
        )
        assert_fails(session, "coverage.summary=resolved:1 pending:0 missing:6", "--require-complete")
        assert_fails(session, "missing required context(s):", "--require-complete")

    with tempfile.TemporaryDirectory() as tmp:
        session = write_multi_context_session(
            Path(tmp),
            outcomes={context: "unavailable" for context in REQUIRED_CONTEXTS},
        )
        assert_passes(session, "--require-complete")

    with tempfile.TemporaryDirectory() as tmp:
        outcomes = {context: "unavailable" for context in REQUIRED_CONTEXTS}
        outcomes["album-playback"] = "pending"
        session = write_multi_context_session(Path(tmp), outcomes=outcomes)
        assert_fails(session, "required context is not resolved", "--require-complete")

    fixed_indexing_probe_rows = "\n".join(
        [
            "fixed_indexing_variant_probe: true",
            "fixed_indexing.original=false",
            "fixed_indexing.variant[false].set=ok",
            "fixed_indexing.variant[true].set=ok",
            "fixed_indexing.restored=true",
            "fixed_indexing.variant[true].current_playlist.neighbor[1]=*|Song A|Artist A|Album|ABC",
        ]
    )
    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="exact",
            probe_classification="partial_current_playlist_neighbors_only",
            notes_text=completed_notes(rows_match="yes"),
            probe_extra=fixed_indexing_probe_rows,
        )
        assert_passes(session)

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="exact",
            probe_classification="partial_current_playlist_neighbors_only",
            notes_text=completed_notes(rows_match="yes", full_probe_coverage="no"),
            probe_extra=fixed_indexing_probe_rows,
        )
        assert_fails(session, "exact claim must state public probe rows covered every visible queue/history row")

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="exact",
            probe_classification="partial_current_playlist_neighbors_only",
            notes_text=completed_notes(rows_match="yes"),
            probe_extra=fixed_indexing_probe_rows.replace("fixed_indexing.restored=true", "fixed_indexing.restored.error=failed"),
        )
        assert_fails(session, "exact fixed-indexing claim did not restore Music.app fixed indexing")

    with tempfile.TemporaryDirectory() as tmp:
        session = write_session(
            Path(tmp),
            manual_outcome="unavailable",
            probe_classification="unavailable_no_current_playlist",
            notes_text=completed_notes(rows_match="no"),
            probe_extra=fixed_indexing_probe_rows.replace("fixed_indexing.restored=true", "fixed_indexing.restored.error=failed"),
        )
        assert_fails(session, "unavailable fixed-indexing claim did not restore Music.app fixed indexing")

    print("validator smoke tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
