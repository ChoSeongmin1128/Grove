import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from glossary_context import build_condition_terms, build_whisper_prompt, load_decoy_terms  # noqa: E402


class GlossaryContextTests(unittest.TestCase):
    def setUp(self) -> None:
        self.arguments = {
            "glossary_path": ROOT / "tests/fixtures/domain-glossary.json",
            "speaker_path": ROOT / "tests/fixtures/speaker-hints.json",
            "decoy_path": ROOT / "tests/fixtures/glossary-decoys.json",
            "profile_name": "example",
        }

    def test_baseline_has_no_context(self) -> None:
        self.assertEqual(build_condition_terms("baseline", **self.arguments), [])

    def test_domain_uses_only_approved_observed_terms(self) -> None:
        terms = build_condition_terms("domain", **self.arguments)
        self.assertIn("SwiftUI", terms)
        self.assertIn("스위프트 유아이", terms)
        self.assertIn("Speaker One", terms)
        self.assertNotIn("스위프트유아이", terms)
        self.assertNotIn("양자정원 프로토콜", terms)

    def test_decoy_condition_adds_every_decoy(self) -> None:
        domain_terms = build_condition_terms("domain", **self.arguments)
        terms = build_condition_terms("domain-decoy", **self.arguments)
        decoys = load_decoy_terms(self.arguments["decoy_path"])
        self.assertTrue(set(decoys).issubset(terms))
        _, domain_prompt_terms = build_whisper_prompt(domain_terms)
        prompt, prompt_terms = build_whisper_prompt(terms, required_terms=decoys)
        self.assertGreater(len(prompt), len(build_whisper_prompt(domain_terms)[0]))
        self.assertEqual(prompt_terms[: len(domain_prompt_terms)], domain_prompt_terms)
        self.assertTrue(set(decoys).issubset(prompt_terms))


if __name__ == "__main__":
    unittest.main()
