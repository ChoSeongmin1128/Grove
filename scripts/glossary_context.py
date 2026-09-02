#!/usr/bin/env python3
"""Build approved and decoy context inputs from Grove's source-backed glossary."""

from __future__ import annotations

import json
from pathlib import Path


CONDITIONS = ("baseline", "domain", "domain-decoy")


def deduplicate(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized = value.strip()
        if normalized and normalized.casefold() not in seen:
            result.append(normalized)
            seen.add(normalized.casefold())
    return result


def load_domain_terms(
    glossary_path: Path,
    profile_name: str,
    *,
    include_generated_hints: bool = False,
) -> list[str]:
    document = json.loads(glossary_path.read_text(encoding="utf-8"))
    profile = document["profiles"][profile_name]
    scope_tags = set(profile["scopeTags"])
    entries = [
        entry
        for entry in document["entries"]
        if scope_tags.intersection(entry["scopeTags"])
    ]
    entries.sort(key=lambda entry: (-entry["priority"], entry["id"]))

    terms: list[str] = []
    for entry in entries:
        terms.append(entry["canonical"])
        terms.extend(entry.get("observedForms", []))
        if include_generated_hints:
            terms.extend(entry.get("generatedSpokenHints", []))
    return deduplicate(terms)[: int(profile["maxHints"])]


def load_speaker_terms(speaker_path: Path) -> list[str]:
    document = json.loads(speaker_path.read_text(encoding="utf-8"))
    terms: list[str] = []
    for speaker in document["speakers"]:
        if speaker.get("coreMeetingSpeakerCandidate"):
            terms.append(speaker["displayName"])
            korean_hints = [
                hint
                for hint in speaker.get("observedNameHints", [])
                if any("가" <= character <= "힣" for character in hint)
            ]
            terms.extend(korean_hints[:2])
    return deduplicate(terms)


def load_decoy_terms(decoy_path: Path) -> list[str]:
    document = json.loads(decoy_path.read_text(encoding="utf-8"))
    return deduplicate(document["terms"])


def build_condition_terms(
    condition: str,
    *,
    glossary_path: Path,
    speaker_path: Path,
    decoy_path: Path,
    profile_name: str,
) -> list[str]:
    if condition not in CONDITIONS:
        raise ValueError(f"Unsupported condition: {condition}")
    if condition == "baseline":
        return []

    terms = load_speaker_terms(speaker_path)
    terms.extend(load_domain_terms(glossary_path, profile_name))
    if condition == "domain-decoy":
        terms.extend(load_decoy_terms(decoy_path))
    return deduplicate(terms)


def build_whisper_prompt(
    terms: list[str],
    *,
    required_terms: list[str] | None = None,
    maximum_characters: int = 190,
) -> tuple[str, list[str]]:
    if not terms:
        return "", []
    prefix = "회의에서 다음 고유명사와 전문 용어가 등장할 수 있습니다: "
    required = deduplicate(required_terms or [])
    required_keys = {term.casefold() for term in required}
    optional = [term for term in terms if term.casefold() not in required_keys]
    optional_selected: list[str] = []
    for term in optional:
        candidate = [*optional_selected, term]
        if len(prefix + ", ".join(candidate)) <= maximum_characters:
            optional_selected.append(term)
    selected = [*optional_selected, *required]
    # The domain-only portion is selected independently of required decoys, so
    # domain and domain-decoy remain a paired experiment whose only difference
    # is the appended decoy set. Required terms may therefore exceed the soft
    # character budget and must be checked against WhisperKit's 223-token
    # effective prompt limit. The conservative 190-character base budget keeps
    # the current base+decoy fixtures below that limit; the direct Swift app must
    # still tokenize and validate every future glossary snapshot.
    prompt = prefix + ", ".join(selected)
    return prompt, selected
