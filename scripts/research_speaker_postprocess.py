#!/usr/bin/env python3
"""Frozen-posterior diarization ablations; no audio/model/reference is loaded.

Research only. The caller supplies private inputs and an unused output directory.
Outputs are not app-compatible replacements and must remain in ignored local storage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import time


PROTOCOL_VERSION = "limited-postprocess-v1"
CONDITIONS = {
    "baseline": {"onset": 0.5, "offset": 0.5, "maximumGapSeconds": 0.0},
    "hysteresis": {"onset": 0.55, "offset": 0.45, "maximumGapSeconds": 0.0},
    "gap-fill": {"onset": 0.5, "offset": 0.5, "maximumGapSeconds": 0.16},
}


def _finite_number(value: object, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{name} must be a finite number")
    return float(value)


def validate_posterior(raw: dict) -> tuple[list[list[float]], float, float, int]:
    if not isinstance(raw, dict):
        raise ValueError("Input must be a JSON object")
    duration = _finite_number(raw.get("durationSeconds"), "durationSeconds")
    frame_duration = _finite_number(raw.get("frameDurationSeconds"), "frameDurationSeconds")
    width = raw.get("maxSpeakers")
    if duration <= 0 or frame_duration <= 0:
        raise ValueError("Audio and frame duration must be positive")
    if type(width) is not int or not 1 <= width <= 64:
        raise ValueError("maxSpeakers must describe a positive, bounded column count")
    predictions = raw.get("rawPredictions")
    if not isinstance(predictions, list) or not predictions:
        raise ValueError("rawPredictions must contain frames")
    minimum_frames = math.ceil(duration / frame_duration - 1e-9)
    if not minimum_frames <= len(predictions) <= minimum_frames + 1:
        raise ValueError("Posterior frame coverage differs from audio duration")
    normalized = []
    for row in predictions:
        if not isinstance(row, list) or len(row) != width:
            raise ValueError("All posterior frames must match maxSpeakers")
        values = [_finite_number(value, "posterior probability") for value in row]
        if any(value < 0 or value > 1 for value in values):
            raise ValueError("Posterior probabilities must be in [0, 1]")
        normalized.append(values)
    return normalized, duration, frame_duration, width


def activity_masks(predictions: list[list[float]], onset: float, offset: float) -> list[list[bool]]:
    if not 0 <= offset <= onset <= 1:
        raise ValueError("Hysteresis requires 0 <= offset <= onset <= 1")
    current = [False] * len(predictions[0])
    masks = []
    for row in predictions:
        for speaker, probability in enumerate(row):
            if probability > onset:
                current[speaker] = True
            elif probability < offset:
                current[speaker] = False
            # Equality and the interior of the hysteresis band retain state.
        masks.append(current.copy())
    return masks


def fill_short_gaps(masks: list[list[bool]], frame_duration: float, maximum_gap: float) -> list[list[bool]]:
    """Fill bounded same-column holes, never across any other active speaker.

    Eligibility always uses the original masks, so column iteration order cannot
    manufacture a new bridge. Leading/trailing silence and longer gaps are kept.
    """
    filled = [row.copy() for row in masks]
    frame_limit = math.floor(maximum_gap / frame_duration + 1e-9)
    if frame_limit <= 0:
        return filled
    for speaker in range(len(masks[0])):
        index = 0
        while index < len(masks):
            if masks[index][speaker]:
                index += 1
                continue
            start = index
            while index < len(masks) and not masks[index][speaker]:
                index += 1
            if start == 0 or index == len(masks) or index - start > frame_limit:
                continue
            if any(any(active for other, active in enumerate(masks[frame]) if other != speaker)
                   for frame in range(start, index)):
                continue
            for frame in range(start, index):
                filled[frame][speaker] = True
    return filled


def _f32(value: float) -> float:
    return struct.unpack("f", struct.pack("f", value))[0]


def frame_time(frame: int, frame_duration: float) -> float:
    # Match the native helper: float32 multiplication, then two-decimal rounding.
    return math.floor(_f32(_f32(float(frame)) * _f32(frame_duration)) * 100 + 0.5) / 100


def segments_from_masks(masks: list[list[bool]], frame_duration: float, duration: float) -> list[dict]:
    segments = []
    for speaker in range(len(masks[0])):
        start = None
        for frame in range(len(masks) + 1):
            active = frame < len(masks) and masks[frame][speaker]
            if active and start is None:
                start = frame
            elif not active and start is not None:
                left, right = frame_time(start, frame_duration), min(frame_time(frame, frame_duration), duration)
                if right > left:
                    segments.append({"start": left, "end": right, "speaker": str(speaker)})
                start = None
    return sorted(segments, key=lambda row: (row["start"], row["speaker"]))


def postprocess(raw: dict, condition: str) -> tuple[list[dict], dict]:
    if condition not in CONDITIONS:
        raise ValueError("Unknown preregistered condition")
    predictions, duration, frame_duration, width = validate_posterior(raw)
    parameters = CONDITIONS[condition]
    masks = activity_masks(predictions, parameters["onset"], parameters["offset"])
    if parameters["maximumGapSeconds"]:
        masks = fill_short_gaps(masks, frame_duration, parameters["maximumGapSeconds"])
    return segments_from_masks(masks, frame_duration, duration), {
        "params": dict(parameters), "frameDuration": frame_duration,
        "duration": duration, "frameCount": len(predictions), "maxSpeakers": width,
    }


def _turns(value: dict) -> list[tuple[float, float, str]]:
    segments = value.get("segments")
    if not isinstance(segments, list):
        raise ValueError("Baseline must contain segments")
    turns = []
    for row in segments:
        left = _finite_number(row.get("start"), "segment start")
        right = _finite_number(row.get("end"), "segment end")
        if not 0 <= left < right or not isinstance(row.get("speaker"), str):
            raise ValueError("Malformed baseline turn")
        turns.append((left, right, row["speaker"]))
    return sorted(turns)


def assert_baseline_parity(raw: dict, baseline: dict, segments: list[dict]) -> None:
    if baseline.get("engine") != "ultra8" or baseline.get("postprocessing") != "nemo-default-0.5":
        raise ValueError("Expected the current Ultra8 NeMo-default baseline")
    if baseline.get("durationSeconds") != raw.get("durationSeconds"):
        raise ValueError("Baseline and raw duration differ")
    if baseline.get("maxSpeakers") != raw.get("maxSpeakers"):
        raise ValueError("Baseline and raw capacities differ")
    if baseline.get("frameCount") != len(raw["rawPredictions"]):
        raise ValueError("Baseline and raw frame counts differ")
    if _turns(baseline) != _turns({"segments": segments}):
        raise ValueError("Raw-posterior default output does not exactly reproduce app baseline turns")
    digest = baseline.get("modelSHA256")
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError("Baseline must record a model SHA256")


def _write_new(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")


def run(raw_path: Path, baseline_path: Path, output_directory: Path) -> dict:
    raw_bytes, baseline_bytes = raw_path.read_bytes(), baseline_path.read_bytes()
    raw, baseline = json.loads(raw_bytes), json.loads(baseline_bytes)
    baseline_segments, _ = postprocess(raw, "baseline")
    assert_baseline_parity(raw, baseline, baseline_segments)
    common = {
        "version": PROTOCOL_VERSION,
        "rawSHA": hashlib.sha256(raw_bytes).hexdigest(),
        "baselineSHA": hashlib.sha256(baseline_bytes).hexdigest(),
        "modelSHA": baseline["modelSHA256"], "modelRevision": baseline.get("modelRevision"),
        "baselineTurnParity": True, "baselinePosteriorParity": "not-available",
        "modelInferenceRerun": False, "referenceRead": False,
        "evaluationRole": "development-ablation-not-held-out",
        "timingScope": "postprocessing-and-validation-only-not-model-inference",
        "sourceColumnIdentityPreserved": True, "minimumSpeechPruning": False,
        "speakerCountConstraint": None,
    }
    # Exclusive directory creation protects both prior experiments and source files.
    output_directory.mkdir(parents=True, exist_ok=False)
    _write_new(output_directory / "preregister.json", {
        "protocol": common, "conditions": CONDITIONS,
        "notes": [
            "Each condition independently starts from the same frozen posterior.",
            "Gap filling uses baseline activity and refuses any competing speaker in the gap.",
            "No minimum-speech pruning, speaker merging, exact-count enforcement or grid search.",
            "The development sample was previously inspected; this is not a held-out evaluation.",
            "Baseline turn equality does not prove numerical posterior equality across inference runs.",
        ],
    })
    outputs = []
    for condition in CONDITIONS:
        started = time.perf_counter()
        segments, details = postprocess(raw, condition)
        elapsed = time.perf_counter() - started
        filename = condition + ".json"
        _write_new(output_directory / filename, {
            "condition": condition,
            "protocol": dict(common, **details, seconds=elapsed),
            "segments": segments,
        })
        outputs.append({"condition": condition, "path": filename})
    manifest = {"protocol": common, "outputs": outputs}
    _write_new(output_directory / "manifest.json", manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args.raw, args.baseline, args.output_dir)
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(1, f"Postprocessing aborted: {error}\n")
    print(f"Postprocessing complete: {args.output_dir / 'manifest.json'}")


if __name__ == "__main__":
    main()
