#!/usr/bin/env python3
"""Compare two caller-supplied normalized diarization outputs, without inference."""
import argparse
import json
from pathlib import Path


def turns(path: Path) -> list[tuple[float, float, str]]:
    value = json.loads(path.read_text(encoding="utf-8"))
    return sorted((float(row["start"]), float(row["end"]), str(row["speaker"]))
                  for row in value["segments"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    args = parser.parse_args()
    expected, actual = turns(args.expected), turns(args.actual)
    if expected != actual:
        first = next((index for index, pair in enumerate(zip(expected, actual))
                      if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise SystemExit(f"Mismatch at turn {first}; counts {len(expected)} vs {len(actual)}")
    print(json.dumps({"exactTurnParity": True, "turnCount": len(actual),
                      "speakerCount": len({row[2] for row in actual})}))


if __name__ == "__main__":
    main()
