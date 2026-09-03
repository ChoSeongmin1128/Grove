"""Synthetic-only tests: no private recordings, transcripts or reference constants."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/research_speaker_postprocess.py"
SPEC = importlib.util.spec_from_file_location("research_speaker_postprocess", SCRIPT)
post = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(post)


def raw(frames, duration=None):
    return {"rawPredictions": frames, "frameDurationSeconds": 0.08,
            "durationSeconds": duration if duration is not None else len(frames) * 0.08,
            "maxSpeakers": len(frames[0])}


def baseline(value):
    segments, _ = post.postprocess(value, "baseline")
    return {"engine": "ultra8", "postprocessing": "nemo-default-0.5",
            "durationSeconds": value["durationSeconds"], "maxSpeakers": value["maxSpeakers"],
            "frameCount": len(value["rawPredictions"]), "modelSHA256": "a" * 64,
            "modelRevision": "synthetic", "segments": segments}


class SpeakerPostprocessTests(unittest.TestCase):
    def test_threshold_equality_retains_state_and_single_frame_speech_survives(self):
        value = raw([[0.5], [0.6], [0.5], [0.4], [0.6], [0.1]])
        result, _ = post.postprocess(value, "baseline")
        self.assertEqual(result, [{"start": 0.08, "end": 0.24, "speaker": "0"},
                                  {"start": 0.32, "end": 0.4, "speaker": "0"}])

    def test_hysteresis_band_is_not_a_minimum_duration_filter(self):
        value = raw([[0.54], [0.56], [0.5], [0.45], [0.44], [0.7], [0.2]])
        result, _ = post.postprocess(value, "hysteresis")
        self.assertEqual(result, [{"start": 0.08, "end": 0.32, "speaker": "0"},
                                  {"start": 0.4, "end": 0.48, "speaker": "0"}])

    def test_gap_limit_is_inclusive_but_longer_gap_is_unchanged(self):
        masks = [[True], [False], [False], [True], [False], [False], [False], [True]]
        original = copy.deepcopy(masks)
        result = post.fill_short_gaps(masks, 0.08, 0.16)
        self.assertEqual(result, [[True], [True], [True], [True], [False], [False], [False], [True]])
        self.assertEqual(masks, original)

    def test_competing_speaker_blocks_bridge_and_never_merges_columns(self):
        value = raw([[0.9, 0.1], [0.1, 0.9], [0.9, 0.1]])
        plain, _ = post.postprocess(value, "baseline")
        filled, _ = post.postprocess(value, "gap-fill")
        self.assertEqual(filled, plain)
        self.assertEqual({segment["speaker"] for segment in filled}, {"0", "1"})

    def test_only_bounded_gaps_fill_and_conditions_do_not_stack(self):
        value = raw([[0.1], [0.51], [0.3], [0.51], [0.1]])
        filled, _ = post.postprocess(value, "gap-fill")
        hysteresis, _ = post.postprocess(value, "hysteresis")
        self.assertEqual(filled, [{"start": 0.08, "end": 0.32, "speaker": "0"}])
        self.assertEqual(hysteresis, [])

    def test_overlapping_columns_preserved_and_duration_tail_clipped(self):
        value = raw([[0.9, 0.9], [0.9, 0.9], [0.9, 0.9]], duration=0.16)
        result, _ = post.postprocess(value, "baseline")
        self.assertEqual(result, [{"start": 0.0, "end": 0.16, "speaker": "0"},
                                  {"start": 0.0, "end": 0.16, "speaker": "1"}])

    def test_bad_probability_shape_or_coverage_is_rejected(self):
        valid = raw([[0.2, 0.1], [0.8, 0.9]])
        variants = []
        for bad in (float("nan"), float("inf"), -0.1, 1.1, True, "0.9"):
            item = copy.deepcopy(valid)
            item["rawPredictions"][0][0] = bad
            variants.append(item)
        for key, bad in (("durationSeconds", 10), ("frameDurationSeconds", 0),
                         ("maxSpeakers", 3), ("maxSpeakers", True), ("rawPredictions", [])):
            variants.append(dict(valid, **{key: bad}))
        for value in variants:
            with self.subTest(value=value), self.assertRaises(ValueError):
                post.postprocess(value, "baseline")

    def test_baseline_mismatch_fails_before_creating_any_output(self):
        value = raw([[0.9], [0.1]])
        expected = baseline(value)
        expected["segments"][0]["end"] = 0.16
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            source, previous, output = folder / "raw.json", folder / "baseline.json", folder / "out"
            source.write_text(json.dumps(value))
            previous.write_text(json.dumps(expected))
            with self.assertRaises(ValueError):
                post.run(source, previous, output)
            self.assertFalse(output.exists())

    def test_run_retains_sources_records_provenance_and_never_overwrites(self):
        value = raw([[0.9], [0.1], [0.9]])
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            source, previous, output = folder / "raw.json", folder / "baseline.json", folder / "out"
            source.write_text(json.dumps(value))
            previous.write_text(json.dumps(baseline(value)))
            source_bytes, baseline_bytes = source.read_bytes(), previous.read_bytes()
            manifest = post.run(source, previous, output)
            self.assertEqual(len(manifest["outputs"]), 3)
            self.assertEqual(source.read_bytes(), source_bytes)
            self.assertEqual(previous.read_bytes(), baseline_bytes)
            self.assertFalse(manifest["protocol"]["referenceRead"])
            self.assertTrue(manifest["protocol"]["baselineTurnParity"])
            self.assertTrue((output / "preregister.json").exists())
            result = json.loads((output / "gap-fill.json").read_text())
            self.assertEqual(result["protocol"]["params"]["maximumGapSeconds"], 0.16)
            self.assertEqual(result["protocol"]["modelSHA"], "a" * 64)
            self.assertGreaterEqual(result["protocol"]["seconds"], 0)
            before = (output / "manifest.json").read_bytes()
            with self.assertRaises(FileExistsError):
                post.run(source, previous, output)
            self.assertEqual((output / "manifest.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
