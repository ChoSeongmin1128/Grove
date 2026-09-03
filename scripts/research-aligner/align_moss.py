#!/usr/bin/env python3
"""Research-only local alignment of unchanged MOSS segment bodies.

No reference labels are read, and no proportional character-to-time split is used.
The upstream aligner's repaired timestamps are retained and explicitly marked.
"""
import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import re
import resource
import sys
import threading
import time
import unicodedata
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def moss_body(segment):
    """Match Grove's leading generated-label removal, not a text correction."""
    text = segment["text"]
    label = str(segment.get("speaker_id", ""))
    prefix = f"[{label}] "
    if re.fullmatch(r"S[0-9]+", label) and text.startswith(prefix):
        return text[len(prefix):], len(prefix)
    return text, 0


def lexical(value):
    return "".join(c for c in unicodedata.normalize("NFKC", value).lower() if c.isalnum())


def crop_bounds(start, end, padding, frame_count, sample_rate):
    if not all(math.isfinite(value) for value in (start, end, padding)) or start < 0 or end < start or padding < 0:
        raise ValueError("Invalid source segment bounds")
    first = max(0, math.floor((start - padding) * sample_rate))
    last = min(frame_count, math.ceil((end + padding) * sample_rate))
    if last <= first:
        raise ValueError("Empty alignment crop")
    return first, last


def decode_words(aligned, raw, offset, crop_end):
    if len(raw) != 2 * len(aligned.items):
        raise ValueError("Raw timestamp and returned unit lengths disagree")
    words = []
    for unit_index, item in enumerate(aligned.items):
        local_start, local_end = float(item.start_time), float(item.end_time)
        raw_start, raw_end = float(raw[unit_index * 2]) / 1000, float(raw[unit_index * 2 + 1]) / 1000
        flags = []
        if not all(math.isfinite(t) for t in (local_start, local_end, raw_start, raw_end)):
            raise ValueError("Non-finite timestamp from aligner")
        if local_start < 0 or local_end < local_start or offset + local_end > crop_end + 0.001:
            flags.append("outsideCropOrInvalid")
        if local_start == local_end:
            flags.append("zeroDuration")
        if abs(local_start - raw_start) > 0.001 or abs(local_end - raw_end) > 0.001:
            flags.append("upstreamTimestampRepair")
        words.append({
            "text": item.text, "start": offset + local_start, "end": offset + local_end,
            "localStart": local_start, "localEnd": local_end,
            "rawStart": offset + raw_start, "rawEnd": offset + raw_end,
            "flags": flags,
        })
    return words


def kept(character):
    return character == "'" or unicodedata.category(character).startswith(("L", "N"))


def map_whole_units(texts, words):
    """Exact sequential Unicode mapping, never time-based or approximate matching."""
    source = []
    offset = 0
    for parent, text in enumerate(texts):
        for local, character in enumerate(text):
            if kept(character):
                source.append((character, parent, local, offset + local))
        offset += len(text) + 1
    target = "".join(c for word in words for c in word["text"] if kept(c))
    if target != "".join(item[0] for item in source):
        failed = [dict(word, flags=[*word["flags"], "sourceMappingFailed"]) for word in words]
        return [[] for _ in texts], failed
    mapped = [[] for _ in texts]
    cursor = 0
    for unit_index, word in enumerate(words):
        characters = [c for c in word["text"] if kept(c)]
        refs = source[cursor:cursor + len(characters)]
        cursor += len(characters)
        if not refs:
            raise ValueError("Empty lexical unit cannot be assigned to a source parent")
        parents = list(dict.fromkeys(ref[1] for ref in refs))
        for portion_index, parent in enumerate(parents):
            portion = [ref for ref in refs if ref[1] == parent]
            crossing = len(parents) > 1
            value = dict(word, alignmentUnitIndex=unit_index, alignmentUnitText=word["text"],
                portionIndex=portion_index, sourceCharStart=portion[0][2], sourceCharEnd=portion[-1][2] + 1,
                sourceGlobalCharStart=portion[0][3], sourceGlobalCharEnd=portion[-1][3] + 1,
                sourceOffsetEncoding="Unicode-codepoint-half-open", timeIsParentContext=crossing)
            if crossing:
                value["text"] = "".join(ref[0] for ref in portion)
                value["flags"] = [*word["flags"], "crossesSourceUtteranceBoundary"]
            mapped[parent].append(value)
    return mapped, []


