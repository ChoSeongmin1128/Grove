#!/usr/bin/env python3
"""Score Grove ASR JSONL outputs against AI Hub reference labels."""

from __future__ import annotations

import argparse
import csv
import json
import random
import re
import statistics
import unicodedata
from pathlib import Path


PAIR = re.compile(r"\(([^()]*)\)/\(([^()]*)\)")
NOISE_MARKER = re.compile(r"(?<!\w)(?:[a-zA-Z]|@)/\s*")


def reference_variants(text: str, limit: int = 256) -> list[str]:
    text = NOISE_MARKER.sub("", text)
    variants = [text]
    while any(PAIR.search(value) for value in variants):
        expanded: list[str] = []
        for value in variants:
            match = PAIR.search(value)
            if not match:
                expanded.append(value)
                continue
            for replacement in match.groups():
                expanded.append(value[: match.start()] + replacement + value[match.end() :])
        variants = expanded[:limit]
    return variants


def normalize(text: str, *, remove_spaces: bool) -> str:
    text = unicodedata.normalize("NFC", text).casefold()
    kept: list[str] = []
    for character in text:
        category = unicodedata.category(character)
        if category[0] in {"L", "N"}:
            kept.append(character)
        elif character.isspace() and not remove_spaces:
            kept.append(" ")
    normalized = "".join(kept)
    return "".join(normalized.split()) if remove_spaces else " ".join(normalized.split())


def edit_distance(left: list[str] | str, right: list[str] | str) -> int:
    if len(left) > len(right):
        left, right = right, left
    previous = list(range(len(left) + 1))
    for row_index, right_item in enumerate(right, start=1):
        current = [row_index]
        for column_index, left_item in enumerate(left, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column_index] + 1,
                    previous[column_index - 1] + (left_item != right_item),
                )
            )
        previous = current
    return previous[-1]


def best_error(reference: str, hypothesis: str, *, remove_spaces: bool) -> tuple[int, int, str]:
    candidates = reference_variants(reference)
    hypothesis_normalized = normalize(hypothesis, remove_spaces=remove_spaces)
    scored = []
    for candidate in candidates:
        normalized = normalize(candidate, remove_spaces=remove_spaces)
        scored.append((edit_distance(normalized, hypothesis_normalized), len(normalized), normalized))
    return min(scored, key=lambda value: (value[0] / max(value[1], 1), value[0]))


