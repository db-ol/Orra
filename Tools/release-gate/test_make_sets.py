"""Tests of the set maker, Tools/release-gate/sets/make_sets.py, that need no voice, so they
run on any system. Standard library only:

    python3 -m unittest discover -s Tools/release-gate -p 'test_*.py' -v
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock

import gate

sys.path.insert(0, str(Path(__file__).resolve().parent / "sets"))
import make_sets  # noqa: E402

GATE_SETS = ["gate-core", "homophone-distractors", "latency-say", "zh-numbers-negation"]


def lines(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class RepositorySetTests(unittest.TestCase):
    def test_every_set_passes_its_checks(self):
        names = make_sets.set_names([])
        self.assertEqual([name for name in names if "/" not in name], GATE_SETS)
        self.assertEqual(len([name for name in names if name.startswith("pairs/")]), 18)
        for name in names:
            with self.subTest(set=name):
                sentences, variants, _ = make_sets.load_set(make_sets.HERE / name)
                self.assertTrue(make_sets.manifest_lines(sentences, variants))

    def test_the_gate_sets_keep_their_manifest_lines(self):
        # The sets the gate runs today get no new key, so a rebuild writes the same manifest.
        for name in GATE_SETS:
            sentences, variants, settings = make_sets.load_set(make_sets.HERE / name)
            self.assertNotIn("pair", settings)
            for line in make_sets.manifest_lines(sentences, variants):
                self.assertEqual(list(line), ["id", "language", "reference", "context", "expect_terms", "forbid_terms"])

    def test_pair_sets_name_their_pair_and_have_a_readme(self):
        for name in make_sets.set_names(["pairs"]):
            with self.subTest(set=name):
                _, _, settings = make_sets.load_set(make_sets.HERE / name)
                self.assertIn(settings.get("pair"), make_sets.PAIRS)
                self.assertTrue(name.split("/")[1].startswith(settings["pair"] + "-"))
                self.assertTrue((make_sets.HERE / name / "README.md").exists())

    def test_the_mirror_sets_hold_the_situations_of_the_template(self):
        template = lines(make_sets.HERE / "pairs/mirror-template.jsonl")
        kinds = [row["kind"] for row in template]
        self.assertEqual([kinds.count(kind) for kind in ("terms", "names", "numbers", "replies", "corrections")], [20, 10, 10, 10, 10])
        for pair in make_sets.PAIRS:
            with self.subTest(pair=pair):
                sentences, _, _ = make_sets.load_set(make_sets.HERE / f"pairs/{pair}-mirror")
                self.assertEqual([row["id"] for row in sentences], [row["id"] for row in template])
                self.assertTrue(all(row["expect_terms"] for row in sentences))

    def test_pair_sets_hold_the_english_lines_unchanged(self):
        for source, kind in (("gate-core", "core"), ("latency-say", "latency")):
            english = {row["id"]: row for row in lines(make_sets.HERE / source / "sentences.jsonl") if row["language"] == "en"}
            for pair in ("ja", "es", "ko"):
                with self.subTest(set=f"{pair}-{kind}"):
                    copied = [row for row in lines(make_sets.HERE / f"pairs/{pair}-{kind}/sentences.jsonl") if row["language"] == "en"]
                    self.assertEqual(copied, list(english.values()))


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp()) / "a-set"
        self.folder.mkdir()

    def write(self, rows: list[dict], settings: dict | None = None) -> Path:
        with open(self.folder / "sentences.jsonl", "w", encoding="utf-8") as out:
            for row in rows:
                out.write(json.dumps({"language": "ko", "expect_terms": [], "forbid_terms": [], **row}, ensure_ascii=False) + "\n")
        (self.folder / "set.json").unlink(missing_ok=True)
        if settings is not None:
            (self.folder / "set.json").write_text(json.dumps(settings), encoding="utf-8")
        return self.folder

    def failure(self, rows: list[dict], settings: dict | None = None) -> str:
        with self.assertRaises(make_sets.SetError) as raised:
            make_sets.load_set(self.write(rows, settings))
        return str(raised.exception)

    def test_terms_match_as_the_gate_matches_them(self):
        cases = [
            ("자세한 내용은 Slack으로 공유할게요.", "Slack"),
            ("We wrote it in trust.", "Rust"),
            ("We wrote it in Rust.", "Rust"),
            ("Released GPT5 today.", "GPT 5"),
            ("Move the cursor here.", "Cursor"),
            ("오후 3시 반에 봐요.", "3시반"),
            ("这个文件有3.5GB。", "3.5GB"),
            ("Ｓｌａｃｋで共有します。", "Slack"),
        ]
        for text, term in cases:
            with self.subTest(term=term, text=text):
                self.assertEqual(make_sets.holds_term(text, term), gate.term_found(term, text))

    def test_a_list_of_spellings_starts_with_the_reference_form(self):
        message = self.failure([{"id": "a", "say": "슬랙", "reference": "슬랙으로 보낼게요.", "expect_terms": [["Slack", "슬랙"]]}])
        self.assertIn("'Slack', the first spelling of its list, is not in the reference", message)
        sentences, _, _ = make_sets.load_set(self.write([{"id": "a", "say": "슬랙", "reference": "Slack으로 보낼게요.", "expect_terms": [["Slack", "슬랙"]]}]))
        self.assertEqual(sentences[0]["expect_terms"], [["Slack", "슬랙"]])

    def test_a_list_of_spellings_needs_two_different_ones(self):
        for spellings in (["Slack"], ["Slack", "Slack"], ["Slack", ""], "Slack"):
            with self.subTest(spellings=spellings):
                message = self.failure([{"id": "a", "say": "x", "reference": "Slack", "accepted": [spellings]}])
                self.assertIn("two or more different spellings", message)

    def test_a_plain_term_must_be_in_the_reference_and_a_forbidden_one_not(self):
        self.assertIn("expected term 'Rust' is not in the reference", self.failure([{"id": "a", "say": "x", "reference": "trust me", "expect_terms": ["Rust"]}]))
        self.assertIn("forbidden term 'Notion'", self.failure([{"id": "a", "say": "x", "reference": "Notion에 정리할게요.", "forbid_terms": ["Notion"]}]))

    def test_a_pair_a_language_and_the_parts_of_say_are_checked(self):
        self.assertIn("pair must be one of zh, ja, es, ko", self.failure([{"id": "a", "say": "x", "reference": "x"}], {"pair": "fr"}))
        self.assertIn("language must be one of", self.failure([{"id": "a", "language": "fr", "say": "x", "reference": "x"}]))
        self.assertIn("say must be a text or a list", self.failure([{"id": "a", "say": [["Samantha"]], "reference": "x"}]))
        self.assertIn("duplicate sentence ids", self.failure([{"id": "a", "say": "x", "reference": "x"}, {"id": "a", "say": "y", "reference": "y"}]))
        rows = [{"id": "a", "language": "ja", "say": [["Samantha", "Um,"], ["Kyoko", "明日です。"]], "reference": "明日です。"}]
        sentences, _, _ = make_sets.load_set(self.write(rows))
        self.assertEqual(make_sets.parts(sentences[0], "a"), [("Samantha", "Um,"), ("Kyoko", "明日です。")])
        self.assertEqual(make_sets.parts({"language": "ko", "say": "네"}, "b"), [("Yuna", "네")])

    def test_manifest_lines_carry_every_list_of_spellings(self):
        rows = [
            {"id": "a", "say": "x", "reference": "Slack에 올리고 3시 반에 봐요.", "context": ["Slack"],
             "expect_terms": ["Slack", ["3시 반", "세 시 반"], ["Slack", "슬랙"]], "accepted": [["3시 반", "세 시 반"], ["봐요", "봬요"]]},
            {"id": "b", "say": "y", "reference": "네", "context": ["Slack"]},
        ]
        variants = [{"suffix": "_ctx0", "context": []}, {"suffix": "_own"}]
        sentences, variants, settings = make_sets.load_set(self.write(rows, {"pair": "ko", "variants": variants}))
        self.assertEqual(settings["pair"], "ko")
        manifest = make_sets.manifest_lines(sentences, variants)
        self.assertEqual([line["id"] for line in manifest], ["a_ctx0", "a_own", "b_ctx0", "b_own"])
        self.assertEqual([line["context"] for line in manifest], [[], ["Slack"], [], ["Slack"]])
        self.assertEqual(manifest[0]["accepted"], [["3시 반", "세 시 반"], ["Slack", "슬랙"], ["봐요", "봬요"]])
        self.assertEqual(manifest[0]["expect_terms"], rows[0]["expect_terms"])
        self.assertNotIn("accepted", manifest[2])

    def test_set_names_stand_for_sets_and_folders_of_sets(self):
        pairs = make_sets.set_names(["pairs"])
        self.assertIn("pairs/ko-mirror", pairs)
        self.assertEqual(make_sets.set_names(["gate-core", "pairs/ja-core", "gate-core"]), ["gate-core", "pairs/ja-core"])
        with self.assertRaises(make_sets.SetError):
            make_sets.set_names(["no-such-set"])
        with self.assertRaises(make_sets.SetError):
            make_sets.set_names(["../../speech-eval"])


class SpeakTests(unittest.TestCase):
    def test_parts_are_joined_into_one_clip(self):
        def fake_run(command, check):
            # say writes nothing here, afconvert writes a clip of one sample per letter of the voice.
            if command[0] == "afconvert":
                voice = Path(command[-2]).read_text(encoding="utf-8")
                with wave.open(command[-1], "wb") as writer:
                    writer.setnchannels(1)
                    writer.setsampwidth(2)
                    writer.setframerate(16000)
                    writer.writeframes(b"\x01\x00" * len(voice))
            else:
                Path(command[command.index("-o") + 1]).write_text(command[2], encoding="utf-8")

        scratch = Path(tempfile.mkdtemp())
        target = scratch / "clip.wav"
        with mock.patch.object(make_sets.subprocess, "run", side_effect=fake_run):
            make_sets.speak([("Samantha", "Um,"), ("Kyoko", "明日です。")], target, scratch)
        with wave.open(str(target), "rb") as reader:
            self.assertEqual((reader.getnchannels(), reader.getsampwidth(), reader.getframerate()), (1, 2, 16000))
            self.assertEqual(reader.getnframes(), len("Samantha") + len("Kyoko"))


if __name__ == "__main__":
    unittest.main()
