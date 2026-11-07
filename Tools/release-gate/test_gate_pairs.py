"""Tests of the release gate's suites of the dictation pairs, pairs and wrong-pairs, in
Tools/release-gate/gate.py. Made up clips and texts, no model. Standard library only:

    python3 -m unittest discover -s Tools/release-gate -p 'test_*.py' -v
"""

from __future__ import annotations

import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import gate


def write_manifest(folder: Path, rows: list[dict]) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "manifest.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
    return folder


def clip(clip_id: str, lang: str, reference: str, source: str = "fleurs", stratum: str | None = None) -> dict:
    return {"id": clip_id, "stratum": stratum or lang, "lang": lang, "source": source, "reference": reference}


def write_set(sets: Path, name: str, pair: str | None, rows: list[dict]) -> None:
    folder = write_manifest(sets / name, rows)
    if pair:
        (folder / "set.json").write_text(json.dumps({"pair": pair}), encoding="utf-8")


class Folders:
    """A speech corpus with Chinese FLEURS clips, English, mixed and silence, FLEURS ja and es
    in one folder and FLEURS ko in another, one set per pair, and say clips of ja and es."""

    def __init__(self, root: Path):
        self.root = root
        self.corpus = write_manifest(root / "speech-corpus", [
            clip("0000_en_short", "en", "send the report", "librispeech-test-clean", "en_short"),
            clip("0001_en_short", "en", "call me back", "librispeech-test-clean", "en_short"),
            clip("0002_zh_short", "zh", "今天开会", "ascend-test", "zh_short"),
            clip("0003_zh_mid", "zh", "明天下雨", "fleurs-cmn_hans_cn-test", "zh_mid"),
            clip("0004_zh_mid", "zh", "我们走吧", "fleurs-cmn_hans_cn-test", "zh_mid"),
            clip("0005_mixed", "mixed", "这个 bug 明天 fix", "ascend-test", "mixed"),
            clip("0006_silence", "none", "", "synthetic", "silence"),
        ])
        self.ja_es = write_manifest(root / "fleurs-ja-es", [
            clip("0000_ja", "ja", "明日は雨です", "fleurs-ja_jp-test"),
            clip("0001_ja", "ja", "駅で会いましょう", "fleurs-ja_jp-test"),
            clip("0002_ja", "ja", "3時に始めます", "fleurs-ja_jp-test"),
            clip("0000_es", "es", "mañana llueve", "fleurs-es_419-test"),
            clip("0001_es", "es", "nos vemos en la estación", "fleurs-es_419-test"),
        ])
        self.ko = write_manifest(root / "fleurs-ko", [
            {**clip("0000_ko", "ko", "약 80km 떨어진 곳", "fleurs-ko_kr-test"), "accepted": [["km", "킬로미터"]]},
            clip("0001_ko", "ko", "내일 비가 와요", "fleurs-ko_kr-test"),
        ])
        self.fleurs = [self.ja_es, self.ko]
        self.sets = root / "pairs"
        write_set(self.sets, "zh-mirror", "zh", [{"id": "m01", "language": "mixed", "reference": "下午 meeting 之前", "context": [], "expect_terms": ["meeting"], "forbid_terms": []}])
        write_set(self.sets, "ja-mirror", "ja", [
            {"id": "m01", "language": "ja", "reference": "午後のミーティングの前に", "context": [], "expect_terms": [["ミーティング", "meeting"]], "forbid_terms": [], "accepted": [["ミーティング", "meeting"]]},
            {"id": "e01", "language": "en", "reference": "Send me the report.", "context": [], "expect_terms": [], "forbid_terms": []},
        ])
        write_set(self.sets, "es-mirror", "es", [{"id": "m01", "language": "es", "reference": "antes de la meeting", "context": [], "expect_terms": ["meeting"], "forbid_terms": []}])
        write_set(self.sets, "ko-mirror", "ko", [{"id": "m01", "language": "ko", "reference": "오후 미팅 전에", "context": [], "expect_terms": [], "forbid_terms": []}])
        # The say clips of the latency runs, without a manifest, so they add no set here.
        for pair in ("ja", "es"):
            say = self.sets / f"{pair}-latency" / "clips"
            say.mkdir(parents=True)
            (say / f"{pair}_short_1.wav").write_bytes(b"")
        self.out = root / "out"

    def plan(self, suite: str, pairs: list[str], count: int = 50) -> list[dict]:
        return gate.plan_runs(suite, self.out, pairs, self.corpus, self.fleurs, self.sets, count)

    def corpora(self) -> list[Path]:
        return [self.corpus, *self.fleurs]


