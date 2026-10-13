# Tests for score.py. CI runs them on Linux:
#
#     python3 -m unittest discover -s Tools/speech-eval -p 'test_*.py'

from __future__ import annotations

import json
import unittest

import score

GOLDEN = score.HERE / "voxt-golden"


class TokenTests(unittest.TestCase):
    def test_english_drops_case_punctuation_and_edge_apostrophes(self) -> None:
        self.assertEqual(score.tokens("Hello, World! It's 'quoted' 42.", "en"), ["hello", "world", "it's", "quoted", "42"])

    def test_english_splits_on_hyphens(self) -> None:
        self.assertEqual(score.tokens("well-known", "en"), ["well", "known"])

    def test_chinese_counts_characters_and_keeps_latin_words_whole(self) -> None:
        self.assertEqual(score.tokens("我用 iPhone 拍了２０张，", "zh"), ["我", "用", "iphone", "拍", "了", "20", "张"])

    def test_numerals_and_digits_do_not_match(self) -> None:
        self.assertEqual(score.edit_distance(score.tokens("2011年", "zh"), score.tokens("二零一一年", "zh")), 4)

    def test_edit_distance(self) -> None:
        self.assertEqual(score.edit_distance(list("kitten"), list("sitting")), 3)
        self.assertEqual(score.edit_distance([], ["a"]), 1)
        self.assertEqual(score.edit_distance(["a"], []), 1)


class ManifestTests(unittest.TestCase):
    def test_the_manifest_holds_the_392_clips(self) -> None:
        manifest = score.load_manifest()
        self.assertEqual(len(manifest), 392)
        self.assertEqual({clip["stratum"] for clip in manifest.values()}, set(score.STRATA + score.EMPTY_STRATA))


class VoxtReproductionTests(unittest.TestCase):
    """Scoring Voxt's own hypotheses gives exactly the error rates its golden files hold."""

    def test_every_golden_file_and_device(self) -> None:
        manifest = score.load_manifest()
        files = sorted(GOLDEN.glob("qwen3-asr-*.json"))
        self.assertEqual(len(files), 3)
        for path in files:
            golden = json.loads(path.read_text(encoding="utf-8"))
            for device, run in golden["devices"].items():
                texts = {clip_id: row["text"] for clip_id, row in run["clips"].items()}
                with self.subTest(file=path.name, device=device):
                    self.assertEqual(score.metrics(manifest, texts), run["metrics"])


class TimingTests(unittest.TestCase):
    def test_median_p95_and_real_time_factor(self) -> None:
        clips = {str(i): {"text": "", "audio_seconds": 10.0, "decode_seconds": float(i)} for i in range(1, 21)}
        result = score.timing(clips)
        self.assertEqual(result["decode_median"], 10.5)
        self.assertEqual(result["decode_p95"], 19.0)
        self.assertAlmostEqual(result["rtf_total"], 1.05)

    def test_no_timing_in_a_golden_file(self) -> None:
        self.assertIsNone(score.timing({"a": {"text": "x"}}))


if __name__ == "__main__":
    unittest.main()
