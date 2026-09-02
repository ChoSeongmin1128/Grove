#!/usr/bin/env python3
"""Run all WAV clips through a loaded local WhisperKit server."""

from __future__ import annotations

import argparse
import json
import mimetypes
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path


def multipart_body(audio_path: Path, fields: dict[str, str]) -> tuple[bytes, str]:
    boundary = f"grove-{uuid.uuid4().hex}"
    chunks: list[bytes] = []
    for key, value in fields.items():
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode(),
                value.encode(),
                b"\r\n",
            ]
        )

    mime = mimetypes.guess_type(audio_path.name)[0] or "application/octet-stream"
    chunks.extend(
        [
            f"--{boundary}\r\n".encode(),
            (
                f'Content-Disposition: form-data; name="file"; '
                f'filename="{audio_path.name}"\r\n'
            ).encode(),
            f"Content-Type: {mime}\r\n\r\n".encode(),
            audio_path.read_bytes(),
            b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
    )
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def audio_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as wav:
        return wav.getnframes() / wav.getframerate()


def transcribe(
    server: str,
    audio_path: Path,
    model: str,
    timeout: float,
    prompt: str | None,
) -> str:
    fields = {
        "model": model,
        "language": "ko",
        "response_format": "json",
        "temperature": "0",
    }
    if prompt:
        fields["prompt"] = prompt
    body, content_type = multipart_body(
        audio_path,
        fields,
    )
    request = urllib.request.Request(
        f"{server.rstrip('/')}/v1/audio/transcriptions",
        data=body,
        headers={"Content-Type": content_type},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    return payload.get("text", "")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--server", default="http://127.0.0.1:50060")
    parser.add_argument("--model", default="large-v3-v20240930_626MB")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--limit", type=int)
    prompt_group = parser.add_mutually_exclusive_group()
    prompt_group.add_argument("--prompt")
    prompt_group.add_argument("--prompt-file", type=Path)
    parser.add_argument("--conditioning-mode", default="baseline")
    args = parser.parse_args()

    prompt = args.prompt
    if args.prompt_file:
        prompt = args.prompt_file.read_text(encoding="utf-8").strip()

    files = sorted(args.audio_dir.glob("*.wav"))
    if args.limit is not None:
        files = files[: args.limit]
    if not files:
        raise SystemExit(f"No WAV files found at {args.audio_dir}")

    args.output.parent.mkdir(parents=True, exist_ok=True)

    # Warm-up is excluded from measurements.
    transcribe(args.server, files[0], args.model, args.timeout, prompt)

    with args.output.open("w", encoding="utf-8") as output:
        for index, audio_path in enumerate(files, start=1):
            duration = audio_duration(audio_path)
            started = time.perf_counter()
            record = {
                "id": audio_path.stem,
                "engine": "whisperkit",
                "locale": "ko",
                "audioPath": str(audio_path),
                "audioDurationSeconds": duration,
                "conditioningMode": args.conditioning_mode,
                "promptCharacterCount": len(prompt or ""),
            }
            try:
                record["text"] = transcribe(
                    args.server, audio_path, args.model, args.timeout, prompt
                )
                record["error"] = None
            except (urllib.error.URLError, TimeoutError, ValueError) as error:
                record["text"] = None
                record["error"] = str(error)

            elapsed = time.perf_counter() - started
            record["processingSeconds"] = elapsed
            record["realTimeFactor"] = elapsed / duration if duration else 0
            output.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
            output.flush()
            print(f"[{index}/{len(files)}] {audio_path.stem} {elapsed:.3f}s")


if __name__ == "__main__":
    main()