def row(text: str, ruled: str | None = None, passes: int = 0, stood: str = "unhinted") -> dict:
    return {"text": text, "ruled_text": text if ruled is None else ruled, "decode_seconds": 0.3, "language_passes": passes, "language_pass": stood}


def write_raw(folder: Path, name: str, clips: dict, language: str | None) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    document = {"build": "Release", "clips": clips}
    if language:
        document["dictation_language"] = language
    gate.write_json(folder / f"{name}.json", document)


def context_raw(found: int, gave_text: int = 0) -> dict:
    """The raw file of the context suite with one contextasr_en clip of two terms."""
    return {"suite": "context", "clips": [{
        "set": "contextasr_en", "id": "c01", "terms": 2, "distractors": 10, "reference_tokens": 20, "audio_seconds": 30.0,
        "plain": {"found": 1, "inserted": 0, "errors": 2, "seconds": 1.2},
        "context": {"found": found, "inserted": 0, "errors": 1, "seconds": 1.3},
    }], "summary": {"no_speech": {"clips": 3, "gave_text": gave_text}}}


def latency_raw(p90: float) -> dict:
    """The raw file of the latency suite with the total of one mode."""
    return {"suite": "latency", "rounds": 2, "modes": {"cleanup_off": {
        "dictations": 2, "steps": {"total": {"median": 300.0, "p90": p90}}, "clips": {"say ja_short_1": {"median": 300.0}},
    }}}


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.data = Folders(Path(self.folder.name))

    def test_each_pair_runs_the_corpus_its_fleurs_clips_the_context_and_latency_suites_and_its_sets(self):
        runs = self.data.plan("pairs", ["zh", "ja", "es"])
        self.assertEqual([run["label"] for run in runs], [
            "pairs-zh-sets",
            "pairs-ja-corpus", "pairs-ja-fleurs", "pairs-ja-context", "pairs-ja-latency", "pairs-ja-sets",
            "pairs-es-corpus", "pairs-es-fleurs", "pairs-es-context", "pairs-es-latency", "pairs-es-sets",
        ])
        by_label = {run["label"]: run for run in runs}
        # A pair named twice runs once.
        self.assertEqual([run["label"] for run in self.data.plan("pairs", ["zh", "zh"])], ["pairs-zh-sets"])
        # Chinese has its corpus, context and latency runs in those suites, so only its sets
        # run here.
        self.assertEqual(by_label["pairs-zh-sets"], {
            "label": "pairs-zh-sets", "kind": "sets", "language": "Chinese", "name": "sets-raw", "folder": self.data.sets, "clips": None,
            "raw": self.data.out / "pairs" / "zh" / "raw",
        })
        corpus = by_label["pairs-ja-corpus"]
        self.assertEqual((corpus["kind"], corpus["language"], corpus["name"], corpus["folder"], corpus["clips"]), ("corpus", "Japanese", "corpus", self.data.corpus, None))
        fleurs = by_label["pairs-ja-fleurs"]
        self.assertEqual((fleurs["folder"], fleurs["name"]), (self.data.ja_es, "fleurs"))
        self.assertEqual(fleurs["clips"].read_text(encoding="utf-8"), "0000_ja\n0001_ja\n0002_ja\n")
        self.assertEqual(by_label["pairs-es-fleurs"]["clips"].read_text(encoding="utf-8"), "0000_es\n0001_es\n")
        self.assertEqual(by_label["pairs-es-sets"]["language"], "Spanish")
        # The context suite reads its own clips, the latency suite the pair's say clips.
        raw = self.data.out / "pairs" / "ja" / "raw"
        self.assertEqual(by_label["pairs-ja-context"], {"label": "pairs-ja-context", "kind": "context", "language": "Japanese", "name": "context", "folder": None, "clips": None, "raw": raw})
        self.assertEqual(by_label["pairs-ja-latency"], {
            "label": "pairs-ja-latency", "kind": "latency", "language": "Japanese", "name": "latency", "folder": self.data.sets / "ja-latency" / "clips", "clips": None, "raw": raw,
        })

    def test_a_pair_needs_a_dictation_language_one_fleurs_folder_and_a_set(self):
        for pairs in (["ko"], ["ja", "fr"], []):
            with self.subTest(pairs=pairs), self.assertRaises(SystemExit):
                self.data.plan("pairs", pairs)
        # FLEURS ja in two folders.
        write_manifest(self.data.root / "more-ja", [clip("0100_ja", "ja", "雨", "fleurs-ja_jp-test")])
        with self.assertRaises(SystemExit):
            gate.plan_runs("pairs", self.data.out, ["ja"], self.data.corpus, [*self.data.fleurs, self.data.root / "more-ja"], self.data.sets, 50)
        # No FLEURS folder of the pair, or no folder at all.
        with self.assertRaises(SystemExit):
            gate.plan_runs("pairs", self.data.out, ["ja"], self.data.corpus, [self.data.ko], self.data.sets, 50)
        with self.assertRaises(SystemExit):
            gate.plan_runs("pairs", self.data.out, ["ja"], self.data.corpus, [self.data.root / "nowhere"], self.data.sets, 50)
        # No set of the pair, and for Chinese, which needs its sets only.
        for name, pair in (("ja-mirror", "ja"), ("zh-mirror", "zh")):
            (self.data.sets / name / "manifest.jsonl").unlink()
            with self.subTest(pair=pair), self.assertRaises(SystemExit):
                self.data.plan("pairs", [pair])
        # No say clips of the pair, for its latency run.
        self.data.plan("pairs", ["es"])
        (self.data.sets / "es-latency" / "clips" / "es_short_1.wav").unlink()
        with self.assertRaises(SystemExit):
            self.data.plan("pairs", ["es"])

    def test_wrong_pairs_take_clips_of_every_other_pair(self):
        runs = self.data.plan("wrong-pairs", ["zh", "ja"], count=2)
        self.assertEqual([run["label"] for run in runs], [
            "wrong-pairs-zh-fleurs-ja-es", "wrong-pairs-zh-fleurs-ko",
            "wrong-pairs-ja-speech-corpus", "wrong-pairs-ja-fleurs-ja-es", "wrong-pairs-ja-fleurs-ko",
        ])
        by_label = {run["label"]: run for run in runs}
        lists = {label: run["clips"].read_text(encoding="utf-8").split() for label, run in by_label.items()}
        # Two of each other pair, at even steps, Korean included. The speech corpus gives its
        # Chinese FLEURS clips, not those of ASCEND.
        self.assertEqual(lists["wrong-pairs-zh-fleurs-ja-es"], ["0000_ja", "0001_ja", "0000_es", "0001_es"])
        self.assertEqual(lists["wrong-pairs-zh-fleurs-ko"], ["0000_ko", "0001_ko"])
        self.assertEqual(lists["wrong-pairs-ja-speech-corpus"], ["0003_zh_mid", "0004_zh_mid"])
        self.assertEqual(lists["wrong-pairs-ja-fleurs-ja-es"], ["0000_es", "0001_es"])
        run = by_label["wrong-pairs-ja-speech-corpus"]
        self.assertEqual((run["language"], run["name"], run["folder"], run["raw"]), ("Japanese", "speech-corpus", self.data.corpus, self.data.out / "wrong-pairs" / "ja" / "raw"))

    def test_spread_takes_even_steps(self):
        ids = [str(number) for number in range(10)]
        self.assertEqual(gate.spread(ids, 4), ["0", "2", "5", "7"])
        self.assertEqual(gate.spread(ids, 10), ids)
        self.assertEqual(gate.spread(ids[:3], 50), ids[:3])

    def test_runs_prints_one_line_of_seven_fields_per_run(self):
        arguments = ["gate.py", "runs", "pairs", str(self.data.out), "--pairs", "ja", "--corpus", str(self.data.corpus),
                     "--fleurs", *map(str, self.data.fleurs), "--pair-sets", str(self.data.sets)]
        printed = io.StringIO()
        with mock.patch.object(sys, "argv", arguments), contextlib.redirect_stdout(printed):
            gate.main()
        lines = [line.split("\t") for line in printed.getvalue().splitlines()]
        self.assertEqual([len(fields) for fields in lines], [7, 7, 7, 7, 7])
        self.assertEqual(lines[0], ["pairs-ja-corpus", "corpus", "Japanese", "corpus", str(self.data.corpus), "-", str(self.data.out / "pairs" / "ja" / "raw")])
        self.assertEqual(lines[1][3:6], ["fleurs", str(self.data.ja_es), str(self.data.out / "pairs" / "ja" / "fleurs-clips.txt")])
        self.assertEqual(lines[2], ["pairs-ja-context", "context", "Japanese", "context", "-", "-", str(self.data.out / "pairs" / "ja" / "raw")])
        self.assertEqual(lines[3][:6], ["pairs-ja-latency", "latency", "Japanese", "latency", str(self.data.sets / "ja-latency" / "clips"), "-"])
        self.assertEqual(lines[4][:4], ["pairs-ja-sets", "sets", "Japanese", "sets-raw"])


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.data = Folders(Path(self.folder.name))
        self.manifest = gate.merged_manifest(self.data.corpora())

    def test_passes_count_the_extra_passes_and_the_texts_of_another_language(self):
        raw = {"clips": {
            "0000_ja": row("明日は雨です", passes=1, stood="japanese"),
            "0001_ja": row("Let's meet at the station", passes=2, stood="english"),
            "0002_ja": row("3時に始めます"),
            "0003_zh_mid": row("明天下雨", passes=1, stood="chinese"),
            "0005_mixed": row("this bug fix tomorrow", passes=2, stood="english"),
            "0000_en_short": row("送报告", passes=1, stood="chinese"),
            # Clips without speech have no language.
            "0006_silence": row("", passes=2, stood="english"),
        }}
        self.assertEqual(gate.pass_counts(raw, self.manifest), {
            "clips": 6,
            "extra_passes": {"0000_en_short": 1, "0000_ja": 1, "0001_ja": 2, "0003_zh_mid": 1, "0005_mixed": 2},
            "other_language": ["0000_en_short", "0001_ja"],
        })

    def test_english_clips_compare_with_the_chinese_run(self):
        chinese = {"clips": {"0000_en_short": row("Send the report."), "0001_en_short": row("Call me back.")}}
        raw = {"clips": {"0000_en_short": row("Um, send the report.", "Um, send the report."), "0001_en_short": row("Call me back."), "0002_zh_short": row("今日")}}
        self.assertEqual(gate.english_unlike_chinese(raw, chinese, self.manifest), {"clips": 2, "unlike": ["0000_en_short"]})
        self.assertIsNone(gate.english_unlike_chinese(raw, None, self.manifest))

    def test_the_set_pair_decides_the_group(self):
        groups = {(language, pair): [name for name, keep in gate.speech_score.GROUPS.items() if keep(gate.set_group_clip(language, pair))]
                  for language, pair in (("ja", "ja"), ("es", "es"), ("ko", "ko"), ("en", "ja"), ("mixed", "zh"), ("zh", "zh"), ("en", "zh"))}
        self.assertEqual(groups, {
            ("ja", "ja"): ["mer_ja_en"], ("es", "es"): ["mer_es_en"], ("ko", "ko"): ["mer_ko_en"], ("en", "ja"): ["wer_en"],
            ("mixed", "zh"): ["mer_mixed"], ("zh", "zh"): ["cer_zh"], ("en", "zh"): ["wer_en"],
        })

    def test_a_fleurs_run_keeps_only_groups_with_clips(self):
        raw = {"clips": {"0000_ja": row("明日は雨です"), "0001_ja": row("駅で会いましょ"), "0002_ja": row("3時に始めます")}}
        summary = gate.summarize_corpus(raw, self.manifest, every_group=False)
        self.assertEqual(set(summary["groups"]["text"]), {"cer_ja"})
        self.assertEqual(set(gate.summarize_corpus(raw, self.manifest)["groups"]["text"]), {"wer_en", "cer_zh", "mer_mixed", "cer_ja"})
        rates = gate.read_rates(raw, self.manifest)
        # 0002_ja holds a digit, so read speech without digits is the other two: 1 error in 14.
        self.assertEqual(rates["text"], {"cer_ja": {"rate": gate.rate(1, 14), "clips": 2}})

    def write_pair_run(self, language: str = "Japanese", english: str = "Send me the report.") -> None:
        out = self.data.out
        write_raw(out / "raw", "corpus", {"0000_en_short": row("send the report"), "0001_en_short": row("call me back")}, None)
        # The sets suite with Chinese chosen, whose English line e01 the Japanese set holds too.
        gate.write_json(out / "raw" / "sets-raw.json", {"suite": "sets", "clips": [{"set": "gate-core", "id": "e01", "text": "Send me the report."}]})
        raw = out / "pairs" / "ja" / "raw"
        write_raw(raw, "corpus", {
            "0000_en_short": row("send the report"), "0001_en_short": row("um call me back"),
            "0002_zh_short": row("今日開会", passes=1, stood="japanese"), "0003_zh_mid": row("明天下雨"), "0004_zh_mid": row("我们走吧"),
            "0005_mixed": row("这个 bug 明天 fix"), "0006_silence": row(""),
        }, language)
        write_raw(raw, "fleurs", {"0000_ja": row("明日は雨です"), "0001_ja": row("駅で会いましょう"), "0002_ja": row("Start at three", passes=2, stood="english")}, language)
        sets = {"suite": "sets", "clips": [
            {"set": "ja-mirror", "id": "m01", "text": "午後のmeetingの前に"},
            {"set": "ja-mirror", "id": "e01", "text": english},
        ]}
        if language:
            sets["dictation_language"] = language
        gate.write_json(raw / "sets-raw.json", sets)
        for name, document in (("context", context_raw(found=2)), ("latency", latency_raw(350.0))):
            if language:
                document["dictation_language"] = language
            gate.write_json(raw / f"{name}.json", document)

    def test_summarize_pairs_writes_a_summary_per_run(self):
        self.write_pair_run()
        written = gate.summarize_pairs(self.data.out, self.data.sets, self.data.corpora())
        self.assertEqual(written, ["pairs/ja/corpus", "pairs/ja/fleurs", "pairs/ja/context", "pairs/ja/latency", "pairs/ja/sets"])
        folder = self.data.out / "pairs" / "ja"
        # The context and latency runs are scored as their suites are.
        self.assertEqual(gate.read_json(folder / "context.json"), gate.summarize_context(gate.read_json(folder / "raw" / "context.json")))
        self.assertEqual(gate.read_json(folder / "context.json")["sets"]["contextasr_en"]["context"]["recall"], 100.0)
        self.assertEqual(gate.read_json(folder / "latency.json"), gate.summarize_latency(gate.read_json(folder / "raw" / "latency.json")))
        corpus = gate.read_json(folder / "corpus.json")
        # The same groups as the corpus suite's, so the same rules compare them.
        self.assertEqual(set(corpus["groups"]["text"]), {"wer_en", "cer_zh", "mer_mixed"})
        self.assertEqual(corpus["passes"], {"clips": 6, "extra_passes": {"0002_zh_short": 1}, "other_language": ["0002_zh_short"]})
        self.assertEqual(corpus["english"], {"clips": 2, "unlike": ["0001_en_short"]})
        fleurs = gate.read_json(folder / "fleurs.json")
        self.assertEqual(set(fleurs["groups"]["text"]), {"cer_ja"})
        self.assertEqual(fleurs["passes"]["other_language"], ["0002_ja"])
        self.assertIn("read_without_digits", fleurs)
        sets = gate.read_json(folder / "sets.json")
        self.assertEqual(set(sets["groups"]), {"mer_ja_en", "wer_en"})
        # meeting is an accepted spelling of ミーティング, so the lenient rate is right.
        self.assertEqual((sets["groups"]["mer_ja_en"] > 0, sets["lenient_groups"]["mer_ja_en"]), (True, 0.0))
        self.assertEqual(sets["sets"]["ja-mirror"]["clips"], 2)
        self.assertEqual(sets["english"], {"clips": 1, "unlike": []})

    def test_english_set_lines_compare_with_the_chinese_sets_run(self):
        self.write_pair_run(english="Send me the report, um.")
        gate.summarize_pairs(self.data.out, self.data.sets, self.data.corpora())
        self.assertEqual(gate.read_json(self.data.out / "pairs" / "ja" / "sets.json")["english"], {"clips": 1, "unlike": ["ja-mirror/e01"]})
        # Without the sets suite in the run, there is nothing to compare with, and the
        # Chinese pair's own sets need no comparison.
        (self.data.out / "raw" / "sets-raw.json").unlink()
        raw = self.data.out / "pairs" / "zh" / "raw"
        raw.mkdir(parents=True)
        gate.write_json(raw / "sets-raw.json", {"suite": "sets", "dictation_language": "Chinese", "clips": [{"set": "zh-mirror", "id": "m01", "text": "下午 meeting 之前"}]})
        gate.summarize_pairs(self.data.out, self.data.sets, self.data.corpora())
        self.assertIsNone(gate.read_json(self.data.out / "pairs" / "ja" / "sets.json")["english"])
        self.assertNotIn("english", gate.read_json(self.data.out / "pairs" / "zh" / "sets.json"))

    def test_a_raw_file_of_another_language_stops_the_summary(self):
        for language in ("Spanish", None):
            with self.subTest(language=language):
                self.write_pair_run(language)
                with self.assertRaises(SystemExit):
                    gate.summarize_pairs(self.data.out, self.data.sets, self.data.corpora())
        # Each run is checked, those of the context and latency suites too.
        for name, document in (("context", context_raw(found=2)), ("latency", latency_raw(350.0))):
            with self.subTest(name=name):
                self.write_pair_run()
                gate.write_json(self.data.out / "pairs" / "ja" / "raw" / f"{name}.json", document)
                with self.assertRaises(SystemExit):
                    gate.summarize_pairs(self.data.out, self.data.sets, self.data.corpora())

    def test_a_clip_id_with_two_lines_stops_the_summary(self):
        write_manifest(self.data.root / "other", [clip("0000_ja", "ja", "別の文", "fleurs-ja_jp-test")])
        with self.assertRaises(SystemExit):
            gate.merged_manifest([*self.data.corpora(), self.data.root / "other"])

    def test_wrong_pairs_summary_per_other_pair(self):
        raw = self.data.out / "wrong-pairs" / "ja" / "raw"
        write_raw(raw, "speech-corpus", {"0003_zh_mid": row("明天下雨", passes=0), "0004_zh_mid": row("Let's go", passes=2, stood="english")}, "Japanese")
        write_raw(raw, "fleurs-ko", {"0000_ko": row("約80km", passes=2, stood="japanese"), "0001_ko": row("내일 비가 와요", passes=2)}, "Japanese")
        self.assertEqual(gate.summarize_pairs(self.data.out, self.data.sets, self.data.corpora()), ["wrong-pairs/ja"])
        summary = gate.read_json(self.data.out / "wrong-pairs" / "ja" / "summary.json")["fleurs"]
        self.assertEqual(sorted(summary), ["ko", "zh"])
        self.assertEqual((summary["zh"]["group"], summary["zh"]["clips"], summary["zh"]["other_language"]), ("cer_zh", 2, ["0004_zh_mid"]))
        self.assertEqual((summary["ko"]["group"], summary["ko"]["other_language"], summary["ko"]["extra_passes"]), ("cer_ko", ["0000_ko"], {"0000_ko": 2, "0001_ko": 2}))


