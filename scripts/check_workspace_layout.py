"""Validate window geometry captured by the debug QA profile, without UI actions."""

import argparse
import json
import re
from pathlib import Path


def rect(value):
    numbers = [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?", value)]
    if len(numbers) != 4:
        raise ValueError("Invalid rectangle")
    return numbers


def split_hosts(view):
    if "NavigationSplitRepresentable" in view["type"]:
        yield view
    for child in view.get("children", []):
        yield from split_hosts(child)


def check(rows):
    checked = 0
    outside = 0
    states = set()
    for row in rows:
        if "views" not in row:
            continue
        x, y, width, height = rect(row["contentFrame"])
        for view in split_hosts(row["views"]):
            sx, sy, sw, sh = rect(view["frame"])
            if min(width, height, sw, sh) <= 0:
                continue
            checked += 1
            if sx < x - 1 or sy < y - 1 or sx + sw > x + width + 1 or sy + sh > y + height + 1:
                outside += 1
            state = row.get("state", "")
            states.add("processing" if state.endswith(":true") else "meeting" if ".meeting(" in state else "library")
    if not checked:
        raise ValueError("No workspace frames captured")
    return {"samples": checked, "outside_window": outside, "states": sorted(states)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--require-transitions", action="store_true")
    args = parser.parse_args()
    try:
        result = check([json.loads(line) for line in args.log.read_text().splitlines() if line.strip()])
    except (OSError, ValueError, KeyError) as error:
        parser.exit(2, f"Cannot validate layout: {error}\n")
    print(json.dumps(result))
    missing = args.require_transitions and set(result["states"]) != {"library", "meeting", "processing"}
    return 1 if result["outside_window"] or missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
