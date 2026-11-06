# Tests for score.py. CI runs them on Linux:
#
#     python3 -m unittest discover -s Tools/speech-eval -p 'test_*.py'

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unicodedata
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
        self.assertEqual([score.scoring_lang(lang) for lang in ("ko", "ja_en", "es_en", "ko_en")], ["ko", "ja", "es", "ko"])

    def test_numerals_and_digits_do_not_match(self) -> None:
        self.assertEqual(score.edit_distance(score.tokens("2011年", "zh"), score.tokens("二零一一年", "zh")), 4)

    def test_edit_distance(self) -> None:
        self.assertEqual(score.edit_distance(list("kitten"), list("sitting")), 3)
        self.assertEqual(score.edit_distance([], ["a"]), 1)
        self.assertEqual(score.edit_distance(["a"], []), 1)


class KoreanTokenTests(unittest.TestCase):
    def test_spaced_and_unspaced_hangul_count_per_syllable(self) -> None:
        syllables = ["내", "일", "회", "의", "가", "있", "어", "요"]
        self.assertEqual(score.tokens("내일 회의가 있어요.", "ko"), syllables)
        self.assertEqual(score.tokens("내일회의가있어요", "ko"), syllables)
        # A space never counts, a wrong syllable is one error.
        self.assertEqual(score.edit_distance(score.tokens("내일 회의", "ko"), score.tokens("내일회이", "ko")), 1)

    def test_nfc_and_nfd_give_the_same_tokens(self) -> None:
        text = "한국어 받아쓰기"
        decomposed = unicodedata.normalize("NFD", text)
        self.assertEqual((len(text), len(decomposed)), (8, 18))
        self.assertEqual(score.tokens(decomposed, "ko"), ["한", "국", "어", "받", "아", "쓰", "기"])
        self.assertEqual(score.tokens(decomposed, "ko"), score.tokens(text, "ko"))

    def test_each_jamo_is_one_token(self) -> None:
        # Compatibility and half width jamo become conjoining jamo under NFKC.
        khieukh = "ᄏ"
        self.assertEqual(score.tokens("ㅋㅋ 좋아요", "ko"), [khieukh, khieukh, "좋", "아", "요"])
        self.assertEqual(score.tokens("ﾻﾻ", "ko"), [khieukh, khieukh])
        # Two leading consonants make no syllable.
        self.assertEqual(score.tokens("ᄀᄀ", "ko"), ["ᄀ", "ᄀ"])

    def test_hanja_kana_and_digits(self) -> None:
        self.assertEqual(score.tokens("大韓民國은 2026년 3월에", "ko"), ["大", "韓", "民", "國", "은", "2026", "년", "3", "월", "에"])
        self.assertEqual(score.tokens("10,000원, 15km", "ko"), ["10", "000", "원", "15km"])
        self.assertEqual(score.tokens("カレー 먹자", "ko"), ["カ", "レ", "ー", "먹", "자"])

    def test_korean_mixed_with_english_keeps_english_words_whole(self) -> None:
        self.assertEqual(
            score.tokens("Slack에서 PR 리뷰를 부탁해요. Deadline은 금요일!", "ko"),
            ["slack", "에", "서", "pr", "리", "뷰", "를", "부", "탁", "해", "요", "deadline", "은", "금", "요", "일"],
        )
        self.assertEqual(score.tokens("O'Brien의 café", "ko"), ["o'brien", "의", "café"])
        # 슬랙 for Slack: one substitution and one insertion.
        self.assertEqual(score.edit_distance(score.tokens("Slack에", "ko"), score.tokens("슬랙에", "ko")), 2)

    def test_the_chinese_way_keeps_hangul_syllables_but_not_jamo_or_kana(self) -> None:
        # Its range starts at U+8C48, which takes in the Hangul syllables. Unchanged, so cer_zh
        # and mer_mixed stay as they were.
        self.assertEqual(score.tokens("안녕 ㅋㅋ 東京へ hello", "zh"), ["안", "녕", "東", "京", "hello"])

    def test_output_tokens_see_every_script(self) -> None:
        for text, count in (("こんにちは", 5), ("ㅋㅋ", 2), ("Привет мир", 2), ("谢谢", 2), ("안녕", 2), ("¿Qué?", 1), ("...", 0), ("", 0)):
            self.assertEqual(len(score.output_tokens(text)), count, text)
        # The Chinese tokens, which counted output before, see none of these.
        self.assertEqual(score.tokens("こんにちは ㅋㅋ Привет", "zh"), [])

    def test_silence_with_output_in_any_script(self) -> None:
        manifest = {
            "s1": {"id": "s1", "stratum": "silence", "lang": "none", "duration": 5.0, "reference": ""},
            "s2": {"id": "s2", "stratum": "silence", "lang": "none", "duration": 5.0, "reference": ""},
            "n1": {"id": "n1", "stratum": "noise", "lang": "none", "duration": 5.0, "reference": ""},
        }
        rates = score.strata(manifest, {"s1": "ありがとう", "s2": "", "n1": "Спасибо."})
        self.assertEqual((rates["silence"], rates["noise"]), ((1, 2), (1, 1)))


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


