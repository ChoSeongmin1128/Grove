#!/usr/bin/env python3
"""Summarize powermetrics and /usr/bin/time outputs for Grove."""

from __future__ import annotations

import argparse
import json
import re
import statistics
from pathlib import Path


POWER_PATTERNS = {
    "cpu_mw": re.compile(r"^CPU Power: ([0-9.]+) mW$", re.MULTILINE),
    "gpu_mw": re.compile(r"^GPU Power: ([0-9.]+) mW$", re.MULTILINE),
    "ane_mw": re.compile(r"^ANE Power: ([0-9.]+) mW$", re.MULTILINE),
    "combined_mw": re.compile(
        r"^Combined Power \(CPU \+ GPU \+ ANE\): ([0-9.]+) mW$", re.MULTILINE
    ),
}


def percentile(values: list[float], fraction: float) -> float:
    values = sorted(values)
    index = (len(values) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(values) - 1)
    weight = index - lower
    return values[lower] * (1 - weight) + values[upper] * weight


def power_summary(path: Path) -> dict:
    text = path.read_text(errors="replace")
    result = {key: [float(value) for value in pattern.findall(text)] for key, pattern in POWER_PATTERNS.items()}
    sample_counts = {key: len(values) for key, values in result.items()}
    if not result["combined_mw"]:
        raise ValueError(f"No power samples found in {path}")
    return {
        "path": str(path),
        "sample_count": min(sample_counts.values()),
        "sample_counts": sample_counts,
        "mean": {key: statistics.fmean(values) for key, values in result.items()},
        "median": {key: statistics.median(values) for key, values in result.items()},
        "p95": {key: percentile(values, 0.95) for key, values in result.items()},
    }


def time_summary(path: Path) -> dict:
    text = path.read_text()
    real_match = re.search(r"([0-9.]+) real", text)
    rss_match = re.search(r"^\s*(\d+)\s+maximum resident set size$", text, re.MULTILINE)
    footprint_match = re.search(r"^\s*(\d+)\s+peak memory footprint$", text, re.MULTILINE)
    if not real_match or not rss_match:
        raise ValueError(f"Incomplete time output: {path}")
    return {
        "wall_seconds": float(real_match.group(1)),
        "max_rss_bytes": int(rss_match.group(1)),
        "peak_memory_footprint_bytes": int(footprint_match.group(1)) if footprint_match else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--audio-seconds", type=float, default=989.7766875)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    idle = power_summary(args.run_dir / "idle-powermetrics.txt")
    engines = {}
    for name in ("apple", "whisperkit"):
        power = power_summary(args.run_dir / f"{name}-powermetrics.txt")
        timing = time_summary(args.run_dir / f"{name}-time.txt")
        net_mean = {
            key: power["mean"][key] - idle["mean"][key]
            for key in POWER_PATTERNS
        }
        raw_energy_joules = (
            power["mean"]["combined_mw"] / 1000 * timing["wall_seconds"]
        )
        energy_joules = net_mean["combined_mw"] / 1000 * timing["wall_seconds"]
        engines[name] = {
            "power": power,
            "timing": timing,
            "net_mean_power_mw_vs_idle": net_mean,
            "raw_system_energy_joules": raw_energy_joules,
            "incremental_energy_joules": energy_joules,
            "incremental_energy_joules_per_audio_minute": energy_joules
            / (args.audio_seconds / 60),
            "audio_real_time_factor": timing["wall_seconds"] / args.audio_seconds,
        }

    result = {
        "run_dir": str(args.run_dir),
        "audio_seconds": args.audio_seconds,
        "idle": idle,
        "engines": engines,
        "comparison": {
            "whisper_to_apple_wall_time_ratio": engines["whisperkit"]["timing"]["wall_seconds"]
            / engines["apple"]["timing"]["wall_seconds"],
            "whisper_to_apple_incremental_energy_ratio": engines["whisperkit"]["incremental_energy_joules"]
            / engines["apple"]["incremental_energy_joules"],
            "whisper_to_apple_raw_system_energy_ratio": engines["whisperkit"]["raw_system_energy_joules"]
            / engines["apple"]["raw_system_energy_joules"],
        },
        "caveat": "powermetrics is system-wide; idle subtraction reduces but does not eliminate unrelated workload noise",
    }
    output = args.output or args.run_dir / "power-summary.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
