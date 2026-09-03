import unittest
from copy import deepcopy
from pathlib import Path
import subprocess
import sys
import tempfile
from align_moss import crop_bounds, lexical, map_whole_units, moss_body
from validate_alignment import validate


class AlignmentContractTests(unittest.TestCase):
    def test_generated_prefix_only(self):
        self.assertEqual(moss_body({"text": "[S01] 합성 문장 [예시]", "speaker_id": "S01"}), ("합성 문장 [예시]", 6))
        self.assertEqual(moss_body({"text": "[S02] 합성 문장", "speaker_id": "S01"}), ("[S02] 합성 문장", 0))
        self.assertEqual(moss_body({"text": "[S01]  합성 문장", "speaker_id": "S01"}), (" 합성 문장", 6))
        self.assertEqual(moss_body({"text": "[S01]\t합성 문장", "speaker_id": "S01"}), ("[S01]\t합성 문장", 0))

    def test_crop_bounded_without_reference(self):
        self.assertEqual(crop_bounds(0.1, 1.1, 0.5, 32000, 16000), (0, 25600))
        self.assertEqual(crop_bounds(1.7, 2.0, 0.5, 32000, 16000), (19200, 32000))
        with self.assertRaises(ValueError):
            crop_bounds(2, 1, 0.5, 32000, 16000)

    def test_lexical_comparison_is_not_replacement(self):
        self.assertEqual(lexical("합성 1.2 테스트."), lexical("합성12테스트"))
        self.assertNotEqual(lexical("합성 다른 문장"), lexical("합성 문장"))

    def validation_fixture(self):
        segment = {"text": "[S01] 합성.", "speaker_id": "S01", "start": 0.2, "end": 0.9}
        utterance = {"index": 0, "text": "합성.", "rawText": segment["text"],
            "removedGeneratedPrefixLength": 6, "start": 0.2, "end": 0.9,
            "cropStart": 0, "cropEnd": 1.4, "words": [
                {"text": "합성", "start": 0.2, "end": 0.9, "rawStart": 0.2, "rawEnd": 0.9, "flags": []}]}
        return {"schemaVersion": 1, "referenceUsed": False, "sourceMossSha256": "synthetic", "utterances": [utterance]}, {"segments": [segment]}

    def test_validator_is_integrity_not_accuracy(self):
        aligned, source = self.validation_fixture()
        report = validate(aligned, source, "synthetic")
        self.assertTrue(report["integrityPassed"])
        self.assertFalse(report["accuracyValidated"])

    def test_validator_rejects_source_or_unit_changes(self):
        aligned, source = self.validation_fixture()
        changed = deepcopy(aligned)
        changed["utterances"][0]["text"] = "다른 문장"
        self.assertFalse(validate(changed, source, "synthetic")["integrityPassed"])
        changed = deepcopy(aligned)
        changed["utterances"][0]["words"] = []
        self.assertFalse(validate(changed, source, "synthetic")["integrityPassed"])

    def test_validator_keeps_raw_repair_diagnostics(self):
        aligned, source = self.validation_fixture()
        word = aligned["utterances"][0]["words"][0]
        word.update(start=0.5, end=0.5, rawStart=0.5, rawEnd=0.2,
                    flags=["zeroDuration", "upstreamTimestampRepair"])
        report = validate(aligned, source, "synthetic")
        self.assertTrue(report["integrityPassed"])
        self.assertEqual(report["rawNonmonotonicEdges"], 1)
        self.assertEqual(report["perUtterance"][0]["zeroDurationUnits"], 1)

    def test_validator_rejects_out_of_crop_timing(self):
        aligned, source = self.validation_fixture()
        aligned["utterances"][0]["words"][0]["end"] = 2
        self.assertFalse(validate(aligned, source, "synthetic")["integrityPassed"])

    def test_whole_mapping_preserves_original_offsets(self):
        words = [{"text": "합성", "start": 1, "end": 2, "flags": []},
                 {"text": "12", "start": 2, "end": 3, "flags": []}]
        mapped, unmapped = map_whole_units(["합성.", "1.2"], words)
        self.assertFalse(unmapped)
        self.assertEqual(mapped[1][0]["sourceCharStart"], 0)
        self.assertEqual(mapped[1][0]["sourceCharEnd"], 3)
        self.assertEqual(mapped[1][0]["sourceGlobalCharStart"], 4)

    def test_whole_crossing_preserves_text_without_timing_split(self):
        mapped, unmapped = map_whole_units(["합", "성"], [{"text": "합성", "start": 1, "end": 3, "flags": []}])
        self.assertFalse(unmapped)
        self.assertEqual([mapped[0][0]["text"], mapped[1][0]["text"]], ["합", "성"])
        for words in mapped:
            self.assertEqual((words[0]["start"], words[0]["end"]), (1, 3))
            self.assertTrue(words[0]["timeIsParentContext"])
            self.assertIn("crossesSourceUtteranceBoundary", words[0]["flags"])

    def test_whole_mapping_mismatch_is_not_guessed(self):
        mapped, unmapped = map_whole_units(["합성"], [{"text": "다름", "start": 1, "end": 2, "flags": []}])
        self.assertEqual(mapped, [[]])
        self.assertIn("sourceMappingFailed", unmapped[0]["flags"])

    def test_validator_rejects_reference_leak_or_boolean_index(self):
        aligned, source = self.validation_fixture()
        aligned["referenceUsed"] = None
        self.assertFalse(validate(aligned, source, "synthetic")["integrityPassed"])
        aligned["referenceUsed"] = False
        aligned["utterances"][0]["index"] = False
        self.assertFalse(validate(aligned, source, "synthetic")["integrityPassed"])

    def test_preparation_refuses_existing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("prepare_model.py")),
                "--directory", directory, "--manifest", str(manifest)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(manifest.exists())

    def test_preparation_refuses_active_cache_subdirectory(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path.home() / "Library/Application Support/Grove/research-aligner-must-not-create"
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("prepare_model.py")),
                "--directory", str(destination), "--manifest", str(Path(directory) / "manifest.json")], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
