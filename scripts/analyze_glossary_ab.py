#!/usr/bin/env python3
"""Analyze Grove glossary conditioning A/B runs without hiding regressions."""

from __future__ import annotations

import argparse
import csv
import json
import random
from pathlib import Path

from score import best_error, normalize


CONDITIONS = ("baseline", "domain", "domain-decoy")
BOOTSTRAP_SAMPLES = 10_000


def load_jsonl(path: Path) -> dict[str, dict]:
    with path.open(encoding="utf-8") as source:
        return {row["id"]: row for row in map(json.loads, source)}


def contains_term(text: str, term: str) -> bool:
    normalized_term = normalize(term, remove_spaces=True)
    return bool(normalized_term) and normalized_term in normalize(text, remove_spaces=True)


def percentile(values: list[float], probability: float) -> float:
    ordered = sorted(values)
    index = round((len(ordered) - 1) * probability)
    return ordered[index]


def paired_cer_comparison(
    left: dict[str, tuple[int, int]],
    right: dict[str, tuple[int, int]],
    *,
    seed: int,
) -> dict:
    """Compare right minus left with an item-paired corpus bootstrap."""
    ids = sorted(left)
    item_differences = {
        item_id: (right[item_id][0] / right[item_id][1])
        - (left[item_id][0] / left[item_id][1])
        for item_id in ids
        if left[item_id][1] and right[item_id][1]
    }
    rng = random.Random(seed)
    bootstrap_differences: list[float] = []
    for _ in range(BOOTSTRAP_SAMPLES):
        sample = rng.choices(ids, k=len(ids))
        left_edits = sum(left[item_id][0] for item_id in sample)
        left_chars = sum(left[item_id][1] for item_id in sample)
        right_edits = sum(right[item_id][0] for item_id in sample)
        right_chars = sum(right[item_id][1] for item_id in sample)
        bootstrap_differences.append(
            (right_edits / right_chars) - (left_edits / left_chars)
        )

    left_cer = sum(value[0] for value in left.values()) / sum(
        value[1] for value in left.values()
    )
    right_cer = sum(value[0] for value in right.values()) / sum(
        value[1] for value in right.values()
    )
    epsilon = 1e-12
    return {
        "rightMinusLeft": right_cer - left_cer,
        "bootstrapSamples": BOOTSTRAP_SAMPLES,
        "bootstrap95PercentCI": [
            percentile(bootstrap_differences, 0.025),
            percentile(bootstrap_differences, 0.975),
        ],
        "probabilityRightLower": sum(value < 0 for value in bootstrap_differences)
        / BOOTSTRAP_SAMPLES,
        "itemWinsRightLower": sum(value < -epsilon for value in item_differences.values()),
        "itemTies": sum(abs(value) <= epsilon for value in item_differences.values()),
        "itemLossesRightHigher": sum(value > epsilon for value in item_differences.values()),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--run",
        action="append",
        nargs=3,
        metavar=("ENGINE", "CONDITION", "JSONL"),
        required=True,
    )
    parser.add_argument("--context-dir", type=Path, required=True)
    parser.add_argument("--labels-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    runs: dict[str, dict[str, dict[str, dict]]] = {}
    for engine, condition, path in args.run:
        if condition not in CONDITIONS:
            raise SystemExit(f"Unsupported condition: {condition}")
        runs.setdefault(engine, {})[condition] = load_jsonl(Path(path))

    for engine, conditions in runs.items():
        missing = set(CONDITIONS) - set(conditions)
        if missing:
            raise SystemExit(f"{engine}: missing conditions {sorted(missing)}")
        id_sets = [set(conditions[condition]) for condition in CONDITIONS]
        if any(item_ids != id_sets[0] for item_ids in id_sets[1:]):
            raise SystemExit(f"{engine}: condition item IDs differ")

    manifests = {
        condition: json.loads(
            (args.context_dir / f"{condition}-manifest.json").read_text(encoding="utf-8")
        )
        for condition in CONDITIONS
    }
    domain_terms = manifests["domain"]["terms"]
    decoys = manifests["domain-decoy"]["decoys"]
    references = None
    if args.labels_dir:
        references = {
            path.stem: path.read_text(encoding="utf-8").strip()
            for path in args.labels_dir.glob("*.txt")
        }

    summary = {
        "conditions": {
            condition: {
                "termCount": manifests[condition]["termCount"],
                "decoyCount": manifests[condition]["decoyCount"],
            }
            for condition in CONDITIONS
        },
        "engines": {},
        "limitations": [
            "A changed transcript is not automatically an improvement.",
            "Without a time-aligned human reference, term correctness requires audio review.",
            "Decoy insertion should remain zero; any insertion is a conditioning regression.",
        ],
    }
    review_rows: list[dict] = []

    for engine, conditions in sorted(runs.items()):
        ids = sorted(conditions["baseline"])
        engine_summary: dict = {"conditions": {}}
        item_scores: dict[str, dict[str, tuple[int, int]]] = {
            condition: {} for condition in CONDITIONS
        }
        for condition in CONDITIONS:
            records = conditions[condition]
            metrics = {
                "items": len(ids),
                "failures": sum(bool(records[item_id].get("error")) for item_id in ids),
                "totalProcessingSeconds": sum(
                    float(records[item_id].get("processingSeconds", 0)) for item_id in ids
                ),
                "decoyInsertionItems": sum(
                    any(contains_term(records[item_id].get("text") or "", decoy) for decoy in decoys)
                    for item_id in ids
                ),
                "decoyMentionCount": sum(
                    contains_term(records[item_id].get("text") or "", decoy)
                    for item_id in ids
                    for decoy in decoys
                ),
            }
            if references is not None:
                missing = set(ids) - set(references)
                if missing:
                    raise SystemExit(f"Missing references for {sorted(missing)[:10]}")
                edits = characters = 0
                reference_mentions = term_hits = 0
                for item_id in ids:
                    hypothesis = records[item_id].get("text") or ""
                    item_edits, item_chars, _ = best_error(
                        references[item_id], hypothesis, remove_spaces=True
                    )
                    item_scores[condition][item_id] = (item_edits, item_chars)
                    edits += item_edits
                    characters += item_chars
                    for term in domain_terms:
                        if len(normalize(term, remove_spaces=True)) < 3:
                            continue
                        if contains_term(references[item_id], term):
                            reference_mentions += 1
                            term_hits += contains_term(hypothesis, term)
                metrics["cer"] = edits / characters if characters else None
                metrics["referenceDomainTermMentions"] = reference_mentions
                metrics["domainTermHits"] = term_hits
                metrics["domainTermRecall"] = (
                    term_hits / reference_mentions if reference_mentions else None
                )
            engine_summary["conditions"][condition] = metrics

        baseline = conditions["baseline"]
        domain = conditions["domain"]
        domain_decoy = conditions["domain-decoy"]
        engine_summary["changedItems"] = {
            "domainVsBaseline": sum(
                (domain[item_id].get("text") or "")
                != (baseline[item_id].get("text") or "")
                for item_id in ids
            ),
            "domainDecoyVsDomain": sum(
                (domain_decoy[item_id].get("text") or "")
                != (domain[item_id].get("text") or "")
                for item_id in ids
            ),
        }
        if references is not None:
            engine_summary["cerDifferences"] = {
                "domainMinusBaseline": engine_summary["conditions"]["domain"]["cer"]
                - engine_summary["conditions"]["baseline"]["cer"],
                "domainDecoyMinusDomain": engine_summary["conditions"]["domain-decoy"]["cer"]
                - engine_summary["conditions"]["domain"]["cer"],
            }
            engine_summary["pairedComparisons"] = {
                "domainVsBaseline": paired_cer_comparison(
                    item_scores["baseline"], item_scores["domain"], seed=42
                ),
                "domainDecoyVsDomain": paired_cer_comparison(
                    item_scores["domain"], item_scores["domain-decoy"], seed=43
                ),
                "domainDecoyVsBaseline": paired_cer_comparison(
                    item_scores["baseline"], item_scores["domain-decoy"], seed=44
                ),
            }
        baseline_seconds = engine_summary["conditions"]["baseline"][
            "totalProcessingSeconds"
        ]
        engine_summary["processingRatiosVsBaseline"] = {
            condition: (
                engine_summary["conditions"][condition]["totalProcessingSeconds"]
                / baseline_seconds
                if baseline_seconds
                else None
            )
            for condition in ("domain", "domain-decoy")
        }
        summary["engines"][engine] = engine_summary

        for item_id in ids:
            decoys_found = [
                decoy
                for decoy in decoys
                if contains_term(domain_decoy[item_id].get("text") or "", decoy)
            ]
            review_row = {
                    "engine": engine,
                    "id": item_id,
                    "reference": references[item_id] if references else "",
                    "baseline": baseline[item_id].get("text") or "",
                    "domain": domain[item_id].get("text") or "",
                    "domain_decoy": domain_decoy[item_id].get("text") or "",
                    "domain_changed": (domain[item_id].get("text") or "")
                    != (baseline[item_id].get("text") or ""),
                    "decoy_changed": (domain_decoy[item_id].get("text") or "")
                    != (domain[item_id].get("text") or ""),
                    "decoys_found": " | ".join(decoys_found),
                }
            if references is not None:
                baseline_cer = (
                    item_scores["baseline"][item_id][0]
                    / item_scores["baseline"][item_id][1]
                )
                domain_cer = (
                    item_scores["domain"][item_id][0]
                    / item_scores["domain"][item_id][1]
                )
                domain_decoy_cer = (
                    item_scores["domain-decoy"][item_id][0]
                    / item_scores["domain-decoy"][item_id][1]
                )
                review_row.update(
                    {
                        "baseline_cer": baseline_cer,
                        "domain_cer": domain_cer,
                        "domain_minus_baseline_cer": domain_cer - baseline_cer,
                        "domain_decoy_cer": domain_decoy_cer,
                        "domain_decoy_minus_domain_cer": domain_decoy_cer
                        - domain_cer,
                    }
                )
            review_rows.append(review_row)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    with (args.output_dir / "paired_review.csv").open(
        "w", encoding="utf-8", newline=""
    ) as output:
        writer = csv.DictWriter(output, fieldnames=review_rows[0].keys())
        writer.writeheader()
        writer.writerows(review_rows)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
