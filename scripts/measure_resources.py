#!/usr/bin/env python3
"""Sample macOS process and memory resources while running a benchmark command."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
from collections import defaultdict
from pathlib import Path


def parse_cpu_time(value: str) -> float:
    value = value.strip()
    days = 0
    if "-" in value:
        day_text, value = value.split("-", 1)
        days = int(day_text)
    parts = value.split(":")
    if len(parts) == 3:
        hours, minutes, seconds = parts
    elif len(parts) == 2:
        hours = "0"
        minutes, seconds = parts
    else:
        hours = minutes = "0"
        seconds = parts[0]
    return days * 86400 + int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def process_snapshot() -> dict[int, dict]:
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,%cpu=,rss=,time=,comm="], text=True
    )
    processes: dict[int, dict] = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 5)
        if len(fields) != 6:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
            processes[pid] = {
                "pid": pid,
                "ppid": ppid,
                "cpu_percent": float(fields[2]),
                "rss_kb": int(fields[3]),
                "cpu_seconds": parse_cpu_time(fields[4]),
                "command": fields[5],
            }
        except ValueError:
            continue
    return processes


def descendants(processes: dict[int, dict], root_pid: int) -> set[int]:
    children: dict[int, list[int]] = defaultdict(list)
    for process in processes.values():
        children[process["ppid"]].append(process["pid"])
    found = {root_pid}
    pending = [root_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            if child not in found:
                found.add(child)
                pending.append(child)
    return found


def vm_stat() -> dict[str, int]:
    output = subprocess.check_output(["vm_stat"], text=True)
    page_size_match = re.search(r"page size of (\d+) bytes", output)
    page_size = int(page_size_match.group(1)) if page_size_match else 16384
    pages: dict[str, int] = {}
    for line in output.splitlines()[1:]:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        match = re.search(r"\d+", value.replace(".", ""))
        if match:
            pages[key.strip()] = int(match.group())
    free_pages = pages.get("Pages free", 0) + pages.get("Pages speculative", 0)
    active_pages = pages.get("Pages active", 0)
    inactive_pages = pages.get("Pages inactive", 0)
    wired_pages = pages.get("Pages wired down", 0)
    compressor_pages = pages.get("Pages occupied by compressor", 0)
    return {
        "free_bytes": free_pages * page_size,
        "active_bytes": active_pages * page_size,
        "inactive_bytes": inactive_pages * page_size,
        "wired_bytes": wired_pages * page_size,
        "compressor_bytes": compressor_pages * page_size,
        "pressure_bytes": (active_pages + wired_pages + compressor_pages) * page_size,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include-pattern", default="$^")
    parser.add_argument("--interval", type=float, default=0.1)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        raise SystemExit("A command is required after --")

    include = re.compile(args.include_pattern, re.IGNORECASE)
    baseline_processes = process_snapshot()
    baseline_vm = vm_stat()
    started = time.perf_counter()
    process = subprocess.Popen(
        args.command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    tracked: dict[int, dict] = {}
    tree_peak_rss = included_peak_rss = 0
    peak_pressure = baseline_vm["pressure_bytes"]
    minimum_free = baseline_vm["free_bytes"]
    samples = 0
    last_vm_sample = 0.0

    while process.poll() is None:
        snapshot = process_snapshot()
        tree = descendants(snapshot, process.pid)
        included = tree | {
            pid for pid, item in snapshot.items() if include.search(item["command"])
        }
        tree_peak_rss = max(
            tree_peak_rss, sum(snapshot[pid]["rss_kb"] for pid in tree if pid in snapshot)
        )
        included_peak_rss = max(
            included_peak_rss,
            sum(snapshot[pid]["rss_kb"] for pid in included if pid in snapshot),
        )
        for pid in included:
            if pid not in snapshot:
                continue
            item = snapshot[pid]
            record = tracked.setdefault(
                pid,
                {
                    "pid": pid,
                    "command": item["command"],
                    "first_cpu_seconds": item["cpu_seconds"],
                    "last_cpu_seconds": item["cpu_seconds"],
                    "baseline_cpu_seconds": baseline_processes.get(pid, item)["cpu_seconds"],
                    "min_rss_kb": item["rss_kb"],
                    "max_rss_kb": item["rss_kb"],
                    "max_cpu_percent": item["cpu_percent"],
                    "in_command_tree": pid in tree,
                },
            )
            record["last_cpu_seconds"] = max(record["last_cpu_seconds"], item["cpu_seconds"])
            record["min_rss_kb"] = min(record["min_rss_kb"], item["rss_kb"])
            record["max_rss_kb"] = max(record["max_rss_kb"], item["rss_kb"])
            record["max_cpu_percent"] = max(record["max_cpu_percent"], item["cpu_percent"])
            record["in_command_tree"] = record["in_command_tree"] or pid in tree

        now = time.perf_counter()
        if now - last_vm_sample >= 0.5:
            memory = vm_stat()
            peak_pressure = max(peak_pressure, memory["pressure_bytes"])
            minimum_free = min(minimum_free, memory["free_bytes"])
            last_vm_sample = now
        samples += 1
        time.sleep(args.interval)

    stderr = process.stderr.read() if process.stderr else ""
    wall_seconds = time.perf_counter() - started
    for record in tracked.values():
        record["cpu_delta_seconds"] = max(
            0.0, record["last_cpu_seconds"] - record["baseline_cpu_seconds"]
        )
        record["rss_growth_kb"] = record["max_rss_kb"] - record["min_rss_kb"]

    command_cpu = sum(
        record["cpu_delta_seconds"]
        for record in tracked.values()
        if record["in_command_tree"]
    )
    included_cpu = sum(record["cpu_delta_seconds"] for record in tracked.values())
    result = {
        "label": args.label,
        "command": args.command,
        "exit_code": process.returncode,
        "stderr": stderr[-4000:],
        "sample_interval_seconds": args.interval,
        "sample_count": samples,
        "wall_seconds": wall_seconds,
        "command_tree_peak_rss_kb": tree_peak_rss,
        "included_peak_rss_kb": included_peak_rss,
        "command_tree_cpu_seconds": command_cpu,
        "included_cpu_seconds": included_cpu,
        "baseline_vm": baseline_vm,
        "peak_pressure_bytes": peak_pressure,
        "pressure_growth_bytes": peak_pressure - baseline_vm["pressure_bytes"],
        "minimum_free_bytes": minimum_free,
        "processes": sorted(
            tracked.values(), key=lambda item: item["cpu_delta_seconds"], reverse=True
        ),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if process.returncode:
        raise SystemExit(process.returncode)


if __name__ == "__main__":
    main()
