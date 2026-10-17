# Tests for score.py. CI runs them on Linux:
#
#     python3 -m unittest discover -s Tools/speech-eval -p 'test_*.py'

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import score

GOLDEN = score.HERE / "voxt-golden"


class TokenTests(unittest.TestCase):
    def test_english_drops_case_punctuation_and_edge_apostrophes(self) -> None:
        self.assertEqual(score.tokens("Hello, World! It's 'quoted' 42.", "en"), ["hello", "world", "it's", "quoted", "42"])

    def test_english_splits_on_hyphens(self) -> None:
        self.assertEqual(score.tokens("well-known", "en"), ["well", "known"])

    def test_chinese_counts_characters_and_keeps_latin_words_whole(self) -> None:
        self.assertEqual(score.tokens("我用 iPhone 拍了２０张，", "zh"), ["我", "用", "iphone", "拍", "了", "20", "张"])

    def test_chinese_drops_kana_and_splits_accented_words_as_voxt_does(self) -> None:
        self.assertEqual(score.tokens("東京へ año", "zh"), ["東", "京", "a", "o"])

    def test_japanese_counts_han_kana_and_iteration_marks_per_character(self) -> None:
        self.assertEqual(
            score.tokens("人々は「モササウルス・ゲーム」を2つ見た。iPhone", "ja"),
            ["人", "々", "は", "モ", "サ", "サ", "ウ", "ル", "ス", "ゲ", "ー", "ム", "を", "2", "つ", "見", "た", "iphone"],
        )

    def test_half_width_katakana_counts_as_full_width(self) -> None:
        self.assertEqual(score.tokens("ｶﾞｰﾃﾞﾝ", "ja"), score.tokens("ガーデン", "ja"))

    def test_spanish_keeps_accents_and_whole_words(self) -> None:
        self.assertEqual(score.tokens("¿El año pasado? «Cuán ácida», dijo O'Brien.", "es"), ["el", "año", "pasado", "cuán", "ácida", "dijo", "o'brien"])
        self.assertEqual(score.edit_distance(score.tokens("el año", "es"), score.tokens("el ano", "es")), 1)

    def test_spanish_counts_a_chinese_or_japanese_transcript_per_character(self) -> None:
        self.assertEqual(score.tokens("咖喱是一道菜", "es"), ["咖", "喱", "是", "一", "道", "菜"])
        self.assertEqual(score.tokens("カレーです", "es"), ["カ", "レ", "ー", "で", "す"])

    def test_hangul_stays_one_word_in_japanese_and_spanish(self) -> None:
        self.assertEqual(score.tokens("안녕하세요 amigos", "es"), ["안녕하세요", "amigos"])
        self.assertEqual(score.tokens("안녕하세요 amigos", "ja"), ["안녕하세요", "amigos"])

    def test_scoring_language(self) -> None:
        self.assertEqual([score.scoring_lang(lang) for lang in ("en", "zh", "mixed", "none", "ja", "es", None)], ["en", "zh", "zh", "zh", "ja", "es", "zh"])

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


class LanguageGroupTests(unittest.TestCase):
    MANIFEST = {
        "a_ja": {"id": "a_ja", "stratum": "ja", "lang": "ja", "duration": 2.0, "reference": "東京へ行きます。"},
        "b_es": {"id": "b_es", "stratum": "es", "lang": "es", "duration": 2.0, "reference": "El año pasado."},
        "c_zh": {"id": "c_zh", "stratum": "zh_short", "lang": "zh", "duration": 2.0, "reference": "你好"},
    }

    def test_japanese_and_spanish_groups(self) -> None:
        texts = {"a_ja": "東京に行きます", "b_es": "El ano pasado", "c_zh": "你好"}
        self.assertEqual(score.metrics(self.MANIFEST, texts), {"wer_en": 0.0, "cer_zh": 0.0, "mer_mixed": 0.0, "cer_ja": round(1 / 7, 5), "wer_es": round(1 / 3, 5)})
        rates = score.strata(self.MANIFEST, texts)
        self.assertEqual((rates["ja"][1], rates["es"][1]), (1, 1))

    def test_the_groups_stay_out_of_a_run_without_such_clips(self) -> None:
        texts = {"c_zh": "你好"}
        self.assertEqual(list(score.metrics(self.MANIFEST, texts)), ["wer_en", "cer_zh", "mer_mixed"])
        self.assertNotIn("ja", score.strata(self.MANIFEST, texts))
        table = score.table({"c_zh": self.MANIFEST["c_zh"]}, [("run", {"c_zh": {"text": "你好"}})])
        self.assertNotIn("cer_ja", table)
        self.assertNotIn("| ja (", table)

    def test_a_run_of_spanish_clips_shows_only_spanish(self) -> None:
        table = score.table({"b_es": self.MANIFEST["b_es"]}, [("run", {"b_es": {"text": "El año pasado"}})])
        self.assertIn("| wer_es | 0.00% |", table)
        self.assertIn("| es (1) | 0.00% |", table)
        for name in ["wer_en", "cer_zh", "mer_mixed"] + score.STRATA + score.EMPTY_STRATA:
            self.assertNotIn(f"| {name} ", table)

    def test_a_run_without_clips_in_a_group_shows_n_a(self) -> None:
        manifest = {clip_id: self.MANIFEST[clip_id] for clip_id in ("a_ja", "b_es")}
        both = {"a_ja": {"text": "東京へ行きます"}, "b_es": {"text": "El año pasado"}}
        with contextlib.redirect_stderr(io.StringIO()):
            table = score.table(manifest, [("both", both), ("ja", {"a_ja": both["a_ja"]})])
        self.assertIn("| cer_ja | 0.00% | 0.00% |", table)
        self.assertIn("| wer_es | 0.00% | n/a |", table)
        self.assertIn("| es (1) | 0.00% | n/a |", table)


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

    def test_a_hinted_field_reads_the_time_of_its_pass(self) -> None:
        row = {"text": "a", "text_japanese": "b", "text_unhinted": "c", "audio_seconds": 10.0, "decode_seconds": 3.0, "decode_seconds_japanese": 1.0}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "run.json"
            path.write_text(json.dumps({"clips": {"x": row}}), encoding="utf-8")
            seconds = {field: score.load_run(str(path), field)[1]["x"]["decode_seconds"] for field in ("text", "text_japanese", "text_unhinted")}
        self.assertEqual(seconds, {"text": 3.0, "text_japanese": 1.0, "text_unhinted": 3.0})

    def test_no_timing_in_a_golden_file(self) -> None:
        self.assertIsNone(score.timing({"a": {"text": "x"}}))


if __name__ == "__main__":
    unittest.main()