class PairGroupTests(unittest.TestCase):
    MANIFEST = {
        "k1": {"id": "k1", "stratum": "ko", "lang": "ko", "duration": 2.0, "reference": "내일 회의가 있어요."},
        "j1": {"id": "j1", "stratum": "ja_en", "lang": "ja_en", "duration": 2.0, "reference": "このPRを確認して"},
        "e1": {"id": "e1", "stratum": "es_en", "lang": "es_en", "duration": 2.0, "reference": "Mándame el deadline."},
        "m1": {"id": "m1", "stratum": "ko_en", "lang": "ko_en", "duration": 2.0, "reference": "Slack에 올려 주세요."},
    }

    def test_korean_and_the_groups_mixed_with_english(self) -> None:
        texts = {"k1": "내일 회이가 있어요", "j1": "このPRを確認して", "e1": "Mándame el dedlain", "m1": "슬랙에 올려 주세요"}
        rates = score.metrics(self.MANIFEST, texts)
        self.assertEqual(rates, {"wer_en": 0.0, "cer_zh": 0.0, "mer_mixed": 0.0, "cer_ko": round(1 / 8, 5), "mer_ja_en": 0.0, "mer_es_en": round(1 / 3, 5), "mer_ko_en": round(2 / 7, 5)})
        self.assertEqual(score.strata(self.MANIFEST, texts)["ko"], (1 / 8, 1))

    def test_a_run_of_korean_clips_shows_only_korean(self) -> None:
        table = score.table({"k1": self.MANIFEST["k1"]}, [("run", {"k1": {"text": "내일회의가 있어요"}})])
        self.assertIn("| cer_ko | 0.00% |", table)
        self.assertIn("| ko (1) | 0.00% |", table)
        for name in ["wer_en", "cer_zh", "mer_mixed", "cer_ja", "wer_es", "mer_ko_en"] + score.STRATA:
            self.assertNotIn(f"| {name} ", table)


class WithoutDigitsTests(unittest.TestCase):
    MANIFEST = {
        "r1": {"id": "r1", "stratum": "ko", "lang": "ko", "source": "fleurs-ko_kr-test", "duration": 5.0, "reference": "오늘은 날씨가 좋아요."},
        "r2": {"id": "r2", "stratum": "ko", "lang": "ko", "source": "fleurs-ko_kr-test", "duration": 5.0, "reference": "회의는 3시에 시작해요."},
        "r3": {"id": "r3", "stratum": "ko", "lang": "ko", "source": "fleurs-ko_kr-test", "duration": 5.0, "reference": "회의는 ３시에 시작해요."},
        "v1": {"id": "v1", "stratum": "ko", "lang": "ko", "source": "volunteers", "duration": 5.0, "reference": "점심 먹었어요?"},
        "m1": {"id": "m1", "stratum": "mixed", "lang": "mixed", "source": "ascend-test", "duration": 5.0, "reference": "这个 bug 明天 fix"},
    }

    def test_only_read_speech_without_digits_counts(self) -> None:
        # r2 and r3 hold a digit, a full width one in r3, v1 is no read speech, and mer_mixed
        # has none, so only r1 counts.
        texts = {"r1": "오늘은 날씨가 좋아요", "r2": "회의는 세 시에 시작해요", "r3": "회의는 세 시에 시작해요", "v1": "점심 먹었어", "m1": "这个bug明天fix"}
        self.assertEqual(score.without_digits(self.MANIFEST, texts), {"cer_ko": (0.0, 1)})
        self.assertEqual(score.metrics(self.MANIFEST, texts)["cer_ko"], round(3 / 35, 5))
        table = score.table(self.MANIFEST, [("run", {clip_id: {"text": text} for clip_id, text in texts.items()})])
        self.assertIn("| cer_ko | 8.57% |", table)
        self.assertIn("| cer_ko, read speech without digits (1) | 0.00% |", table)
        self.assertNotIn("mer_mixed, read speech", table)

    def test_the_speech_corpus_has_read_speech_without_digits_in_two_groups(self) -> None:
        # LibriSpeech holds no digits. FLEURS cmn holds them in 44 of its 143 clips, and ASCEND is
        # spontaneous speech.
        manifest = score.load_manifest()
        texts = {clip_id: clip["reference"] for clip_id, clip in manifest.items()}
        self.assertEqual(score.without_digits(manifest, texts), {"wer_en": (0.0, 147), "cer_zh": (0.0, 99)})