def corpus_summary(errors: dict[str, int], extra: dict[str, int], other: list[str], rate: float = 4.0) -> dict:
    return {
        "groups": {"text": {"cer_ja": rate}, "ruled_text": {"cer_ja": rate}},
        "decode_p90_s": 0.5,
        "clips": {clip_id: {"errors": count, "ruled_errors": count, "tokens": 10} for clip_id, count in errors.items()},
        "passes": {"clips": len(errors), "extra_passes": extra, "other_language": other},
    }


def sets_summary(errors: int) -> dict:
    return {
        "sets": {"ja-mirror": {"clips": 1, "errors": errors, "tokens": 10, "error_rate": 10.0 * errors, "expect_recall": 100.0, "forbidden_found": 0, "exact_clips": int(errors == 0)}},
        "clips": {"ja-mirror/m01": {"errors": errors, "tokens": 10, "missing_terms": [], "forbidden_found": []}},
        "groups": {"mer_ja_en": 10.0 * errors},
    }


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.base, self.cand = Path(self.folder.name, "base"), Path(self.folder.name, "cand")

    def write(self, root: Path, pair: str, name: str, summary: dict) -> None:
        (root / "pairs" / pair).mkdir(parents=True, exist_ok=True)
        gate.write_json(root / "pairs" / pair / f"{name}.json", summary)

    def test_same_results_pass_and_each_line_names_its_pair(self):
        fleurs = corpus_summary({"0000_ja": 0, "0001_ja": 1}, {"0001_ja": 1}, [])
        fleurs["read_without_digits"] = {"text": {"cer_ja": {"rate": 5.69, "clips": 138}}}
        for root in (self.base, self.cand):
            self.write(root, "ja", "fleurs", fleurs)
            self.write(root, "ja", "sets", sets_summary(0))
        result = gate.compare(self.base, self.cand, ["pairs"])
        self.assertEqual(result.failures, [])
        self.assertIn("pairs ja fleurs text cer_ja: 4.00% -> 4.00%", result.lines)
        self.assertIn("pairs ja fleurs text cer_ja, read speech without digits (138): 5.69% -> 5.69%", result.lines)
        self.assertIn("pairs ja fleurs extra passes: 1 -> 1, on 1 -> 1 of 2 clips", result.lines)
        self.assertIn("pairs ja fleurs pasted in another language: 0 -> 0 of 2 clips", result.lines)
        self.assertIn("pairs ja sets ja-mirror: error 0.00% -> 0.00%, exact clips 1 -> 1 of 1, terms 100.0% -> 100.0%, forbidden 0 -> 0", result.lines)
        self.assertIn("pairs ja sets mer_ja_en: 0.00% -> 0.00%", result.lines)

    def test_the_rules_of_the_corpus_sets_and_passes_hold_per_pair(self):
        self.write(self.base, "ja", "fleurs", corpus_summary({"0000_ja": 0, "0001_ja": 1}, {"0001_ja": 1}, []))
        self.write(self.cand, "ja", "fleurs", corpus_summary({"0000_ja": 1, "0001_ja": 1}, {"0000_ja": 2, "0001_ja": 1}, ["0000_ja"], rate=4.2))
        self.write(self.base, "ja", "sets", sets_summary(0))
        self.write(self.cand, "ja", "sets", sets_summary(1))
        result = gate.compare(self.base, self.cand, ["pairs"])
        rules = dict(result.failures)
        self.assertEqual(rules["pairs ja fleurs clips that were right and are now wrong"], ["pairs/ja/fleurs/0000_ja"])
        self.assertIn("pairs ja fleurs text cer_ja rose by 0.20 points, more than 0.1", rules)
        self.assertEqual(rules["pairs ja fleurs extra passes rose from 1 to 3"], ["pairs/ja/fleurs/0000_ja"])
        self.assertEqual(rules["pairs ja fleurs clips pasted in another language rose from 0 to 1"], ["pairs/ja/fleurs/0000_ja"])
        self.assertEqual(rules["pairs ja set clips that were right and are now wrong"], ["pairs/ja/sets/ja-mirror/m01"])
        self.assertIn("pairs ja sets ja-mirror error rate rose by 10.00 points", rules)
        self.assertIn("pairs/ja/fleurs/0000_ja extra passes 0 -> 2", result.worse)
        self.assertIn("pairs/ja/fleurs/0000_ja pasted in another language", result.worse)

    def test_the_rules_of_the_context_and_latency_suites_hold_per_pair(self):
        self.write(self.base, "ja", "context", gate.summarize_context(context_raw(found=2)))
        self.write(self.cand, "ja", "context", gate.summarize_context(context_raw(found=1, gave_text=1)))
        self.write(self.base, "ja", "latency", gate.summarize_latency(latency_raw(400.0)))
        self.write(self.cand, "ja", "latency", gate.summarize_latency(latency_raw(600.0)))
        result = gate.compare(self.base, self.cand, ["pairs"])
        rules = dict(result.failures)
        self.assertIn("pairs ja context contextasr_en term recall fell by 50.0 points", rules)
        self.assertEqual(rules["pairs ja context clips that found all their terms and now miss one"], ["pairs/ja/context/contextasr_en/c01"])
        self.assertIn("pairs ja context no_speech gave_text rose from 0 to 1", rules)
        self.assertIn("pairs ja latency cleanup_off total p90 rose from 400.0 to 600.0 ms, more than 20%", rules)
        self.assertIn("pairs ja context contextasr_en: recall 100.0% -> 50.0%, inserted 0 -> 0, error 5.00% -> 5.00%, p90 1.30 s -> 1.30 s", result.lines)
        self.assertIn("pairs ja latency cleanup_off total: median 300.0 -> 300.0 ms, p90 400.0 -> 600.0 ms", result.lines)
        self.assertIn("pairs/ja/context/contextasr_en/c01 terms found 2 -> 1", result.worse)
        # The same numbers pass.
        self.assertEqual(gate.compare(self.base, self.base, ["pairs"]).failures, [])

    def test_a_clip_that_changes_places_is_listed_without_failing(self):
        self.write(self.base, "es", "fleurs", corpus_summary({"0000_es": 0, "0001_es": 0}, {"0000_es": 1}, ["0000_es"]))
        self.write(self.cand, "es", "fleurs", corpus_summary({"0000_es": 0, "0001_es": 0}, {"0001_es": 1}, ["0001_es"]))
        result = gate.compare(self.base, self.cand, ["pairs"])
        self.assertEqual(result.failures, [])
        self.assertEqual(result.worse, ["pairs/es/fleurs/0001_es extra passes 0 -> 1", "pairs/es/fleurs/0001_es pasted in another language"])

    def test_a_run_missing_from_the_candidate_fails_and_a_new_one_has_no_baseline(self):
        self.write(self.base, "ja", "corpus", corpus_summary({"0000_en_short": 0}, {}, []))
        self.write(self.cand, "ja", "fleurs", corpus_summary({"0000_ja": 0}, {}, []))
        result = gate.compare(self.base, self.cand, ["pairs"])
        self.assertEqual(result.failures, [("pairs ja corpus: in the baseline without a result", [])])
        self.assertIn("pairs ja fleurs: no baseline, nothing to compare", result.lines)
        # A pair the candidate did not run is not compared, and no pair at all fails.
        self.write(self.base, "es", "fleurs", corpus_summary({"0000_es": 0}, {}, []))
        self.assertEqual(len(gate.compare(self.base, self.cand, ["pairs"]).failures), 1)
        self.assertEqual(gate.compare(self.base, self.base / "nothing", ["pairs"]).failures, [(f"pairs: no result in {self.base / 'nothing'}", [])])

    def test_english_clips_unlike_chinese_are_shown_and_barred_once_turned_on(self):
        summary = corpus_summary({"0000_en_short": 0, "0001_en_short": 0}, {}, [])
        summary["english"] = {"clips": 2, "unlike": ["0001_en_short"]}
        for root in (self.base, self.cand):
            self.write(root, "es", "corpus", summary)
        result = gate.compare(self.base, self.cand, ["pairs"])
        self.assertEqual(result.failures, [])
        self.assertIn("pairs es corpus English clips pasted unlike with Chinese chosen: 1 of 2, not barred yet", result.lines)
        with mock.patch.object(gate, "ENGLISH_SAME_TEXT_BARRED", True):
            result = gate.compare(self.base, self.cand, ["pairs"])
        self.assertEqual(result.failures, [("pairs es corpus English clips pasted unlike with Chinese chosen", ["pairs/es/corpus/0001_en_short"])])
        # Without the corpus suite in the run there is nothing to compare with.
        summary["english"] = None
        self.write(self.cand, "es", "corpus", summary)
        self.assertIn("pairs es corpus English clips against Chinese chosen: no corpus suite in this run", gate.compare(self.base, self.cand, ["pairs"]).lines)
        # The English lines of the sets the same way.
        sets = sets_summary(0)
        sets["english"] = {"clips": 1, "unlike": ["es-core/en_terms_1"]}
        self.write(self.cand, "es", "sets", sets)
        self.assertIn("pairs es sets English clips pasted unlike with Chinese chosen: 1 of 1, not barred yet", gate.compare(self.base, self.cand, ["pairs"]).lines)

    def test_wrong_pairs_are_shown_and_never_fail(self):
        summary = {"fleurs": {"ko": {"group": "cer_ko", "error_rate": 40.0, "clips": 50, "extra_passes": {"0000_ko": 2}, "other_language": ["0000_ko"]}}}
        for root, value in ((self.base, summary), (self.cand, copy.deepcopy(summary))):
            (root / "wrong-pairs" / "ja").mkdir(parents=True)
            gate.write_json(root / "wrong-pairs" / "ja" / "summary.json", value)
        cand = gate.read_json(self.cand / "wrong-pairs" / "ja" / "summary.json")
        cand["fleurs"]["ko"]["other_language"] += [f"x{number}" for number in range(9)]
        gate.write_json(self.cand / "wrong-pairs" / "ja" / "summary.json", cand)
        result = gate.compare(self.base, self.cand, ["wrong-pairs"])
        self.assertEqual(result.failures, [])
        self.assertEqual(result.lines, ["wrong-pairs ja chosen, FLEURS ko: 50 clips, cer_ko 40.00%, pasted in another language 10, sent to another pass 1, baseline 40.00%, 1 and 1"])
        self.assertEqual(gate.compare(self.base, Path(self.folder.name, "none"), ["wrong-pairs"]).failures[0][0], f"wrong-pairs: no result in {Path(self.folder.name, 'none')}")

    def test_show_prints_the_pairs_only_when_the_folder_has_them(self):
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.assertEqual(gate.show(self.cand), 0)
        self.assertEqual(printed.getvalue(), "")
        self.write(self.cand, "ja", "fleurs", corpus_summary({"0000_ja": 0}, {}, []))
        with contextlib.redirect_stdout(printed):
            self.assertEqual(gate.show(self.cand), 0)
        self.assertIn("pairs ja fleurs text cer_ja: 4.00% -> 4.00%", printed.getvalue())

    def test_the_pair_suites_are_known_to_compare_but_not_its_default(self):
        self.assertNotIn("pairs", gate.SUITES)
        self.assertNotIn("wrong-pairs", gate.SUITES)
        arguments = ["gate.py", "compare", str(self.base), str(self.cand), "--only", "pairs,nonsense"]
        with mock.patch.object(sys, "argv", arguments), self.assertRaises(SystemExit) as stop:
            gate.main()
        self.assertEqual(str(stop.exception), "unknown suites: nonsense")


if __name__ == "__main__":
    unittest.main()
