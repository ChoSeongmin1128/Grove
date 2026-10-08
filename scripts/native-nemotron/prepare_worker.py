#!/usr/bin/env python3
import hashlib
import platform
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
URL = "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v0.2.0/nemo-speech-0.2.0-macos-aarch64-metal.tar.gz"
SHA256 = "5cb02ba7c04f0b5585ce5cde9c830be5f0b7dfb4c83083c500109c381b4f2da9"

if platform.system() != "Darwin" or platform.machine() != "arm64":
    raise SystemExit("This helper targets Apple Silicon macOS.")
destination = ROOT / ".work/native-workers/Nemotron"
if destination.exists():
    raise SystemExit("Nemotron helper already exists. Preserve it before preparing another runtime.")
(ROOT / ".work").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(dir=ROOT / ".work") as temporary:
    folder = Path(temporary)
    archive = folder / "runtime.tar.gz"
    urllib.request.urlretrieve(URL, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("Official runtime checksum mismatch.")
    with tarfile.open(archive) as compressed:
        compressed.extractall(folder / "unpacked", filter="data")
    source = folder / "unpacked/nemo-speech-0.2.0-macos-aarch64-metal"
    destination.mkdir(parents=True)
    for name in ("bin", "lib", "share"):
        shutil.copytree(source / name, destination / name, symlinks=True)
print(destination)