def load_records(path: Path) -> dict[str, dict]:
    records: dict[str, dict] = {}
    with path.open(encoding="utf-8") as source:
        for line in source:
            record = json.loads(line)
            records[record["id"]] = record
    return records


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = (len(ordered) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    weight = index - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--labels-dir", type=Path, required=True)
    parser.add_argument("--session-json", type=Path, required=True)
    parser.add_argument("--engine", action="append", nargs=2, metavar=("NAME", "JSONL"), required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    session = json.loads(args.session_json.read_text(encoding="utf-8"))["dataSet"]
    speaker_by_id = {
        Path(item["textPath"]).stem: item["speaker"] for item in session["dialogs"]
    }
    references = {
        path.stem: path.read_text(encoding="utf-8").strip()
        for path in args.labels_dir.glob("*.txt")
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    detail_rows: list[dict] = []
    summaries: list[dict] = []
    rows_by_engine: dict[str, dict[str, dict]] = {}

    for engine_name, jsonl_path in args.engine:
        records = load_records(Path(jsonl_path))
        missing_ids = sorted(set(references) - set(records))
        extra_ids = sorted(set(records) - set(references))
        if missing_ids or extra_ids:
            raise SystemExit(
                f"{engine_name}: record/reference mismatch: "
                f"missing={missing_ids[:10]} ({len(missing_ids)} total), "
                f"extra={extra_ids[:10]} ({len(extra_ids)} total)"
            )
        total_edits = total_chars = 0
        strict_edits = strict_chars = 0
        exact = failures = 0
        processing_times: list[float] = []
        rtfs: list[float] = []
        engine_rows: list[dict] = []

        for item_id, reference in sorted(references.items()):
            record = records.get(item_id)
            hypothesis = "" if not record else (record.get("text") or "")
            failed = not record or bool(record.get("error"))
            if failed:
                failures += 1

            edits, characters, selected_reference = best_error(
                reference, hypothesis, remove_spaces=True
            )
            strict_item_edits, strict_item_chars, _ = best_error(
                reference, hypothesis, remove_spaces=False
            )
            total_edits += edits
            total_chars += characters
            strict_edits += strict_item_edits
            strict_chars += strict_item_chars
            exact += edits == 0

            processing = float(record.get("processingSeconds", 0)) if record else 0
            rtf = float(record.get("realTimeFactor", 0)) if record else 0
            processing_times.append(processing)
            rtfs.append(rtf)

            row = {
                "engine": engine_name,
                "id": item_id,
                "speaker": speaker_by_id.get(item_id, "unknown"),
                "reference_raw": reference,
                "reference_scored": selected_reference,
                "hypothesis": hypothesis,
                "edits": edits,
                "reference_characters": characters,
                "cer": edits / characters if characters else 0,
                "strict_cer": strict_item_edits / strict_item_chars if strict_item_chars else 0,
                "processing_seconds": processing,
                "rtf": rtf,
                "failed": failed,
            }
            engine_rows.append(row)
            detail_rows.append(row)

        summaries.append(
            {
                "engine": engine_name,
                "items": len(references),
                "failures": failures,
                "cer": total_edits / total_chars if total_chars else 0,
                "strict_cer": strict_edits / strict_chars if strict_chars else 0,
                "exact_match_rate": exact / len(references) if references else 0,
                "total_processing_seconds": sum(processing_times),
                "median_processing_seconds": statistics.median(processing_times),
                "p95_processing_seconds": percentile(processing_times, 0.95),
                "mean_rtf": statistics.fmean(rtfs),
                "median_rtf": statistics.median(rtfs),
            }
        )
        rows_by_engine[engine_name] = {row["id"]: row for row in engine_rows}

    by_speaker_rows: list[dict] = []
    for engine_name, engine_rows in rows_by_engine.items():
        speakers = sorted({row["speaker"] for row in engine_rows.values()})
        for speaker in speakers:
            rows = [row for row in engine_rows.values() if row["speaker"] == speaker]
            by_speaker_rows.append(
                {
                    "engine": engine_name,
                    "speaker": speaker,
                    "items": len(rows),
                    "cer": sum(row["edits"] for row in rows)
                    / sum(row["reference_characters"] for row in rows),
                    "mean_rtf": statistics.fmean(row["rtf"] for row in rows),
                }
            )

    comparison = None
    if len(rows_by_engine) == 2:
        first_name, second_name = rows_by_engine.keys()
        first = rows_by_engine[first_name]
        second = rows_by_engine[second_name]
        item_ids = sorted(first)

        first_wins = second_wins = ties = 0
        for item_id in item_ids:
            first_cer = first[item_id]["cer"]
            second_cer = second[item_id]["cer"]
            if first_cer < second_cer:
                first_wins += 1
            elif second_cer < first_cer:
                second_wins += 1
            else:
                ties += 1

        def corpus_cer(rows: dict[str, dict], sampled_ids: list[str]) -> float:
            edits = sum(rows[item_id]["edits"] for item_id in sampled_ids)
            characters = sum(rows[item_id]["reference_characters"] for item_id in sampled_ids)
            return edits / characters

        rng = random.Random(42)
        bootstrap_differences: list[float] = []
        for _ in range(10_000):
            sampled = [rng.choice(item_ids) for _ in item_ids]
            bootstrap_differences.append(
                corpus_cer(second, sampled) - corpus_cer(first, sampled)
            )
        bootstrap_differences.sort()

        comparison = {
            "first_engine": first_name,
            "second_engine": second_name,
            "difference_definition": "second CER minus first CER",
            "observed_cer_difference": corpus_cer(second, item_ids)
            - corpus_cer(first, item_ids),
            "bootstrap_95_percent_interval": [
                percentile(bootstrap_differences, 0.025),
                percentile(bootstrap_differences, 0.975),
            ],
            "bootstrap_probability_second_is_lower": sum(
                difference < 0 for difference in bootstrap_differences
            )
            / len(bootstrap_differences),
            "clip_level_wins": {
                first_name: first_wins,
                second_name: second_wins,
                "ties": ties,
            },
        }

        paired_rows = []
        for item_id in item_ids:
            first_row = first[item_id]
            second_row = second[item_id]
            paired_rows.append(
                {
                    "id": item_id,
                    "speaker": first_row["speaker"],
                    "reference": first_row["reference_raw"],
                    f"{first_name}_hypothesis": first_row["hypothesis"],
                    f"{second_name}_hypothesis": second_row["hypothesis"],
                    f"{first_name}_cer": first_row["cer"],
                    f"{second_name}_cer": second_row["cer"],
                    "cer_difference_second_minus_first": second_row["cer"]
                    - first_row["cer"],
                }
            )

    with (args.output_dir / "details.csv").open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=detail_rows[0].keys())
        writer.writeheader()
        writer.writerows(detail_rows)

    with (args.output_dir / "by_speaker.csv").open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=by_speaker_rows[0].keys())
        writer.writeheader()
        writer.writerows(by_speaker_rows)

    (args.output_dir / "summary.json").write_text(
        json.dumps(summaries, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    if comparison is not None:
        (args.output_dir / "comparison.json").write_text(
            json.dumps(comparison, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        with (args.output_dir / "paired_details.csv").open(
            "w", encoding="utf-8", newline=""
        ) as output:
            writer = csv.DictWriter(output, fieldnames=paired_rows[0].keys())
            writer.writeheader()
            writer.writerows(paired_rows)
    print(json.dumps(summaries, ensure_ascii=False, indent=2))
    if comparison is not None:
        print(json.dumps(comparison, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
