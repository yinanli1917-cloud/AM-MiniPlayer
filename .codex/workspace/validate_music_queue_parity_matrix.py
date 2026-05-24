#!/usr/bin/env python3
"""Validate Music.app queue parity matrix evidence.

The validator is intentionally conservative: it does not decide that a context
is exact. It only blocks exact claims when the required visible-note and public
probe evidence is missing or contradictory.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


VALID_OUTCOMES = {"pending", "exact", "partial", "stale", "empty", "unavailable"}
UNAVAILABLE_PREFIXES = ("unavailable", "empty", "missing")
NOTIFICATION_EXACT_BLOCKING_OUTCOMES = {
    "no_notifications_observed",
    "metadata_or_context_only_no_queue_row_keys_observed",
}
REQUIRED_CONTEXTS = (
    "album-playback",
    "user-playlist-playback",
    "apple-music-playlist-playback",
    "local-library-file-track",
    "radio-station-url-track",
    "play-next-play-later-edits",
    "skip-previous-rapid-changes",
)
COMPLETE_OUTCOMES = {"exact", "unavailable"}


@dataclass
class SummaryRow:
    context: str
    manual_outcome: str
    probe_classification: str
    probe_output: str
    visible_notes: str
    line_number: int


def strip_cell(cell: str) -> str:
    cell = cell.strip()
    if len(cell) >= 2 and cell[0] == "`" and cell[-1] == "`":
        return cell[1:-1].strip()
    return cell


def resolve_path(raw: str, session_dir: Path) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    if path.exists():
        return path
    candidate = session_dir / path
    if candidate.exists():
        return candidate
    return path


def parse_summary(summary_path: Path) -> list[SummaryRow]:
    rows: list[SummaryRow] = []
    for line_number, line in enumerate(summary_path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        if "---" in stripped or "Context" in stripped:
            continue
        cells = [strip_cell(cell) for cell in stripped.strip("|").split("|")]
        if len(cells) != 5:
            raise ValueError(f"{summary_path}:{line_number}: expected 5 table cells, got {len(cells)}")
        rows.append(SummaryRow(*cells, line_number=line_number))
    return rows


def extract_probe_classification(text: str) -> str:
    matches = re.findall(r"^classification\.outcome=(.+)$", text, flags=re.MULTILINE)
    return matches[-1].strip() if matches else "missing"


def extract_probe_value(text: str, key: str) -> str | None:
    pattern = rf"^{re.escape(key)}=(.*)$"
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    return matches[-1].strip() if matches else None


def parse_csv_value(value: str | None) -> list[str]:
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_int_value(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def is_distributed_notification_probe(text: str) -> bool:
    return (
        "# Music.app Distributed Notification Probe" in text
        or "capture.row_carrier_userInfo_keys=" in text
    )


def is_fixed_indexing_probe(text: str) -> bool:
    return (
        "fixed_indexing_variant_probe: true" in text
        or "fixed_indexing.variant[" in text
    )


def notification_has_row_payload_shape(text: str, row_keys: list[str]) -> bool:
    for key in row_keys:
        escaped_key = re.escape(key)
        shape_pattern = rf"^event\[\d+\]\.userInfoShape\[{escaped_key}\]=(array|dictionary)\[count=(\d+)\]$"
        for shape_match in re.finditer(shape_pattern, text, flags=re.MULTILINE):
            if int(shape_match.group(2)) > 0:
                return True
    return False


def extract_note_field(text: str, label: str) -> str | None:
    pattern = rf"^- {re.escape(label)}:\s*(.+)$"
    matches = re.findall(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
    return matches[-1].strip() if matches else None


def normalized_note_field(text: str, label: str) -> str:
    return (extract_note_field(text, label) or "").strip().lower()


def visible_rows_are_filled(notes_text: str) -> bool:
    match = re.search(
        r"## Visible Rows\b.*?```(?:text)?\n(?P<body>.*?)```",
        notes_text,
        flags=re.DOTALL | re.IGNORECASE,
    )
    if not match:
        return False
    body = match.group("body").strip()
    if not body:
        return False
    return "TODO" not in body


def notes_have_completed_visible_context(notes_text: str) -> bool:
    if "TODO" in notes_text:
        return False
    visible_open = normalized_note_field(notes_text, "Music.app visible Up Next/history UI open")
    return visible_open in {"yes", "true"} and visible_rows_are_filled(notes_text)


def validate_row(row: SummaryRow, session_dir: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    prefix = f"SUMMARY.md:{row.line_number} [{row.context}]"

    if row.manual_outcome not in VALID_OUTCOMES:
        errors.append(f"{prefix}: invalid manual outcome '{row.manual_outcome}'")

    probe_path = resolve_path(row.probe_output, session_dir)
    notes_path = resolve_path(row.visible_notes, session_dir)

    probe_text = ""
    if not probe_path.exists():
        errors.append(f"{prefix}: missing probe output: {row.probe_output}")
    else:
        probe_text = probe_path.read_text(encoding="utf-8", errors="replace")
        actual_classification = extract_probe_classification(probe_text)
        if actual_classification != row.probe_classification:
            errors.append(
                f"{prefix}: summary classification '{row.probe_classification}' "
                f"does not match probe '{actual_classification}'"
            )
        if "excluded_queue_sources:" not in probe_text:
            errors.append(f"{prefix}: probe output is missing public-surface exclusion preflight")

    notes_text = ""
    if not notes_path.exists():
        errors.append(f"{prefix}: missing visible notes: {row.visible_notes}")
    else:
        notes_text = notes_path.read_text(encoding="utf-8", errors="replace")

    if row.manual_outcome == "exact":
        is_notification_probe = is_distributed_notification_probe(probe_text)
        fixed_indexing_probe = is_fixed_indexing_probe(probe_text)
        notification_has_possible_rows = False

        if "TODO" in notes_text:
            errors.append(f"{prefix}: exact claim still contains TODO markers in visible notes")
        if not visible_rows_are_filled(notes_text):
            errors.append(f"{prefix}: exact claim has no recorded visible Music.app rows")
        visible_open = normalized_note_field(notes_text, "Music.app visible Up Next/history UI open")
        if visible_open not in {"yes", "true"}:
            errors.append(f"{prefix}: exact claim must state the visible Music.app queue UI was open")
        rows_match = normalized_note_field(notes_text, "Do visible rows match probe rows by order and identity")
        if rows_match not in {"yes", "true"}:
            errors.append(f"{prefix}: exact claim must state visible rows matched probe rows by order and identity")
        if row.probe_classification.startswith(UNAVAILABLE_PREFIXES):
            errors.append(f"{prefix}: exact claim points to unavailable probe classification '{row.probe_classification}'")
        if fixed_indexing_probe and extract_probe_value(probe_text, "fixed_indexing.restored") != "true":
            errors.append(f"{prefix}: exact fixed-indexing claim did not restore Music.app fixed indexing")

        if is_notification_probe:
            event_count = parse_int_value(extract_probe_value(probe_text, "capture.events_count"))
            row_carrier_keys = parse_csv_value(extract_probe_value(probe_text, "capture.row_carrier_userInfo_keys"))
            trigger_mode = extract_probe_value(probe_text, "capture.trigger_mode") or "none"
            trigger_finished = extract_probe_value(probe_text, "capture.trigger_finished")

            if event_count is None:
                errors.append(f"{prefix}: exact notification claim is missing capture.events_count")
            elif event_count <= 0:
                errors.append(f"{prefix}: exact notification claim observed no notification events")

            if row.probe_classification in NOTIFICATION_EXACT_BLOCKING_OUTCOMES:
                errors.append(
                    f"{prefix}: exact notification claim points to non-row notification classification "
                    f"'{row.probe_classification}'"
                )

            if not row_carrier_keys:
                errors.append(f"{prefix}: exact notification claim has no row-carrier userInfo keys")
            elif not notification_has_row_payload_shape(probe_text, row_carrier_keys):
                errors.append(
                    f"{prefix}: exact notification claim has row-carrier keys but no non-empty "
                    "array/dictionary payload shape"
                )
            else:
                notification_has_possible_rows = True

            if trigger_mode != "none" and trigger_finished != "true":
                errors.append(f"{prefix}: exact triggered notification claim did not finish restoring trigger state")

        has_public_rows = (
            "neighbor[" in probe_text
            or "classification.public_queue_candidate=named_playlist" in probe_text
            or notification_has_possible_rows
        )
        if probe_text and not has_public_rows:
            errors.append(f"{prefix}: exact claim has no public probe queue rows or named public queue candidate")
    elif row.manual_outcome == "pending":
        if "TODO" in notes_text:
            warnings.append(f"{prefix}: pending row still has TODO markers, which is expected before manual comparison")
    elif row.manual_outcome == "unavailable":
        if is_fixed_indexing_probe(probe_text) and extract_probe_value(probe_text, "fixed_indexing.restored") != "true":
            errors.append(f"{prefix}: unavailable fixed-indexing claim did not restore Music.app fixed indexing")
        if not notes_have_completed_visible_context(notes_text):
            errors.append(
                f"{prefix}: unavailable claim must include completed visible Music.app queue notes "
                "with the queue UI open and visible rows recorded"
            )

        rows_match = normalized_note_field(notes_text, "Do visible rows match probe rows by order and identity")
        if not row.probe_classification.startswith("unavailable") and rows_match not in {"no", "false"}:
            errors.append(
                f"{prefix}: unavailable claim must either point to an unavailable probe classification "
                "or state that visible rows did not match public probe rows by order and identity"
            )
    elif row.manual_outcome in {"partial", "stale", "empty"} and "TODO" in notes_text:
        warnings.append(f"{prefix}: {row.manual_outcome} row still has TODO markers")

    return errors, warnings


def validate_required_context_coverage(rows: list[SummaryRow], *, require_complete: bool) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    rows_by_context: dict[str, list[SummaryRow]] = {}
    known_contexts = set(REQUIRED_CONTEXTS)

    for row in rows:
        rows_by_context.setdefault(row.context, []).append(row)
        if row.context not in known_contexts:
            warnings.append(f"SUMMARY.md:{row.line_number} [{row.context}]: context is not in required coverage list")

    missing_contexts = [context for context in REQUIRED_CONTEXTS if context not in rows_by_context]
    if missing_contexts:
        errors.append("missing required context(s): " + ", ".join(missing_contexts))

    if require_complete:
        for context in REQUIRED_CONTEXTS:
            context_rows = rows_by_context.get(context, [])
            if not context_rows:
                continue

            if not any(row.manual_outcome in COMPLETE_OUTCOMES for row in context_rows):
                latest = context_rows[-1]
                errors.append(
                    f"SUMMARY.md:{latest.line_number} [{context}]: required context is not resolved; "
                    "manual outcome must be exact or unavailable"
                )

    return errors, warnings


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a Music queue parity matrix session.")
    parser.add_argument("session_dir", type=Path, help="Path to parity-matrix-* session directory")
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help=(
            "Require every required playback context to have a resolved exact or "
            "unavailable row. Use this before claiming read-strategy coverage."
        ),
    )
    args = parser.parse_args()

    session_dir = args.session_dir
    summary_path = session_dir / "SUMMARY.md"
    if not summary_path.exists():
        print(f"error: missing summary: {summary_path}", file=sys.stderr)
        return 2

    try:
        rows = parse_summary(summary_path)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if not rows:
        print(f"error: no matrix rows found in {summary_path}", file=sys.stderr)
        return 2

    all_errors: list[str] = []
    all_warnings: list[str] = []
    for row in rows:
        errors, warnings = validate_row(row, session_dir)
        all_errors.extend(errors)
        all_warnings.extend(warnings)

    if args.require_complete:
        errors, warnings = validate_required_context_coverage(rows, require_complete=True)
        all_errors.extend(errors)
        all_warnings.extend(warnings)

    for warning in all_warnings:
        print(f"warning: {warning}")
    for error in all_errors:
        print(f"error: {error}", file=sys.stderr)

    if all_errors:
        return 1

    if args.require_complete:
        print(f"validated complete required context coverage for {len(rows)} parity matrix row(s): {summary_path}")
    else:
        print(f"validated {len(rows)} parity matrix row(s): {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
