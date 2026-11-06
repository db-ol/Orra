# Tests for build_fleurs.py, without the network. CI runs them on Linux:
#
#     python3 -m unittest discover -s Tools/speech-eval -p 'test_*.py'

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import random
import re
import struct
import tarfile
import tempfile
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

import build_fleurs


def float_wav(samples: list[float], rate: int = 16000, channels: int = 1, tag: int = 3, bits: int = 32) -> bytes:
    """A WAVE file laid out as FLEURS lays out its recordings: a fmt chunk of 18 bytes, a
    fact chunk and the data."""
    code = {(3, 32): "f", (1, 16): "h"}[(tag, bits)]
    data = struct.pack(f"<{len(samples)}{code}", *samples)
    fmt = struct.pack("<HHIIHHH", tag, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits, 0)
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"fact" + struct.pack("<II", 4, len(samples)) + b"data" + struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


def pcm16_values(wav: bytes) -> list[int]:
    return list(struct.unpack(f"<{(len(wav) - 44) // 2}h", wav[44:]))


def quiet() -> contextlib.AbstractContextManager:
    return contextlib.redirect_stdout(io.StringIO())


def no_download(url: str, target: Path) -> None:
    raise AssertionError(f"tried to download {url}")


class TsvTests(unittest.TestCase):
    def test_unquote_undoes_the_quoting_of_a_csv_writer(self) -> None:
        self.assertEqual(build_fleurs.unquote('"그는 ""무정부""라고 했다. "'), '그는 "무정부"라고 했다. ')
        self.assertEqual(build_fleurs.unquote("plain text"), "plain text")
        self.assertEqual(build_fleurs.unquote('text with "quotes" inside'), 'text with "quotes" inside')
        self.assertEqual(build_fleurs.unquote('"'), '"')

    def test_read_tsv(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "test.tsv"
            path.write_text(
                "1700\t12.wav\t\"그는 \"\"무정부\"\"라고 했다. \"\tx\tx\t960\tMALE\n"
                "1650\t9.wav\tPlain text.\tplain text\tp l a i n\t1920\tFEMALE\n",
                encoding="utf-8",
            )
            rows = build_fleurs.read_tsv(path)
        self.assertEqual(rows, [
            {"sentence_id": "1700", "source_id": "12", "text": '그는 "무정부"라고 했다.', "samples": 960},
            {"sentence_id": "1650", "source_id": "9", "text": "Plain text.", "samples": 1920},
        ])

    def test_read_tsv_refuses_other_rows(self) -> None:
        for line in ("1700\t12.wav\ttext\tx\tx\t960\n", "1700\t../12.wav\ttext\tx\tx\t960\tMALE\n", "1700\t12.wav\ttext\tx\tx\tmany\tMALE\n"):
            with self.subTest(line=line), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "test.tsv"
                path.write_text(line, encoding="utf-8")
                with self.assertRaises(SystemExit):
                    build_fleurs.read_tsv(path)

    def test_first_recordings_takes_the_first_row_of_each_sentence_sorted_by_file_name(self) -> None:
        rows = [
            {"sentence_id": "1", "source_id": "9"},
            {"sentence_id": "2", "source_id": "5"},
            {"sentence_id": "1", "source_id": "1"},
            {"sentence_id": "3", "source_id": "10"},
        ]
        self.assertEqual([row["source_id"] for row in build_fleurs.first_recordings(rows)], ["10", "5", "9"])


class DrawTests(unittest.TestCase):
    @staticmethod
    def language(count: int, left_out: set[str]) -> build_fleurs.Language:
        language = object.__new__(build_fleurs.Language)
        language.config = "ko_kr"
        language.candidates = [{"sentence_id": str(index), "source_id": str(index)} for index in range(count)]
        language.left_out = {sentence_id: "reason" for sentence_id in left_out}
        return language

    def test_the_order_starts_as_a_plain_sample_of_the_count(self) -> None:
        # The stored ja, es and yue sets were drawn with random.Random(20261004).sample(items, 200)
        # from 321, 348 and 339 sentences. ko_kr has 270.
        for count in (270, 321, 339, 348):
            language = self.language(count, set())
            self.assertEqual(language.draw(200, 20261004), random.Random(20261004).sample(language.candidates, 200), count)

    def test_a_sentence_left_out_leaves_the_rest_of_the_order(self) -> None:
        everything = [row["sentence_id"] for row in self.language(30, set()).draw(20, 7)]
        some_out = [row["sentence_id"] for row in self.language(30, {everything[3]}).draw(20, 7)]
        self.assertEqual(some_out[:19], everything[:3] + everything[4:20])
        self.assertNotIn(everything[3], some_out)

    def test_too_few_sentences(self) -> None:
        with self.assertRaises(SystemExit):
            self.language(10, {"1", "2"}).draw(9, 7)


class LatinRuleTests(unittest.TestCase):
    def test_a_latin_gloss_leaves_the_reference(self) -> None:
        self.assertEqual(build_fleurs.latin_rule("도시 비슈케크(Bishkek)가 조용했다.", []), ("도시 비슈케크가 조용했다.", ["Bishkek"], None))
        self.assertEqual(build_fleurs.latin_rule("로스비 수 (Rossby number)가 작다.", []), ("로스비 수가 작다.", ["Rossby number"], None))
        self.assertEqual(build_fleurs.latin_rule("아순시온(Asunción)과 고마(Goma).", [])[0], "아순시온과 고마.")

    def test_parentheses_without_latin_letters_stay(self) -> None:
        text = "엔젤 (2006)은 높은 기온(항상 높음)을 말했다."
        self.assertEqual(build_fleurs.latin_rule(text, []), (text, [], None))

    def test_latin_letters_with_hangul_or_digits_in_parentheses_keep_the_sentence_out(self) -> None:
        for text, part in (("80 km (50 mi)에 이른다.", "(50 mi)"), ("누어(Noor, 빛) 산", "(Noor, 빛)")):
            with self.subTest(text=text):
                reason = build_fleurs.latin_rule(text, [["km", "킬로미터"]])[2]
                self.assertIn(part, reason)

    def test_latin_letters_outside_parentheses_need_accepted_spellings(self) -> None:
        text = "TogiNet Radio에서 방송했다."
        self.assertIn("TogiNet, Radio", build_fleurs.latin_rule(text, [])[2])
        self.assertIn("Radio", build_fleurs.latin_rule(text, [["TogiNet", "토기넷"]])[2])
        self.assertIsNone(build_fleurs.latin_rule(text, [["TogiNet", "토기넷"], ["Radio", "라디오"]])[2])

    def test_reference_of_keeps_the_lists_and_checks_them(self) -> None:
        row = {"sentence_id": "1", "text": "약 70km, 먼 쪽이 약 100km 두께입니다."}
        lists = [["km", "킬로미터", "킬로"]]
        self.assertEqual(build_fleurs.reference_of("ko_kr", row, {"1": lists}), (row["text"], lists, [], None))
        with self.assertRaises(SystemExit):
            build_fleurs.reference_of("ko_kr", {"sentence_id": "1", "text": "약 70km와 킬로미터."}, {"1": lists})
        with self.assertRaises(SystemExit):
            build_fleurs.reference_of("ja_jp", {"sentence_id": "1", "text": "約70キロ"}, {"1": lists})

    def test_other_languages_keep_the_raw_transcription(self) -> None:
        row = {"sentence_id": "1", "text": "Sea rotunda (existan diferencias culturales o no)."}
        self.assertEqual(build_fleurs.reference_of("es_419", row, {}), (row["text"], [], [], None))


class DataFileTests(unittest.TestCase):
    def test_the_accepted_spellings(self) -> None:
        accepted = build_fleurs.load_accepted()
        self.assertEqual(set(accepted), {"ko_kr"})
        for sentence_id, lists in accepted["ko_kr"].items():
            for forms in lists:
                with self.subTest(sentence=sentence_id, forms=forms):
                    self.assertTrue(build_fleurs.LATIN.search(forms[0]))
                    for other in forms[1:]:
                        self.assertTrue(build_fleurs.HANGUL.search(other))
                        self.assertFalse(build_fleurs.LATIN.search(other))

    def test_a_list_needs_two_different_spellings_of_a_known_config(self) -> None:
        for data in (
            {"ko_kr": {"1": [["km"]]}},
            {"ko_kr": {"1": [["km", "km"]]}},
            {"ko_kr": {"1": [["km", ""]]}},
            {"ko_kr": {"1": [["km", " 킬로미터"]]}},
            {"ko_kr": {"1": ["km"]}},
            {"xx_yy": {"1": [["km", "킬로미터"]]}},
        ):
            with self.subTest(data=data), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "accepted.json"
                path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
                with self.assertRaises(SystemExit):
                    build_fleurs.load_accepted(path)

    def test_every_download_is_pinned(self) -> None:
        hashes = build_fleurs.read_hashes()
        names = [name for config in build_fleurs.LANGUAGES for name in build_fleurs.downloads(config)]
        self.assertEqual(sorted(hashes), sorted(names))
        for name in names:
            self.assertRegex(hashes[name], r"^[0-9a-f]{64}$")


class AudioTests(unittest.TestCase):
    def test_float_to_16_bit(self) -> None:
        samples = build_fleurs.float_samples(float_wav([0.0, 0.5, -0.5, 0.75, 1.0, -1.0, 2.0, -2.0, 5.96e-8, -5.96e-8]))
        wav = build_fleurs.pcm16(samples)
        self.assertEqual(pcm16_values(wav), [0, 16384, -16384, 24575, 32767, -32767, 32767, -32768, 0, 0])
        self.assertEqual(len(wav), 44 + 20)
        self.assertEqual(wav[:4] + wav[8:16], b"RIFFWAVEfmt ")
        self.assertEqual(struct.unpack("<IIHHIIHH4sI", wav[4:8] + wav[16:44]), (56, 16, 1, 1, 16000, 32000, 2, 16, b"data", 20))

    def test_only_32_bit_float_mono_at_16_khz(self) -> None:
        for wav in (float_wav([0, 1], tag=1, bits=16), float_wav([0.0, 0.0], channels=2), float_wav([0.0], rate=44100), b"RIFF\0\0\0\0WAVE", b"not a wave file"):
            with self.subTest(wav=wav[:24]), self.assertRaises(ValueError):
                build_fleurs.float_samples(wav)

    def test_a_sample_that_is_not_a_number(self) -> None:
        with self.assertRaises(ValueError):
            build_fleurs.pcm16(build_fleurs.float_samples(float_wav([0.0, float("nan")])))


class ExtractTests(unittest.TestCase):
    def test_only_regular_audio_files_with_safe_names(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive = root / "audio.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                def add(name: str, kind: bytes = tarfile.REGTYPE, data: bytes = b"wave", link: str = "") -> None:
                    info = tarfile.TarInfo(name)
                    info.type, info.linkname = kind, link
                    info.size = len(data) if kind == tarfile.REGTYPE else 0
                    tar.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
                add("test", tarfile.DIRTYPE)
                add("test/1.wav", data=b"first")
                add("test/2.wav", tarfile.SYMTYPE, link="/etc/hosts")
                add("test/3.wav", tarfile.LNKTYPE, link="test/1.wav")
                add("../4.wav")
                add("/tmp/5.wav")
                add("test/sub/6.wav")
                add("test/../7.wav")
                add("test/8.txt")
                add("test/9.wav", tarfile.FIFOTYPE)
                add("other/test/10.wav")
                add("test/11.wav", data=b"too large")
            target = root / "out" / "extracted"
            with mock.patch.object(build_fleurs, "MAX_AUDIO_BYTES", 8):
                skipped = build_fleurs.extract(archive, target)
            self.assertEqual(skipped, ["test/2.wav", "test/3.wav", "../4.wav", "/tmp/5.wav", "test/sub/6.wav", "test/../7.wav", "test/8.txt", "test/9.wav", "other/test/10.wav", "test/11.wav"])
            written = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file())
            self.assertEqual(written, ["audio.tar.gz", "out/extracted/.done", "out/extracted/test/1.wav"])
            self.assertEqual((target / "test" / "1.wav").read_bytes(), b"first")
            self.assertEqual(build_fleurs.extract(archive, target), [])


class FetchTests(unittest.TestCase):
    DATA = b"the archive"
    PINNED = hashlib.sha256(DATA).hexdigest()

    def test_a_copy_with_the_pinned_hash_is_read_where_it_is(self) -> None:
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(build_fleurs, "download", no_download), quiet():
            have = Path(folder) / "have"
            have.mkdir()
            (have / "a.tar.gz").write_bytes(self.DATA)
            path = build_fleurs.fetch("a.tar.gz", "https://example.invalid/a", self.PINNED, Path(folder) / "raw", [have])
            self.assertEqual(path, have / "a.tar.gz")
            self.assertFalse((Path(folder) / "raw").exists())

    def test_a_download_must_match_the_pin(self) -> None:
        for data, kept in ((self.DATA, "a.tar.gz"), (b"something else", "a.tar.gz.partial")):
            with self.subTest(kept=kept), tempfile.TemporaryDirectory() as folder, quiet():
                have = Path(folder) / "have"
                have.mkdir()
                (have / "a.tar.gz").write_bytes(b"an old copy")
                raw = Path(folder) / "raw"
                with mock.patch.object(build_fleurs, "download", lambda url, target: target.write_bytes(data)):
                    if kept == "a.tar.gz":
                        self.assertEqual(build_fleurs.fetch("a.tar.gz", "https://example.invalid/a", self.PINNED, raw, [have]), raw / "a.tar.gz")
                    else:
                        with self.assertRaises(SystemExit):
                            build_fleurs.fetch("a.tar.gz", "https://example.invalid/a", self.PINNED, raw, [have])
                self.assertEqual(sorted(path.name for path in raw.iterdir()), [kept])
                self.assertEqual((have / "a.tar.gz").read_bytes(), b"an old copy")

    def test_a_download_needs_a_pin(self) -> None:
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(build_fleurs, "download", no_download):
            with self.assertRaises(SystemExit):
                build_fleurs.fetch("a.tar.gz", "https://example.invalid/a", None, Path(folder), [])

    def test_a_redirect_must_stay_on_https(self) -> None:
        request = urllib.request.Request("https://huggingface.co/datasets/google/fleurs/resolve/main/data/ko_kr/test.tsv")
        handler = build_fleurs.HttpsOnly()
        with self.assertRaises(SystemExit):
            handler.redirect_request(request, None, 302, "Found", {}, "http://cdn.example.invalid/test.tsv")
        followed = handler.redirect_request(request, None, 302, "Found", {}, "https://cdn.example.invalid/test.tsv")
        self.assertEqual(followed.full_url, "https://cdn.example.invalid/test.tsv")


class SetTests(unittest.TestCase):
    """A small split laid out as FLEURS lays out ko_kr, built and rebuilt."""

    SENTENCES = [
        ("1001", "5", "평범한 문장입니다.", 2),
        ("1002", "31", "도시 비슈케크(Bishkek)가 조용했다.", 1),
        ("1003", "17", "약 70km 떨어져 있다.", 1),
        ("1004", "8", "80 km (50 mi)에 이른다.", 1),
        ("1005", "42", "\"그는 \"\"무정부\"\"라고 했다.\"", 1),
        ("1006", "11", "Sie라는 단어.", 1),
    ]
    ACCEPTED = {"ko_kr": {"1003": [["km", "킬로미터", "킬로"]]}}

    def setUp(self) -> None:
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.addCleanup(self.folder.cleanup)
        self.split = self.root / "split"
        self.split.mkdir()
        lines, members = [], []
        for sentence_id, file_id, text, recordings in self.SENTENCES:
            for take in range(recordings):
                name = f"{file_id}{take or ''}.wav"
                frames = 960 * (int(file_id) % 4 + 1)
                lines.append(f"{sentence_id}\t{name}\t{text}\tnormalized\tchars\t{frames}\tMALE")
                members.append((name, float_wav([((index % 7) - 3) / 8 for index in range(frames)])))
        (self.split / "fleurs-ko_kr-test.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
        with tarfile.open(self.split / "fleurs-ko_kr-test.tar.gz", "w:gz") as tar:
            for name, data in members:
                info = tarfile.TarInfo(f"test/{name}")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        self.hashes = {path.name: build_fleurs.sha256(path) for path in self.split.iterdir()}
        patcher = mock.patch.object(build_fleurs, "download", no_download)
        patcher.start()
        self.addCleanup(patcher.stop)

    def build(self, out: Path, count: int = 3) -> list[dict]:
        with quiet():
            return build_fleurs.build(out, ["ko_kr"], count, 20261004, [self.split], self.hashes, self.ACCEPTED)

    def test_build_and_rebuild(self) -> None:
        first = self.root / "first"
        lines = self.build(first)
        self.assertEqual([line["id"] for line in lines], ["0000_ko", "0001_ko", "0002_ko"])
        self.assertEqual(len({line["sentence_id"] for line in lines}), 3)
        self.assertFalse({"1004", "1006"} & {line["sentence_id"] for line in lines})
        for line in lines:
            self.assertEqual(list(line)[:8], ["id", "stratum", "lang", "source", "source_id", "sentence_id", "duration", "reference"])
            self.assertEqual((line["stratum"], line["lang"], line["source"]), ("ko", "ko", "fleurs-ko_kr-test"))
            clip = (first / "clips" / f"{line['id']}.wav").read_bytes()
            self.assertEqual(line["duration"], round((len(clip) - 44) / 2 / 16000, 3))
        stored = [json.loads(text) for text in (first / "manifest.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(stored, lines)
        readme = (first / "README.md").read_text(encoding="utf-8")
        self.assertIn("CC BY 4.0", readme)
        self.assertIn("1004: Latin letters with Hangul or digits in parentheses: (50 mi)", readme)
        self.assertIn("1006: Latin letters outside parentheses without accepted spellings: Sie", readme)
        self.assertNotRegex(readme, "[;\u2013\u2014]")

        second = self.root / "second"
        with quiet():
            build_fleurs.rebuild(first / "manifest.jsonl", second, [self.split], self.hashes, self.ACCEPTED)
        self.assertEqual(build_fleurs.compare(second, first / "manifest.jsonl"), ([], 3))

    def test_the_rule_on_every_sentence_kept(self) -> None:
        lines = self.build(self.root / "all", count=4)
        by_sentence = {line["sentence_id"]: line for line in lines}
        self.assertEqual(sorted(by_sentence), ["1001", "1002", "1003", "1005"])
        self.assertEqual(by_sentence["1002"]["reference"], "도시 비슈케크가 조용했다.")
        self.assertEqual(by_sentence["1003"]["accepted"], [["km", "킬로미터", "킬로"]])
        self.assertEqual(by_sentence["1005"]["reference"], '그는 "무정부"라고 했다.')
        self.assertNotIn("accepted", by_sentence["1001"])
        self.assertEqual(by_sentence["1001"]["source_id"], "5")
        with self.assertRaises(SystemExit):
            self.build(self.root / "too-many", count=5)

    def test_compare_names_what_differs(self) -> None:
        first = self.root / "first"
        self.build(first)
        stored = self.root / "stored"
        stored.mkdir()
        (stored / "clips").mkdir()
        text = (first / "manifest.jsonl").read_text(encoding="utf-8")
        (stored / "manifest.jsonl").write_text(text.replace('"duration": ', '"duration": 1', 1), encoding="utf-8")
        for path in (first / "clips").iterdir():
            (stored / "clips" / path.name).write_bytes(path.read_bytes())
        (stored / "clips" / "0001_ko.wav").write_bytes(b"other")
        problems, compared = build_fleurs.compare(first, stored / "manifest.jsonl")
        self.assertEqual(compared, 3)
        self.assertEqual(problems, ["manifest.jsonl line 1 (0000_ko): duration differ", "clips/0001_ko.wav differs from the stored clip"])

    def test_a_folder_with_a_set_is_never_written(self) -> None:
        first = self.root / "first"
        self.build(first)
        before = (first / "manifest.jsonl").read_bytes()
        with self.assertRaises(SystemExit):
            self.build(first)
        with self.assertRaises(SystemExit), quiet():
            build_fleurs.rebuild(first / "manifest.jsonl", first, [self.split], self.hashes, self.ACCEPTED)
        self.assertEqual((first / "manifest.jsonl").read_bytes(), before)

    def test_rebuild_refuses_unknown_sources_and_clip_ids(self) -> None:
        first = self.root / "first"
        self.build(first)
        line = json.loads((first / "manifest.jsonl").read_text(encoding="utf-8").splitlines()[0])
        for change, number in (({"source": "fleurs-xx_yy-test"}, 1), ({"id": "../escape"}, 2), ({"source_id": "999"}, 3)):
            with self.subTest(change=change):
                manifest = self.root / f"changed-{number}.jsonl"
                manifest.write_text(json.dumps({**line, **change}, ensure_ascii=False) + "\n", encoding="utf-8")
                with self.assertRaises(SystemExit), quiet():
                    build_fleurs.rebuild(manifest, self.root / f"rebuilt-{number}", [self.split], self.hashes, self.ACCEPTED)
        self.assertEqual(list(self.root.rglob("escape*")), [])
        with self.assertRaises(SystemExit):
            build_fleurs.config_of("fleurs-xx_yy-test")
        twice = self.root / "twice.jsonl"
        twice.write_text((json.dumps(line, ensure_ascii=False) + "\n") * 2, encoding="utf-8")
        with self.assertRaises(SystemExit), quiet():
            build_fleurs.rebuild(twice, self.root / "rebuilt-twice", [self.split], self.hashes, self.ACCEPTED)

    def test_a_recording_must_have_the_length_of_its_row(self) -> None:
        tsv = self.split / "fleurs-ko_kr-test.tsv"
        tsv.write_text(re.sub(r"\t(\d+)\tMALE", lambda match: f"\t{int(match.group(1)) + 1}\tMALE", tsv.read_text(encoding="utf-8")), encoding="utf-8")
        self.hashes[tsv.name] = build_fleurs.sha256(tsv)
        with self.assertRaises(SystemExit):
            self.build(self.root / "first")


if __name__ == "__main__":
    unittest.main()
