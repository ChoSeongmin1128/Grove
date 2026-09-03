#!/usr/bin/env python3
"""Read-only integrity checks; optional private JSON receipt, no accuracy scoring."""
import argparse
import json
import math
from pathlib import Path

from align_moss import lexical, moss_body, sha256


def validate(alignment, moss, moss_sha):
    errors = []
    diagnostics = []
    if type(alignment.get("schemaVersion")) is not int or alignment["schemaVersion"] != 1:
        errors.append("Unsupported or untyped alignment schema version")
    if alignment.get("referenceUsed") is not False:
        errors.append("Alignment must explicitly declare referenceUsed false")
    if alignment.get("sourceMossSha256") != moss_sha:
        errors.append("MOSS content hash mismatch")
    utterances = alignment.get("utterances", [])
    if any(type(u.get("index")) is not int for u in utterances):
        errors.append("Source utterance index must be an integer, not bool or a string")
    if [u.get("index") for u in utterances] != list(range(len(moss["segments"]))):
        errors.append("Source utterance indices are missing, duplicated or reordered")
    for utterance in utterances:
        index = utterance["index"]
        if type(index) is not int or index not in range(len(moss["segments"])):
            continue
        source = moss["segments"][index]
        text, prefix_length = moss_body(source)
        if utterance["text"] != text or utterance["rawText"] != source["text"]:
            errors.append(f"Source text changed at utterance {index}")
        if utterance["start"] != source["start"] or utterance["end"] != source["end"]:
            errors.append(f"Source utterance bounds changed at {index}")
        if utterance["removedGeneratedPrefixLength"] != prefix_length:
            errors.append(f"Prefix offset mismatch at {index}")
        words = utterance["words"]
        if lexical("".join(w["text"] for w in words)) != lexical(text):
            errors.append(f"Lexical unit mismatch at {index}")
        repaired = sum("upstreamTimestampRepair" in word["flags"] for word in words)
        zero = sum(word["start"] == word["end"] for word in words)
        raw = [value for word in words for value in (word["rawStart"], word["rawEnd"])]
        fixed = [value for word in words for value in (word["start"], word["end"])]
        raw_nonmonotonic = sum(right < left - 0.000001 for left, right in zip(raw, raw[1:]))
        fixed_nonmonotonic = sum(right < left - 0.000001 for left, right in zip(fixed, fixed[1:]))
        invalid = sum(
            not all(math.isfinite(t) for t in (word["start"], word["end"]))
            or word["start"] < utterance["cropStart"] - 0.001
            or word["end"] > utterance["cropEnd"] + 0.001
            or word["end"] < word["start"]
            for word in words
        )
        if invalid or fixed_nonmonotonic:
            errors.append(f"Invalid fixed unit geometry at {index}")
        diagnostics.append({
            "index": index, "unitCount": len(words), "repairedUnits": repaired,
            "zeroDurationUnits": zero, "invalidUnits": invalid,
            "rawNonmonotonicEdges": raw_nonmonotonic, "fixedNonmonotonicEdges": fixed_nonmonotonic,
        })
    global_raw = [value for u in utterances for word in u["words"] for value in (word["rawStart"], word["rawEnd"])]
    return {
        "integrityPassed": not errors, "errors": errors,
        "accuracyValidated": False, "referenceUsed": False,
        "note": "Structural integrity is not timing truth. Raw nonmonotonic and repaired/zero-duration units remain uncertain.",
        "rawNonmonotonicUtterances": sum(d["rawNonmonotonicEdges"] > 0 for d in diagnostics),
        "rawNonmonotonicEdges": sum(d["rawNonmonotonicEdges"] for d in diagnostics),
        "wholeClipRawNonmonotonicEdges": sum(b < a - 0.000001 for a, b in zip(global_raw, global_raw[1:]))
            if alignment.get("mode") == "whole-clip" else None,
        "perUtterance": diagnostics,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--alignment", type=Path, required=True)
    parser.add_argument("--moss", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--harness-snapshot", type=Path)
    parser.add_argument("--expected-alignment-sha256")
    args = parser.parse_args()
    if args.output and args.output.exists():
        raise SystemExit("Refusing to overwrite a validation receipt")
    data = json.loads(args.alignment.read_text())
    report = validate(data, json.loads(args.moss.read_text()), sha256(args.moss))
    actual_hash = sha256(args.alignment)
    if args.expected_alignment_sha256 and actual_hash != args.expected_alignment_sha256:
        report["errors"].append("Alignment snapshot byte hash mismatch")
    if args.harness_snapshot and sha256(args.harness_snapshot) != data.get("harnessSHA256"):
        report["errors"].append("Executed harness snapshot byte hash mismatch")
    report["integrityPassed"] = not report["errors"]
    report.update({"alignmentSha256": actual_hash, "sourceMossSha256": sha256(args.moss),
                   "harnessSnapshotVerified": bool(args.harness_snapshot) and "Executed harness snapshot byte hash mismatch" not in report["errors"]})
    if args.output:
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    print(json.dumps({key: value for key, value in report.items() if key != "perUtterance"}))
    if not report["integrityPassed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
