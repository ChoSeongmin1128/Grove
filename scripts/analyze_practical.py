#!/usr/bin/env python3
"""Turn Grove benchmark outputs into practical engine-selection evidence."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from pathlib import Path


def load_jsonl(path: Path) -> dict[str, dict]:
    with path.open(encoding="utf-8") as source:
        return {row["id"]: row for row in map(json.loads, source)}


def load_scored(path: Path) -> dict[str, dict[str, dict]]:
    engines: dict[str, dict[str, dict]] = {}
    with path.open(encoding="utf-8", newline="") as source:
        for row in csv.DictReader(source):
            for key in ("edits", "reference_characters"):
                row[key] = int(float(row[key]))
            for key in ("cer", "processing_seconds", "rtf"):
                row[key] = float(row[key])
            engines.setdefault(row["engine"], {})[row["id"]] = row
    return engines


def corpus_cer(rows: list[dict]) -> float:
    characters = sum(row["reference_characters"] for row in rows)
    return sum(row["edits"] for row in rows) / characters if characters else 0.0


def pearson(left: list[float], right: list[float]) -> float:
    left_mean = statistics.fmean(left)
    right_mean = statistics.fmean(right)
    numerator = sum(
        (left_value - left_mean) * (right_value - right_mean)
        for left_value, right_value in zip(left, right)
    )
    denominator = math.sqrt(
        sum((value - left_mean) ** 2 for value in left)
        * sum((value - right_mean) ** 2 for value in right)
    )
    return numerator / denominator if denominator else 0.0


def selected_rows(
    ids: list[str],
    apple: dict[str, dict],
    whisper: dict[str, dict],
    confidence: dict[str, dict],
    threshold: float,
) -> tuple[list[dict], set[str]]:
    selected = {
        item_id
        for item_id in ids
        if confidence[item_id]["minimumConfidence"] <= threshold
    }
    return [whisper[item_id] if item_id in selected else apple[item_id] for item_id in ids], selected


def compare_transcripts(paths: list[Path]) -> dict:
    runs = [load_jsonl(path) for path in paths]
    base = runs[0]
    return {
        "paths": [str(path) for path in paths],
        "run_count": len(paths),
        "item_count": len(base),
        "differences_from_first": [
            sum(base[item_id].get("text") != run[item_id].get("text") for item_id in base)
            for run in runs[1:]
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--details",
        type=Path,
        default=Path("results/practical/repro-scored/details.csv"),
    )
    parser.add_argument(
        "--apple-confidence",
        type=Path,
        default=Path("results/resources/apple-confidence.jsonl"),
    )
    parser.add_argument(
        "--power-summary",
        type=Path,
        default=Path("results/resources/power-summary.json"),
    )
    parser.add_argument("--threshold", type=float, default=0.80)
    parser.add_argument(
        "--output-dir", type=Path, default=Path("results/practical")
    )
    args = parser.parse_args()

    scored = load_scored(args.details)
    if set(scored) != {"apple-confidence", "whisperkit"}:
        raise SystemExit(f"Unexpected engines: {sorted(scored)}")
    apple = scored["apple-confidence"]
    whisper = scored["whisperkit"]
    confidence = load_jsonl(args.apple_confidence)
    power = json.loads(args.power_summary.read_text(encoding="utf-8"))
    ids = sorted(apple)

    apple_rows = [apple[item_id] for item_id in ids]
    whisper_rows = [whisper[item_id] for item_id in ids]
    hybrid_rows, selected = selected_rows(
        ids, apple, whisper, confidence, args.threshold
    )

    minimum_confidences = [confidence[item_id]["minimumConfidence"] for item_id in ids]
    mean_confidences = [confidence[item_id]["meanConfidence"] for item_id in ids]
    apple_cers = [apple[item_id]["cer"] for item_id in ids]
    whisper_benefits = [apple[item_id]["cer"] - whisper[item_id]["cer"] for item_id in ids]

    # Leave-one-speaker-out selection estimates how a threshold tuned without a
    # speaker transfers to that speaker. It is still exploratory: only four
    # speakers are present and one has just 15 clips.
    thresholds = [value / 100 for value in range(30, 100)]
    speakers = sorted({apple[item_id]["speaker"] for item_id in ids})
    held_out_rows: list[dict] = []
    held_out_selected = 0
    fold_details = []
    for speaker in speakers:
        train_ids = [item_id for item_id in ids if apple[item_id]["speaker"] != speaker]
        test_ids = [item_id for item_id in ids if apple[item_id]["speaker"] == speaker]

        def training_cer(threshold: float) -> float:
            rows, _ = selected_rows(train_ids, apple, whisper, confidence, threshold)
            return corpus_cer(rows)

        best_threshold = min(thresholds, key=training_cer)
        test_rows, test_selected = selected_rows(
            test_ids, apple, whisper, confidence, best_threshold
        )
        held_out_rows.extend(test_rows)
        held_out_selected += len(test_selected)
        fold_details.append(
            {
                "held_out_speaker": speaker,
                "test_items": len(test_ids),
                "selected_threshold": best_threshold,
                "test_selected_items": len(test_selected),
                "test_cer": corpus_cer(test_rows),
                "apple_test_cer": corpus_cer([apple[item_id] for item_id in test_ids]),
                "whisper_test_cer": corpus_cer([whisper[item_id] for item_id in test_ids]),
            }
        )

    apple_wall = power["engines"]["apple"]["timing"]["wall_seconds"]
    whisper_wall = power["engines"]["whisperkit"]["timing"]["wall_seconds"]
    apple_energy = power["engines"]["apple"]["incremental_energy_joules"]
    whisper_energy = power["engines"]["whisperkit"]["incremental_energy_joules"]
    whisper_selected_processing = sum(
        whisper[item_id]["processing_seconds"] for item_id in selected
    )
    whisper_total_processing = sum(row["processing_seconds"] for row in whisper_rows)
    selected_fraction_of_whisper_work = (
        whisper_selected_processing / whisper_total_processing
    )
    estimated_hybrid_wall = apple_wall + whisper_wall * selected_fraction_of_whisper_work
    estimated_hybrid_energy = apple_energy + whisper_energy * selected_fraction_of_whisper_work

    duration_by_id = {
        item_id: confidence[item_id]["audioDurationSeconds"] for item_id in ids
    }
    length_bins = [
        ("under_3_seconds", lambda duration: duration < 3),
        ("3_to_under_8_seconds", lambda duration: 3 <= duration < 8),
        ("8_seconds_or_more", lambda duration: duration >= 8),
    ]
    by_length = []
    for label, predicate in length_bins:
        group = [item_id for item_id in ids if predicate(duration_by_id[item_id])]
        by_length.append(
            {
                "length_bin": label,
                "items": len(group),
                "apple_cer": corpus_cer([apple[item_id] for item_id in group]),
                "whisper_cer": corpus_cer([whisper[item_id] for item_id in group]),
            }
        )

    oracle_rows = [
        min((apple[item_id], whisper[item_id]), key=lambda row: row["edits"])
        for item_id in ids
    ]
    summary = {
        "dataset": {
            "items": len(ids),
            "speakers": len(speakers),
            "audio_seconds": power["audio_seconds"],
            "limitation": "isolated studio/broadcast utterance clips; not a continuous meeting and not a diarization test",
        },
        "quality": {
            "apple_cer": corpus_cer(apple_rows),
            "whisper_cer": corpus_cer(whisper_rows),
            "whisper_relative_cer_reduction": 1
            - corpus_cer(whisper_rows) / corpus_cer(apple_rows),
            "severe_clip_count_cer_at_least_20_percent": {
                "apple": sum(row["cer"] >= 0.20 for row in apple_rows),
                "whisper": sum(row["cer"] >= 0.20 for row in whisper_rows),
            },
            "oracle_best_per_clip_cer_not_deployable": corpus_cer(oracle_rows),
            "by_length": by_length,
        },
        "confidence_signal": {
            "minimum_confidence_range": [min(minimum_confidences), max(minimum_confidences)],
            "minimum_confidence_median": statistics.median(minimum_confidences),
            "mean_confidence_median": statistics.median(mean_confidences),
            "pearson_with_apple_clip_cer": {
                "minimum_confidence": pearson(minimum_confidences, apple_cers),
                "mean_confidence": pearson(mean_confidences, apple_cers),
            },
            "pearson_with_whisper_benefit": {
                "minimum_confidence": pearson(minimum_confidences, whisper_benefits),
                "mean_confidence": pearson(mean_confidences, whisper_benefits),
            },
        },
        "fixed_threshold_hybrid": {
            "rule": f"use WhisperKit when Apple minimum confidence <= {args.threshold:.2f}",
            "selected_items": len(selected),
            "selected_item_fraction": len(selected) / len(ids),
            "cer": corpus_cer(hybrid_rows),
            "estimated_sequential_wall_seconds": estimated_hybrid_wall,
            "estimated_incremental_energy_joules": estimated_hybrid_energy,
            "estimated_wall_fraction_of_full_whisper": estimated_hybrid_wall / whisper_wall,
            "estimated_energy_fraction_of_full_whisper": estimated_hybrid_energy / whisper_energy,
            "caveat": "same-sample exploratory estimate; fallback work and energy are scaled from measured Whisper processing time",
        },
        "leave_one_speaker_out_hybrid": {
            "cer": corpus_cer(held_out_rows),
            "selected_items": held_out_selected,
            "folds": fold_details,
            "caveat": "four folds only; threshold generalization is not established",
        },
        "repeatability": {
            "apple": compare_transcripts(
                [
                    Path("results/raw/apple.jsonl"),
                    Path("results/resources/apple-rerun.jsonl"),
                    Path("results/power/20260901-212101/apple.jsonl"),
                    Path("results/resources/apple-confidence.jsonl"),
                ]
            ),
            "whisperkit": compare_transcripts(
                [
                    Path("results/raw/whisperkit.jsonl"),
                    Path("results/resources/whisperkit-rerun.jsonl"),
                    Path("results/power/20260901-212101/whisperkit.jsonl"),
                ]
            ),
        },
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    review_rows = []
    for item_id in ids:
        review_rows.append(
            {
                "id": item_id,
                "speaker": apple[item_id]["speaker"],
                "minimum_confidence": confidence[item_id]["minimumConfidence"],
                "mean_confidence": confidence[item_id]["meanConfidence"],
                "reference": apple[item_id]["reference_raw"],
                "apple_hypothesis": apple[item_id]["hypothesis"],
                "whisper_hypothesis": whisper[item_id]["hypothesis"],
                "apple_cer": apple[item_id]["cer"],
                "whisper_cer": whisper[item_id]["cer"],
                "whisper_advantage": apple[item_id]["cer"] - whisper[item_id]["cer"],
                "selected_by_fixed_threshold": item_id in selected,
            }
        )
    review_rows.sort(key=lambda row: abs(row["whisper_advantage"]), reverse=True)
    with (args.output_dir / "disagreement_review.csv").open(
        "w", encoding="utf-8", newline=""
    ) as output:
        writer = csv.DictWriter(output, fieldnames=review_rows[0].keys())
        writer.writeheader()
        writer.writerows(review_rows)

    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