class AcceptedSpellingTests(unittest.TestCase):
    MANIFEST = {
        "k1": {"id": "k1", "stratum": "ko", "lang": "ko", "source": "fleurs-ko_kr-test", "duration": 5.0, "reference": "약 80km 떨어진 곳", "accepted": [["km", "킬로미터"]]},
        "k2": {"id": "k2", "stratum": "ko", "lang": "ko", "source": "fleurs-ko_kr-test", "duration": 5.0, "reference": "Slack에 올려 주세요", "expect_terms": [["Slack", "슬랙"]]},
        "k3": {"id": "k3", "stratum": "ko", "lang": "ko", "source": "fleurs-ko_kr-test", "duration": 5.0, "reference": "점심 먹었어요"},
    }

    def test_longest_spellings_go_first(self) -> None:
        self.assertEqual(score.lenient_text("약 15킬로미터 떨어진 곳에서 3미터", [["km", "킬로미터"], ["m", "미터"]], ""), "약 15km 떨어진 곳에서 3m")
        self.assertEqual(score.lenient_text("3미터와 15킬로미터", [["m", "미터"], ["km", "킬로미터"]], ""), "3m와 15km")

    def test_a_shorter_spelling_never_cuts_the_form_of_the_reference(self) -> None:
        self.assertEqual(score.lenient_text("킬로그램과 킬로", [["킬로그램", "kg"], ["km", "킬로"]], "킬로그램과 km"), "킬로그램과 km")

    def test_a_word_of_the_reference_keeps_its_spelling(self) -> None:
        # 세 시간 holds 세 시, another spelling of 3시, and 킬로그램 holds 킬로, another spelling of
        # km. Neither is replaced, so a text equal to its reference keeps no error.
        for reference, lists in (("세 시간 뒤 3시에 만나요", [["3시", "세 시"]]), ("10킬로그램을 들고 80km를 걸었다", [["km", "킬로미터", "킬로"]])):
            clip = {"id": "k", "lang": "ko", "reference": reference, "accepted": lists}
            self.assertEqual(score.clip_errors(clip, reference, lenient=True), (0, len(score.tokens(reference, "ko"))), reference)
        # The other spellings still count, and 킬로, which the reference holds, keeps its errors.
        clip = {"id": "k", "lang": "ko", "reference": "10킬로그램을 들고 80km를 걸었다", "accepted": [["km", "킬로미터", "킬로"]]}
        self.assertEqual(score.clip_errors(clip, "10킬로그램을 들고 80킬로미터를 걸었다", lenient=True), (0, 13))
        self.assertEqual(score.clip_errors(clip, "10킬로그램을 들고 80킬로를 걸었다", lenient=True), score.clip_errors(clip, "10킬로그램을 들고 80킬로를 걸었다"))

    def test_latin_spellings_match_whole_words_and_spaces_are_free(self) -> None:
        self.assertEqual(score.lenient_text("Slacker와 Slack에서", [["슬랙", "Slack"]], ""), "slacker와 슬랙에서")
        self.assertEqual(score.lenient_text("에이 피 아이 문서", [["API", "에이피아이"]], ""), "api 문서")

    def test_no_spelling_takes_part_of_a_longer_word_or_number(self) -> None:
        # A letter with an accent ends a word as much as an ASCII letter, and a digit ends a number.
        for text, lists in (
            ("Slacké와", [["슬랙", "Slack"]]),
            ("el wifiño", [["Wi-Fi", "wifi"]]),
            ("no son 130,000", [["treinta mil", "30,000"]]),
            ("un disco de 11TB", [["1 TB", "1TB"]]),
            ("en el edificio 20", [["edificio dos", "edificio 2"]]),
        ):
            self.assertEqual(score.lenient_text(text, lists, ""), score.folded(text), text)
        # es de 20 must not take part of es de 200, which 200 ms needs (es-numbers num37 of the
        # pair sets).
        clip = {
            "id": "num37", "lang": "es", "reference": "La latencia del server no es de 200 milisegundos, es de 20.",
            "accepted": [["200 milisegundos", "200 ms", "doscientos milisegundos"], ["es de 20", "es de veinte"]],
        }
        self.assertEqual(score.clip_errors(clip, "La latencia del server no es de 200 ms, es de 20.", lenient=True), (0, 12))
        self.assertEqual(score.clip_errors(clip, "La latencia del server no es de 200 ms, es de veinte.", lenient=True), (0, 12))
        # A digit next to a letter, or anything next to Hangul, still matches: km in 80km, and a
        # spelling right after a particle without its space.
        self.assertEqual(score.lenient_text("타임아웃을30초에서 80킬로미터", [["삼십 초", "30초"], ["km", "킬로미터"]], ""), "타임아웃을삼십 초에서 80km")
        # Hangul has no edge, so 일 테라 is found in 십일 테라 too, and its 십 stays an error.
        self.assertEqual(score.lenient_text("십일 테라", [["1TB", "일 테라"]], ""), "십1tb")

    def test_strict_and_lenient_rates(self) -> None:
        texts = {"k1": "약 80킬로미터 떨어진 곳", "k2": "슬랙에 올려 주세요", "k3": "점심 먹었어요"}
        self.assertEqual(score.clip_errors(self.MANIFEST["k1"], texts["k1"]), (5, 6))
        self.assertEqual(score.clip_errors(self.MANIFEST["k1"], texts["k1"], lenient=True), (0, 6))
        self.assertEqual(score.clip_errors(self.MANIFEST["k2"], texts["k2"], lenient=True), (0, 7))
        self.assertEqual(score.metrics(self.MANIFEST, texts)["cer_ko"], round(7 / 19, 5))
        self.assertEqual(score.metrics(self.MANIFEST, texts, lenient=True)["cer_ko"], 0.0)
        # k1 holds digits, so the rate without digits counts k2 and k3.
        self.assertEqual(score.without_digits(self.MANIFEST, texts), {"cer_ko": (round(2 / 13, 5), 2)})
        self.assertEqual(score.without_digits(self.MANIFEST, texts, lenient=True), {"cer_ko": (0.0, 2)})
        table = score.table(self.MANIFEST, [("run", {clip_id: {"text": text} for clip_id, text in texts.items()})])
        for line in ("| cer_ko | 36.84% |", "| cer_ko, lenient | 0.00% |", "| cer_ko, read speech without digits (2) | 15.38% |", "| cer_ko, read speech without digits, lenient (2) | 0.00% |"):
            self.assertIn(line, table)

    def test_without_lists_both_rates_are_the_same(self) -> None:
        manifest = score.load_manifest()
        golden = json.loads((GOLDEN / "qwen3-asr-1.7b-8bit.json").read_text(encoding="utf-8"))
        texts = {clip_id: row["text"] for clip_id, row in golden["devices"]["Apple M5"]["clips"].items()}
        self.assertEqual(score.metrics(manifest, texts, lenient=True), score.metrics(manifest, texts))
        self.assertEqual(score.without_digits(manifest, texts, lenient=True), score.without_digits(manifest, texts))
        for clip_id, text in texts.items():
            self.assertEqual(score.clip_errors(manifest[clip_id], text, lenient=True), score.clip_errors(manifest[clip_id], text))
        self.assertNotIn("lenient", score.table(manifest, [("golden", {clip_id: {"text": text} for clip_id, text in texts.items()})]))

    def test_lists_must_hold_strings(self) -> None:
        self.assertEqual(score.accepted_spellings(self.MANIFEST["k3"]), [])
        self.assertEqual(score.accepted_spellings({"id": "x", "accepted": [["km", "킬로미터"]], "expect_terms": ["Jira", ["Slack", "슬랙"]]}), [["km", "킬로미터"], ["Slack", "슬랙"]])
        for accepted in (["km"], [[]], [["km", 3]]):
            with self.assertRaises(ValueError):
                score.accepted_spellings({"id": "x", "accepted": accepted})


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
