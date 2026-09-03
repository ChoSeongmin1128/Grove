#!/usr/bin/env python3
"""Download only a pinned public aligner into an explicitly supplied local directory."""
import argparse
import hashlib
import json
import time
from pathlib import Path

MODEL = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"
REVISION = "0e1a68e91d815300c7c9754b2a7639378b23db15"
UPSTREAM_MODEL = "Qwen/Qwen3-ForcedAligner-0.6B"
UPSTREAM_REVISION = "c7cbfc2048c462b0d63a45797104fc9db3ad62b7"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    destination = args.directory.expanduser().resolve()
    protected = [Path("/Applications"), (Path.home() / "Library").resolve(),
                 (Path.home() / ".cache/huggingface").resolve()]
    if destination.exists():
        raise SystemExit("A new, non-existing model directory is required; existing snapshots are never replaced")
    if any(destination == path or path in destination.parents for path in protected):
        raise SystemExit("Refusing to create a research model inside installed apps or active user model caches")
    if args.manifest.exists():
        raise SystemExit("Refusing to replace an existing model manifest")
    from huggingface_hub import snapshot_download
    before = time.perf_counter()
    snapshot_download(MODEL, revision=REVISION, local_dir=destination, token=False)
    elapsed = time.perf_counter() - before
    files = [
        {"name": str(path.relative_to(destination)), "size": path.stat().st_size, "sha256": sha256(path)}
        for path in sorted(destination.rglob("*"))
        if path.is_file() and ".cache" not in path.parts
    ]
    result = {
        "model": MODEL, "revision": REVISION,
        "upstreamModel": UPSTREAM_MODEL, "upstreamRevisionAtInspection": UPSTREAM_REVISION,
        "conversionParityVerified": False, "downloadSeconds": elapsed,
        "modelBytes": sum(item["size"] for item in files), "files": files,
        "sources": [f"https://huggingface.co/{UPSTREAM_MODEL}", f"https://huggingface.co/{MODEL}/tree/{REVISION}"],
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    with args.manifest.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps({key: value for key, value in result.items() if key != "files"}))


if __name__ == "__main__":
    main()
