#!/usr/bin/env python3
"""Export one Grove glossary A/B condition for Apple and WhisperKit."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from glossary_context import CONDITIONS, build_condition_terms, build_whisper_prompt, load_decoy_terms


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--condition", choices=CONDITIONS, required=True)
    parser.add_argument("--profile", default="example")
    parser.add_argument(
        "--glossary", type=Path, default=Path("tests/fixtures/domain-glossary.json")
    )
    parser.add_argument(
        "--speakers", type=Path, default=Path("tests/fixtures/speaker-hints.json")
    )
    parser.add_argument(
        "--decoys", type=Path, default=Path("tests/fixtures/glossary-decoys.json")
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    terms = build_condition_terms(
        args.condition,
        glossary_path=args.glossary,
        speaker_path=args.speakers,
        decoy_path=args.decoys,
        profile_name=args.profile,
    )
    decoys = load_decoy_terms(args.decoys) if args.condition == "domain-decoy" else []
    prompt, whisper_terms = build_whisper_prompt(terms, required_terms=decoys)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / f"{args.condition}-apple-context.json").write_text(
        json.dumps(terms, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output_dir / f"{args.condition}-whisper-prompt.txt").write_text(
        prompt + ("\n" if prompt else ""), encoding="utf-8"
    )
    (args.output_dir / f"{args.condition}-manifest.json").write_text(
        json.dumps(
            {
                "condition": args.condition,
                "profile": args.profile,
                "termCount": len(terms),
                "decoyCount": len(decoys),
                "terms": terms,
                "whisperTerms": whisper_terms,
                "decoys": decoys,
                "whisperPrompt": prompt,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"condition={args.condition} terms={len(terms)} decoys={len(decoys)}")


if __name__ == "__main__":
    main()
