# Nemotron 3 native runtime

Build preparation uses the official NeMo-Speech.cpp 0.2.0 Apple Silicon Metal archive.
The archive is pinned by SHA256 in `prepare_worker.py` and includes runtime licenses.

```bash
python3 scripts/native-nemotron/prepare_worker.py
```

Packaging embeds the executable and dynamic libraries. Configuration examples and
license texts belong under Resources rather than executable-only Helpers directories.
Weights are separately downloaded and verified by the app. No Python, compiler or
separate CLI installation is required on the user's Mac.

The model is limited to eight automatic speaker slots. It cannot enforce an exact count.