class RSSSampler:
    def __init__(self, memory_limit=0):
        self.stop_event = threading.Event()
        self.peak = 0
        self.sample_count = 0
        self.children_included = True
        self.memory_limit = memory_limit
        self.memory_getter = None
        self.peak_mlx_live = 0
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self):
        import psutil
        process = psutil.Process()
        while not self.stop_event.is_set():
            total = 0
            try:
                children = process.children(recursive=True)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                children = []
                self.children_included = False
            for child in [process, *children]:
                try:
                    total += child.memory_info().rss
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            self.peak = max(self.peak, total)
            self.sample_count += 1
            if self.memory_getter is not None:
                self.peak_mlx_live = max(self.peak_mlx_live, self.memory_getter())
            if self.memory_limit and max(self.peak_mlx_live, total) > self.memory_limit:
                print("MEMORY_GUARD_ABORT: own process RSS or MLX live allocation exceeded configured bound", file=sys.stderr, flush=True)
                os._exit(75)
            self.stop_event.wait(0.05)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--moss", type=Path, required=True)
    parser.add_argument("--model-directory", type=Path, required=True)
    parser.add_argument("--model-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--padding", type=float, default=0.5)
    parser.add_argument("--mode", choices=("per-utterance", "whole-clip"), default="per-utterance")
    parser.add_argument("--memory-limit-gib", type=float, default=12)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit("Refusing to replace an existing alignment")
    if not args.model_directory.is_dir():
        raise SystemExit("A prepared local model directory is required")
    if not math.isfinite(args.memory_limit_gib) or not 0 < args.memory_limit_gib <= 12:
        raise SystemExit("The memory guard must be positive and no more than 12 GiB")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    started = time.perf_counter()
    memory_limit = int(args.memory_limit_gib * 1024 ** 3) if args.mode == "whole-clip" else 0
    sampler = RSSSampler(memory_limit=memory_limit)
    sampler.thread.start()
    import mlx.core as mx
    import soundfile as sf
    from mlx_audio.stt import load
    if memory_limit:
        mx.set_memory_limit(memory_limit)
        sampler.memory_getter = lambda: mx.get_active_memory() + mx.get_cache_memory()

    model_manifest = json.loads(args.model_manifest.read_text(encoding="utf-8"))
    for item in model_manifest["files"]:
        local = args.model_directory / item["name"]
        if local.stat().st_size != item["size"] or sha256(local) != item["sha256"]:
            raise ValueError("Prepared model contents no longer match the pinned manifest")
    moss_sha = sha256(args.moss)
    audio_sha = sha256(args.audio)
    moss = json.loads(args.moss.read_text(encoding="utf-8"))
    if moss.get("hitTokenLimit") or moss.get("hasUnparsedText"):
        raise ValueError("The frozen MOSS output is incomplete")
    info = sf.info(args.audio)
    if info.samplerate != 16_000 or info.channels != 1:
        raise ValueError("This harness requires a pre-existing mono 16kHz source; it does not rewrite audio")
    if abs(info.duration - float(moss["audioDurationSeconds"])) > 1 / info.samplerate:
        raise ValueError("Audio duration does not match the frozen MOSS output")
    load_started = time.perf_counter()
    model = load(args.model_directory)
    if getattr(model.config, "model_type", None) != "qwen3_forced_aligner" or not hasattr(model, "aligner_processor"):
        raise ValueError("The local model did not load as a forced aligner")
    mx.eval(model.parameters())
    load_seconds = time.perf_counter() - load_started
    # Capture the model's own raw timestamp predictions before its standard LIS repair.
    # This wrapper observes the output; it does not change timestamp postprocessing.
    original_parse = model.aligner_processor.parse_timestamp
    captured = {}

    def observe_parse(word_list, timestamp):
        captured["rawMilliseconds"] = timestamp.tolist()
        return original_parse(word_list, timestamp)

    model.aligner_processor.parse_timestamp = observe_parse
    utterances = []
    unmapped_words = []
    full_input_text = None
    inference_started = time.perf_counter()
    if args.mode == "whole-clip":
        if info.duration > 300:
            raise ValueError("Whole-clip input exceeds the official five-minute contract")
        source_bodies = [moss_body(segment)[0] for segment in moss["segments"]]
        full_input_text = " ".join(source_bodies)
        audio, _ = sf.read(args.audio, dtype="float32", always_2d=False)
        captured.clear()
        aligned = model.generate(audio=audio, text=full_input_text, language="Korean")
        all_words = decode_words(aligned, captured["rawMilliseconds"], 0, info.duration)
        mapped, unmapped_words = map_whole_units(source_bodies, all_words)
        for index, (segment, words) in enumerate(zip(moss["segments"], mapped)):
            text, prefix_length = moss_body(segment)
            utterances.append({
                "index": index, "text": text, "rawText": segment["text"],
                "removedGeneratedPrefixLength": prefix_length,
                "start": float(segment["start"]), "end": float(segment["end"]),
                "asrChunkIndex": segment.get("asr_chunk"), "sourceStartOffset": 0,
                "cropStart": 0, "cropEnd": info.duration, "cropStartFrame": 0, "cropEndFrame": info.frames,
                "lexicalContentPreserved": lexical("".join(w["text"] for w in words)) == lexical(text),
                "alignmentCallIndex": 0, "alignmentSeconds": None, "words": words,
            })
        print(f"wholeClip units={len(all_words)} unmapped={len(unmapped_words)} seconds={time.perf_counter() - inference_started:.3f}", flush=True)
    else:
        with sf.SoundFile(args.audio) as source:
            for index, segment in enumerate(moss["segments"]):
                text, prefix_length = moss_body(segment)
                start, end = float(segment["start"]), float(segment["end"])
                first, last = crop_bounds(start, end, args.padding, info.frames, info.samplerate)
                source.seek(first)
                audio = source.read(last - first, dtype="float32", always_2d=False)
                captured.clear()
                before = time.perf_counter()
                aligned = model.generate(audio=audio, text=text, language="Korean")
                elapsed = time.perf_counter() - before
                offset = first / info.samplerate
                crop_end = last / info.samplerate
                words = decode_words(aligned, captured["rawMilliseconds"], offset, crop_end)
                preserved = lexical("".join(item["text"] for item in words)) == lexical(text)
                utterances.append({
                    "index": index, "text": text, "rawText": segment["text"],
                    "removedGeneratedPrefixLength": prefix_length, "start": start, "end": end,
                    "asrChunkIndex": segment.get("asr_chunk"), "sourceStartOffset": offset,
                    "cropStart": offset, "cropEnd": crop_end, "cropStartFrame": first, "cropEndFrame": last,
                    "lexicalContentPreserved": preserved, "alignmentSeconds": elapsed, "words": words,
                })
                print(f"utterance={index} units={len(words)} flags={sum(bool(w['flags']) for w in words)} lexicalPreserved={preserved} seconds={elapsed:.3f}", flush=True)
    alignment_seconds = time.perf_counter() - inference_started
    if sha256(args.audio) != audio_sha or sha256(args.moss) != moss_sha:
        raise ValueError("Input changed during alignment")
    sampler.stop_event.set()
    sampler.thread.join(timeout=1)
    dependencies = {d.metadata["Name"]: d.version for d in importlib.metadata.distributions()}
    units = [word for utterance in utterances for word in utterance["words"]]
    result = {
        "schemaVersion": 1, "sourceMossSha256": moss_sha, "sourceAudioSha256": audio_sha,
        "harnessSHA256": sha256(Path(__file__)), "command": sys.argv,
        "model": model_manifest["model"], "revision": model_manifest["revision"],
        "modelManifest": model_manifest, "runtime": dependencies, "python": sys.version,
        "platform": platform.platform(), "language": "Korean", "referenceUsed": False,
        "condition": "moss-whole-clip-v1" if args.mode == "whole-clip" else "moss-per-utterance-crop-v1",
        "mode": args.mode, "alignmentCallCount": 1 if args.mode == "whole-clip" else len(utterances),
        "paddingSeconds": args.padding if args.mode == "per-utterance" else 0,
        "fullInputText": full_input_text, "joinSeparator": " " if full_input_text is not None else None,
        "sourceMappingFailed": bool(unmapped_words), "unmappedWords": unmapped_words,
        "memoryGuardBytes": memory_limit, "sampledMLXLivePeakBytes": sampler.peak_mlx_live,
        "memoryGuardPolicy": "MLX guideline plus sampled own-process guard; not an absolute OS allocation cap" if memory_limit else None,
        "modelTimestampQuantumSeconds": float(model.config.timestamp_segment_time) / 1000,
        "sourceTextPolicy": "unchanged body; remove only matching generated leading speaker label",
        "unitPolicy": "upstream Korean tokenizer; punctuation retained in original text, not necessarily in units",
        "timestampPolicy": "upstream predicted timestamps plus standard LIS repair; raw values and repaired flags retained",
        "sourcePaths": {"audio": str(args.audio.resolve()), "moss": str(args.moss.resolve())},
        "audioDuration": info.duration, "sampleRate": info.samplerate,
        "modelLoadSeconds": load_seconds, "alignmentSeconds": alignment_seconds,
        "processSeconds": time.perf_counter() - started,
        "peakProcessTreeRSSBytes": sampler.peak, "rssSampleCount": sampler.sample_count,
        "rssIncludesChildren": sampler.children_included,
        "rssSamplingSeconds": 0.05, "processMaxRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "mlxPeakBytes": mx.get_peak_memory(),
        "summary": {"utteranceCount": len(utterances), "unitCount": len(units),
            "lexicalMismatchUtterances": sum(not u["lexicalContentPreserved"] for u in utterances),
            "flaggedUnits": sum(bool(w["flags"]) for w in units),
            "timestampRepairedUnits": sum("upstreamTimestampRepair" in w["flags"] for w in units),
            "zeroDurationUnits": sum("zeroDuration" in w["flags"] for w in units),
            "invalidUnits": sum("outsideCropOrInvalid" in w["flags"] for w in units)},
        "utterances": utterances,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")
    print(json.dumps(result["summary"]))


if __name__ == "__main__":
    main()
