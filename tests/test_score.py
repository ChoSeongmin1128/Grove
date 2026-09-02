import importlib.util
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "score", Path(__file__).parents[1] / "scripts" / "score.py"
)
assert SPEC and SPEC.loader
score = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(score)


class ScoreTests(unittest.TestCase):
    def test_reference_variants_accept_orthographic_and_spoken_forms(self) -> None:
        variants = score.reference_variants("중학교 (1학년)/(일 학년)")
        self.assertEqual(variants, ["중학교 1학년", "중학교 일 학년"])

    def test_noise_and_annotation_symbols_do_not_affect_normalized_cer(self) -> None:
        edits, characters, _ = score.best_error(
            "n/ 정보화사회가 발달했습니다*", "정보화 사회가 발달했습니다.", remove_spaces=True
        )
        self.assertEqual(edits, 0)
        self.assertGreater(characters, 0)

    def test_korean_spacing_can_be_measured_separately(self) -> None:
        relaxed = score.best_error("정보화 사회", "정보화사회", remove_spaces=True)
        strict = score.best_error("정보화 사회", "정보화사회", remove_spaces=False)
        self.assertEqual(relaxed[0], 0)
        self.assertGreater(strict[0], 0)

    def test_edit_distance(self) -> None:
        self.assertEqual(score.edit_distance("가나다", "가마"), 2)


if __name__ == "__main__":
    unittest.main()
