#!/usr/bin/env python3
"""Builds sets of FLEURS test recordings for the speech evaluation, or rebuilds a stored set
from its manifest.

FLEURS is Google's set of read sentences in 102 languages (Conneau et al., 2022, "FLEURS:
Few-shot Learning Evaluation of Universal Representations of Speech"),
https://huggingface.co/datasets/google/fleurs, licensed under CC BY 4.0
(https://creativecommons.org/licenses/by/4.0/). Every set this script builds gets a
README.md with that attribution, the downloads and the changes made.

A set holds COUNT distinct sentences per language. The candidates are the first recording
of every sentence id in the test split's test.tsv, sorted by file name.
random.Random(SEED).sample puts them in an order, and the language takes the first COUNT
that its reference rule keeps. Every language draws with its own generator. The clips are
the recordings as 16 kHz mono 16 bit WAVE, clips/<number>_<language>.wav in the order
drawn, and manifest.jsonl has one line per clip in the layout of the speech corpus, which
score.py reads:

    {"id", "stratum", "lang", "source", "source_id", "sentence_id", "duration", "reference"}

and "accepted" after "reference" on a clip with accepted spellings. The reference is the
raw transcription. Korean references follow the Latin letter rule of latin_rule, with the
accepted spellings of fleurs-accepted.json.

Usage, standard library only:

    python3 -I Tools/speech-eval/build_fleurs.py build --count 200 --seed 20261004 OUT ko_kr
    python3 -I Tools/speech-eval/build_fleurs.py rebuild MANIFEST OUT

build takes test.tsv and audio/test.tar.gz of each language from a folder named with
--downloads, which it only reads, or from OUT/raw, and downloads a file into OUT/raw only
when neither has a copy with the SHA-256 pinned in fleurs.sha256. It extracts the
archive's regular files named test/<digits>.wav, and nothing else, into
OUT/extracted/<language>/test. With --compare it then compares the set with a stored one.

rebuild takes the clips, their ids and their order from a stored manifest, makes everything
else again from the downloads, writes the set into OUT and compares its manifest and clips
byte for byte with the stored manifest and the clips next to it.

OUT must not hold a set already. A comparison that finds a difference exits with 1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import struct
import sys
import tarfile
import urllib.request
from array import array
from pathlib import Path

HERE = Path(__file__).resolve().parent
HASHES = HERE / "fleurs.sha256"
ACCEPTED = HERE / "fleurs-accepted.json"
RATE = 16000
BASE_URL = "https://huggingface.co/datasets/google/fleurs/resolve/main/data"
# The FLEURS configs this script knows, with the language of their clips, which is also
# their stratum.
LANGUAGES = {"ja_jp": "ja", "es_419": "es", "yue_hant_hk": "yue", "ko_kr": "ko"}
# The configs whose references follow latin_rule.
LATIN_RULE = frozenset({"ko_kr"})
AUDIO_NAME = re.compile(r"[0-9]+\.wav")
AUDIO_MEMBER = re.compile(r"test/([0-9]+\.wav)")
MAX_AUDIO_BYTES = 64 << 20
CLIP_ID = re.compile(r"[0-9A-Za-z_]+")
# Latin letters with accents, Hangul and digits, as escapes, since an editor that normalizes
# text could change a character of a range.
LATIN = re.compile(r"[A-Za-z\u00c0-\u024f]")
LATIN_WORD = re.compile(r"[A-Za-z\u00c0-\u024f]+(?:-[A-Za-z\u00c0-\u024f]+)*")
HANGUL = re.compile(r"[\u1100-\u11ff\u3130-\u318f\ua960-\ua97f\uac00-\ud7ff]")
DIGIT = re.compile(r"[0-9\uff10-\uff19]")
# A part in parentheses, with the space before it.
PARENTHESES = re.compile(r"\s*\(([^()]*)\)")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_hashes(path: Path = HASHES) -> dict[str, str]:
    hashes = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            digest, name = line.split(maxsplit=1)
            hashes[name] = digest
    return hashes


def load_accepted(path: Path = ACCEPTED) -> dict[str, dict[str, list[list[str]]]]:
    """Accepted spellings per config and sentence id. Each list holds the form written in
    the reference first, then the other spellings that count as right."""
    data = json.loads(path.read_text(encoding="utf-8"))
    for config, sentences in data.items():
        if config not in LANGUAGES:
            raise SystemExit(f"{path.name}: unknown FLEURS config {config}")
        for sentence_id, lists in sentences.items():
            for forms in lists:
                if (
                    not isinstance(forms, list)
                    or len(forms) < 2
                    or len(set(forms)) != len(forms)
                    or not all(isinstance(form, str) and form and form == form.strip() for form in forms)
                ):
                    raise SystemExit(f"{path.name}: {config} {sentence_id}: {forms!r} is not a list of two or more spellings")
    return data


def downloads(config: str) -> dict[str, str]:
    """The two files of a language's test split, with their URLs."""
    return {
        f"fleurs-{config}-test.tsv": f"{BASE_URL}/{config}/test.tsv",
        f"fleurs-{config}-test.tar.gz": f"{BASE_URL}/{config}/audio/test.tar.gz",
    }


class HttpsOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise SystemExit(f"refusing a redirect to {newurl.split('?')[0]}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url: str, target: Path) -> None:
    with urllib.request.build_opener(HttpsOnly()).open(url, timeout=60) as response, target.open("wb") as handle:
        for block in iter(lambda: response.read(1 << 20), b""):
            handle.write(block)


def fetch(name: str, url: str, pinned: str | None, raw: Path, folders: list[Path]) -> Path:
    """A copy of a download with its pinned SHA-256: one in a folder of --downloads, which is
    only read, or one in raw, downloaded unless it is there already."""
    if not pinned:
        raise SystemExit(f"{name} has no SHA-256 in {HASHES.name}")
    for folder in [*folders, raw]:
        path = folder / name
        if path.is_file() and sha256(path) == pinned:
            print(f"have {path}")
            return path
    raw.mkdir(parents=True, exist_ok=True)
    partial = raw / f"{name}.partial"
    print(f"downloading {url}")
    download(url, partial)
    actual = sha256(partial)
    if actual != pinned:
        raise SystemExit(f"{name}: SHA-256 {actual} is not the pinned {pinned}, kept as {partial}")
    return partial.replace(raw / name)


def extract(archive: Path, target: Path) -> list[str]:
    """Extracts the regular files named test/<digits>.wav into target/test, once, and writes
    nothing else: no link, device, absolute path, .. or other folder or file. Returns the
    names of the members it left alone."""
    if (target / ".done").exists():
        return []
    folder = target / "test"
    folder.mkdir(parents=True, exist_ok=True)
    skipped = []
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            match = AUDIO_MEMBER.fullmatch(member.name)
            if match and member.isreg() and member.size <= MAX_AUDIO_BYTES:
                (folder / match.group(1)).write_bytes(tar.extractfile(member).read())
            elif not (member.isdir() and member.name.rstrip("/") == "test"):
                skipped.append(member.name)
    (target / ".done").write_text("")
    return skipped


def unquote(field: str) -> str:
    """test.tsv quotes a field that holds a double quote, as a CSV writer does."""
    if len(field) >= 2 and field.startswith('"') and field.endswith('"'):
        return field[1:-1].replace('""', '"')
    return field


def read_tsv(path: Path) -> list[dict]:
    """The rows of a test.tsv: sentence id, file name, raw transcription, normalized
    transcription, characters, number of samples and gender."""
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 7 or not re.fullmatch(r"[0-9]+", fields[0]) or not AUDIO_NAME.fullmatch(fields[1]) or not re.fullmatch(r"[0-9]+", fields[5]):
            raise SystemExit(f"{path.name}:{number}: not a row of a FLEURS test.tsv")
        rows.append({"sentence_id": fields[0], "source_id": fields[1][:-4], "text": unquote(fields[2]).strip(), "samples": int(fields[5])})
    return rows


def first_recordings(rows: list[dict]) -> list[dict]:
    """One recording per sentence, the first row of its sentence id, sorted by file name."""
    seen = set()
    items = []
    for row in rows:
        if row["sentence_id"] not in seen:
            seen.add(row["sentence_id"])
            items.append(row)
    return sorted(items, key=lambda row: row["source_id"])


def latin_rule(text: str, accepted: list[list[str]]) -> tuple[str, list[str], str | None]:
    """The Korean reference of a sentence, the glosses it dropped, and why the sentence stays
    out, or None when it stays in.

    A part in parentheses that holds Latin letters and no Hangul and no digits is a gloss,
    such as 비슈케크(Bishkek), which a reader does not read. It leaves the reference with the
    space before it. When a part in parentheses holds Latin letters with Hangul or digits, a
    reader may read some of it, so its sentence stays out. Latin letters outside parentheses
    stay only when the sentence's accepted spellings cover every one of them, each list with
    the form of the reference first."""
    glosses = []
    mixed = []

    def gloss(match: re.Match) -> str:
        inside = match.group(1)
        if not LATIN.search(inside):
            return match.group(0)
        if HANGUL.search(inside) or DIGIT.search(inside):
            mixed.append(inside)
            return match.group(0)
        glosses.append(inside)
        return ""

    reference = PARENTHESES.sub(gloss, text)
    if mixed:
        return reference, glosses, f"Latin letters with Hangul or digits in parentheses: ({mixed[0]})"
    rest = reference
    for forms in accepted:
        rest = rest.replace(forms[0], " ")
    left = list(dict.fromkeys(LATIN_WORD.findall(rest)))
    if left:
        return reference, glosses, "Latin letters outside parentheses without accepted spellings: " + ", ".join(left)
    return reference, glosses, None


def reference_of(config: str, row: dict, accepted: dict[str, list[list[str]]]) -> tuple[str, list[list[str]], list[str], str | None]:
    """The reference of a recording, its accepted spellings, the glosses dropped from it, and
    why its sentence stays out, or None."""
    lists = accepted.get(row["sentence_id"], [])
    if config in LATIN_RULE:
        reference, glosses, reason = latin_rule(row["text"], lists)
    else:
        reference, glosses, reason = row["text"], [], None
    if reason is None:
        for forms in lists:
            if forms[0] not in reference:
                raise SystemExit(f"{config} {row['sentence_id']}: the accepted form {forms[0]!r} is not in the reference")
            for other in forms[1:]:
                if other in reference:
                    raise SystemExit(f"{config} {row['sentence_id']}: the accepted spelling {other!r} is in the reference already")
    return reference, lists, glosses, reason


def float_samples(wav: bytes) -> array:
    """The samples of a FLEURS recording: RIFF WAVE, IEEE float, 32 bit, mono, 16 kHz."""
    if len(wav) < 12 or wav[:4] != b"RIFF" or wav[8:12] != b"WAVE":
        raise ValueError("not a RIFF WAVE file")
    fmt = data = None
    position = 12
    while position + 8 <= len(wav):
        chunk = wav[position:position + 4]
        size = struct.unpack_from("<I", wav, position + 4)[0]
        body = wav[position + 8:position + 8 + size]
        if chunk == b"fmt " and len(body) >= 16:
            fmt = struct.unpack_from("<HHIIHH", body)
        elif chunk == b"data":
            data = body
        position += 8 + size + (size & 1)
    if fmt is None or data is None:
        raise ValueError("no fmt or no data chunk")
    tag, channels, rate, _, _, bits = fmt
    if (tag, channels, rate, bits) != (3, 1, RATE, 32) or len(data) % 4:
        raise ValueError(f"format {tag}, {channels} channels, {rate} Hz, {bits} bit, not 32 bit float mono at {RATE} Hz")
    samples = array("f")
    samples.frombytes(data)
    if sys.byteorder == "big":
        samples.byteswap()
    return samples


def pcm16(samples: array) -> bytes:
    """16 bit WAVE with a 44 byte header. Each sample is multiplied by 32767 and rounded half
    to even, which gives the stored ja, es and yue clips byte for byte. A sample beyond -1 or
    1 would be clipped, and none of the four sets has one."""
    try:
        values = array("h", [max(-32768, min(32767, round(32767.0 * sample))) for sample in samples])
    except (ValueError, OverflowError):
        raise ValueError("a sample is not a finite number") from None
    if sys.byteorder == "big":
        values.byteswap()
    data = values.tobytes()
    fmt = struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
    return b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE" + b"fmt " + fmt + b"data" + struct.pack("<I", len(data)) + data


def check_out(out: Path) -> None:
    if (out / "manifest.jsonl").exists() or (out / "clips").exists():
        raise SystemExit(f"{out} holds a set already. Build into a new folder.")


def config_of(source: str) -> str:
    match = re.fullmatch(r"fleurs-(.+)-test", source)
    if not match or match.group(1) not in LANGUAGES:
        raise SystemExit(f"{source} is not a FLEURS test split this script knows")
    return match.group(1)


class Language:
    """The test split of one language, fetched, checked and extracted."""

    def __init__(self, config: str, out: Path, folders: list[Path], hashes: dict[str, str], accepted: dict[str, dict]):
        if config not in LANGUAGES:
            raise SystemExit(f"unknown FLEURS config {config}, known: {', '.join(LANGUAGES)}")
        self.config = config
        self.lang = LANGUAGES[config]
        self.accepted = accepted.get(config, {})
        self.files = {name: (url, fetch(name, url, hashes.get(name), out / "raw", folders)) for name, url in downloads(config).items()}
        self.hashes = {name: hashes[name] for name in self.files}
        tsv = self.files[f"fleurs-{config}-test.tsv"][1]
        skipped = extract(self.files[f"fleurs-{config}-test.tar.gz"][1], out / "extracted" / config)
        if skipped:
            print(f"{config}: left {len(skipped)} members of the archive alone, such as {skipped[0]}")
        self.audio = out / "extracted" / config / "test"
        self.rows = read_tsv(tsv)
        self.by_source = {row["source_id"]: row for row in self.rows}
        self.candidates = first_recordings(self.rows)
        self.left_out = {}
        for row in self.candidates:
            reason = reference_of(config, row, self.accepted)[3]
            if reason:
                self.left_out[row["sentence_id"]] = reason

    def draw(self, count: int, seed: int) -> list[dict]:
        order = random.Random(seed).sample(self.candidates, len(self.candidates))
        kept = [row for row in order if row["sentence_id"] not in self.left_out]
        if len(kept) < count:
            raise SystemExit(f"{self.config}: {len(kept)} sentences are kept, fewer than {count}")
        return kept[:count]


def write_set(out: Path, clips: list[tuple[str, Language, dict]]) -> list[dict]:
    """Writes clips/<id>.wav and manifest.jsonl. Returns the manifest lines."""
    (out / "clips").mkdir(parents=True)
    lines = []
    for clip_id, language, row in clips:
        if not CLIP_ID.fullmatch(clip_id):
            raise SystemExit(f"{clip_id!r} is not a clip id")
        reference, lists, _, reason = reference_of(language.config, row, language.accepted)
        if reason:
            raise SystemExit(f"{clip_id}: sentence {row['sentence_id']} stays out: {reason}")
        name = f"{row['source_id']}.wav"
        try:
            samples = float_samples((language.audio / name).read_bytes())
        except (OSError, ValueError) as error:
            raise SystemExit(f"{language.config} {name}: {error}") from None
        if len(samples) != row["samples"]:
            raise SystemExit(f"{language.config} {name}: {len(samples)} samples, test.tsv says {row['samples']}")
        (out / "clips" / f"{clip_id}.wav").write_bytes(pcm16(samples))
        line = {
            "id": clip_id,
            "stratum": language.lang,
            "lang": language.lang,
            "source": f"fleurs-{language.config}-test",
            "source_id": row["source_id"],
            "sentence_id": row["sentence_id"],
            "duration": round(len(samples) / RATE, 3),
            "reference": reference,
        }
        if lists:
            line["accepted"] = lists
        lines.append(line)
    with (out / "manifest.jsonl").open("w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(json.dumps(line, ensure_ascii=False) + "\n")
    return lines


def compare(out: Path, stored: Path) -> tuple[list[str], int]:
    """Differences between the set in out and a stored manifest with the clips next to it,
    and the number of clips compared."""
    problems = []
    if (out / "manifest.jsonl").read_bytes() != stored.read_bytes():
        built_lines = [line for line in (out / "manifest.jsonl").read_text(encoding="utf-8").split("\n") if line]
        stored_lines = [line for line in stored.read_text(encoding="utf-8").split("\n") if line]
        if len(built_lines) != len(stored_lines):
            problems.append(f"manifest.jsonl: {len(built_lines)} lines built, {len(stored_lines)} stored")
        for number, (built, kept) in enumerate(zip(built_lines, stored_lines), 1):
            if built != kept:
                new, old = json.loads(built), json.loads(kept)
                fields = [key for key in dict.fromkeys([*old, *new]) if old.get(key) != new.get(key)]
                what = ", ".join(fields) + " differ" if fields else "the same values in other bytes"
                problems.append(f"manifest.jsonl line {number} ({old.get('id')}): {what}")
        if not problems:
            problems.append("manifest.jsonl differs outside its lines, such as in a last line break")
    stored_clips = stored.parent / "clips"
    compared = 0
    if stored_clips.is_dir():
        for path in sorted((out / "clips").iterdir()):
            other = stored_clips / path.name
            compared += 1
            if not other.is_file():
                problems.append(f"clips/{path.name} is not stored")
            elif other.read_bytes() != path.read_bytes():
                problems.append(f"clips/{path.name} differs from the stored clip")
    return problems, compared


def report(problems: list[str], compared: int, stored: Path) -> int:
    if problems:
        print(f"{len(problems)} differences from {stored}:")
        print("\n".join(problems[:50]))
        return 1
    clips = f" and {compared} clips are" if compared else " is"
    print(f"manifest.jsonl{clips} byte for byte the same as the stored set in {stored.parent}")
    return 0


def digits(text: str) -> bool:
    return bool(DIGIT.search(text))


def write_readme(out: Path, how: str, languages: list[Language], lines: list[dict]) -> None:
    """README.md of the set: how it was made, the attribution, the downloads and, for a
    language with the Latin letter rule, what the rule did."""
    text = [
        "# FLEURS test sets",
        "",
        "Made by Tools/speech-eval/build_fleurs.py of the Orra repository:",
        "",
        f"    build_fleurs.py {how}",
        "",
        "| Language | FLEURS config | Clips | With digits | Audio | Recordings in the split | Sentences | Sentences kept |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for language in languages:
        own = [line for line in lines if line["lang"] == language.lang]
        text.append(
            f"| {language.lang} | {language.config} | {len(own)} | {sum(digits(line['reference']) for line in own)} "
            f"| {sum(line['duration'] for line in own):.1f} s | {len(language.rows)} | {len(language.candidates)} "
            f"| {len(language.candidates) - len(language.left_out)} |"
        )
    text += [
        "",
        "## Source and license",
        "",
        "The recordings and transcriptions come from FLEURS, Google's set of read sentences "
        "(Conneau et al., 2022, \"FLEURS: Few-shot Learning Evaluation of Universal Representations "
        "of Speech\"), https://huggingface.co/datasets/google/fleurs, licensed under CC BY 4.0, "
        "https://creativecommons.org/licenses/by/4.0/. They are provided as is, without warranties.",
        "",
        "Changes: a subset of each test split, one recording per sentence, converted from 32 bit "
        "float to 16 kHz mono 16 bit WAVE and named by its place in the set. The references are "
        "the raw transcriptions with the quoting of the TSV undone, and Korean references follow "
        "the rule below.",
        "",
        "Downloads, with the SHA-256 that Tools/speech-eval/fleurs.sha256 pins:",
        "",
    ]
    for language in languages:
        for name, (url, _) in language.files.items():
            text.append(f"    {language.hashes[name]}  {name}  {url}")
    for language in languages:
        if language.config not in LATIN_RULE:
            continue
        own = [(line, language.by_source[line["source_id"]]) for line in lines if line["lang"] == language.lang]
        changed = [(line, reference_of(language.config, row, language.accepted)[2]) for line, row in own]
        changed = [(line, glosses) for line, glosses in changed if glosses]
        listed = [line for line, _ in own if "accepted" in line]
        text += [
            "",
            f"## Latin letters in {language.config}",
            "",
            "A part in parentheses that holds Latin letters and no Hangul and no digits is a gloss "
            "that a reader does not read, such as 비슈케크(Bishkek). It leaves the reference with "
            "the space before it. A sentence with a part in parentheses that holds Latin letters "
            "with Hangul or digits stays out, since the reader may read part of it. Latin letters "
            "outside parentheses stay only where Tools/speech-eval/fleurs-accepted.json gives "
            "accepted spellings for every one of them, the form of the reference first, and the "
            "clip's line in manifest.jsonl carries them as \"accepted\". Otherwise the sentence "
            "stays out. The Hangul spellings wait for a native reader's check.",
            "",
            f"Glosses left out of {len(changed)} references:",
            "",
        ]
        text += [f"- {line['id']}, sentence {line['sentence_id']}: " + ", ".join(f"({gloss})" for gloss in glosses) for line, glosses in changed]
        text += ["", f"Accepted spellings on {len(listed)} clips:", ""]
        text += [
            f"- {line['id']}, sentence {line['sentence_id']}: " + " and ".join(f"{forms[0]} as {' or '.join(forms[1:])}" for forms in line["accepted"])
            for line in listed
        ]
        text += ["", f"Sentences left out ({len(language.left_out)} of {len(language.candidates)}):", ""]
        text += [f"- {sentence_id}: {reason}" for sentence_id, reason in sorted(language.left_out.items())]
    (out / "README.md").write_text("\n".join(text) + "\n", encoding="utf-8")


def summary(languages: list[Language], lines: list[dict]) -> None:
    for language in languages:
        own = [line for line in lines if line["lang"] == language.lang]
        print(
            f"{language.config}: {len(language.rows)} recordings of {len(language.candidates)} sentences, "
            f"{len(language.left_out)} sentences left out, {len(own)} clips, {sum(digits(line['reference']) for line in own)} with digits, "
            f"{sum('accepted' in line for line in own)} with accepted spellings, {sum(line['duration'] for line in own):.1f} s"
        )


def build(out: Path, configs: list[str], count: int, seed: int, folders: list[Path], hashes=None, accepted=None) -> list[dict]:
    hashes = read_hashes() if hashes is None else hashes
    accepted = load_accepted() if accepted is None else accepted
    check_out(out)
    languages = [Language(config, out, folders, hashes, accepted) for config in dict.fromkeys(configs)]
    clips = [(f"{index:04d}_{language.lang}", language, row) for language in languages for index, row in enumerate(language.draw(count, seed))]
    lines = write_set(out, clips)
    write_readme(out, f"build --count {count} --seed {seed} {out.name} {' '.join(language.config for language in languages)}", languages, lines)
    summary(languages, lines)
    return lines


def rebuild(stored: Path, out: Path, folders: list[Path], hashes=None, accepted=None) -> list[dict]:
    hashes = read_hashes() if hashes is None else hashes
    accepted = load_accepted() if accepted is None else accepted
    check_out(out)
    records = [json.loads(line) for line in stored.read_text(encoding="utf-8").split("\n") if line]
    if len({record["id"] for record in records}) != len(records):
        raise SystemExit(f"{stored} holds a clip id twice")
    languages = {config: Language(config, out, folders, hashes, accepted) for config in dict.fromkeys(config_of(record["source"]) for record in records)}
    clips = []
    for record in records:
        language = languages[config_of(record["source"])]
        row = language.by_source.get(record["source_id"])
        if row is None:
            raise SystemExit(f"{record['id']}: {record['source_id']} is not in {language.config}'s test.tsv")
        clips.append((record["id"], language, row))
    lines = write_set(out, clips)
    write_readme(out, f"rebuild {stored} {out.name}", list(languages.values()), lines)
    summary(list(languages.values()), lines)
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("build", help="draw a new set")
    make.add_argument("--count", type=int, required=True, help="sentences per language")
    make.add_argument("--seed", type=int, required=True)
    make.add_argument("--compare", type=Path, help="a stored manifest to compare the new set with")
    make.add_argument("out", type=Path)
    make.add_argument("configs", nargs="+", help=f"FLEURS configs: {', '.join(LANGUAGES)}")
    again = commands.add_parser("rebuild", help="make a stored set again from its manifest")
    again.add_argument("manifest", type=Path)
    again.add_argument("out", type=Path)
    for command in (make, again):
        command.add_argument("--downloads", type=Path, action="append", default=[], help="a folder that holds downloads already, only read")
    arguments = parser.parse_args()
    out = arguments.out.expanduser()
    folders = [folder.expanduser() for folder in arguments.downloads]
    if arguments.command == "build":
        lines = build(out, arguments.configs, arguments.count, arguments.seed, folders)
        stored = arguments.compare.expanduser() if arguments.compare else None
    else:
        stored = arguments.manifest.expanduser()
        lines = rebuild(stored, out, folders)
    print(f"wrote {len(lines)} clips, manifest.jsonl and README.md to {out}")
    return report(*compare(out, stored), stored) if stored else 0


if __name__ == "__main__":
    sys.exit(main())
