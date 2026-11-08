#!/usr/bin/env python3
"""Makes the synthetic test sets of the release gate with the macOS voices.

Each folder next to this script is one set, and so is each folder in pairs/: sentences.jsonl
with one sentence per line ({"id", "language", "say", "reference", "expect_terms",
"forbid_terms"}, optional "voice", "context" and "accepted") and an optional set.json with
the set's pair and its context variants. A variant without a context, or a set without
variants, uses the context of each sentence. Every sentence is spoken once with `say`, then
afconvert writes it as 16 kHz mono 16 bit WAVE. A "say" that is a list of [voice, text]
parts is spoken part by part and joined into one clip. Each variant adds one clip and one
manifest line per sentence, with the variant's suffix after the sentence id and its context.

A term of expect_terms is one spelling, or a list of spellings: the one in the reference
first, then the others that count as right, such as ["Slack", "슬랙"]. "accepted" lists
other spellings the same way for words that are not expected terms. Every plain term and
the first spelling of every list must be in the reference, matched as the gate matches
terms, and no forbidden term may be.

The output folder of a set holds clips/<id>.wav and manifest.jsonl, one line per clip:
{"id", "language", "reference", "context", "expect_terms", "forbid_terms"}, and "accepted"
with every list of spellings of the sentence when it has one. set.json and README.md go
with them when the set has them. A set in pairs/ goes to pairs/<name> in the output folder.
The clips stay outside the repository.

Usage (macOS only, standard library only):

    python3 Tools/release-gate/sets/make_sets.py [--out FOLDER] [--check] [SET ...]

A set is named by its folder, such as gate-core or pairs/ja-core, and pairs names every set
in pairs/. The default output folder is $ORRA_BENCH/gate-sets, the folder the gate reads
(ORRA_BENCH is ~/projects/orra-project/bench unless set). With no set named, every set is
made. --check checks the named sets and writes nothing, on any system.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = Path(os.environ.get("ORRA_BENCH", Path.home() / "projects/orra-project/bench")) / "gate-sets"
ONE_VARIANT = [{"suffix": ""}]
VOICES = {"en": "Samantha", "zh": "Tingting", "mixed": "Tingting", "ja": "Kyoko", "es": "Paulina", "ko": "Yuna"}
# The dictation pairs a set.json may name. A set without one is for the Chinese pair.
PAIRS = ("zh", "ja", "es", "ko")
# Files of a set that go with its clips.
COPIED = ("set.json", "README.md")


class SetError(Exception):
    """A set that cannot be made, with the reason."""


def label(folder: Path) -> str:
    return folder.relative_to(HERE).as_posix() if HERE in folder.parents else folder.name


def holds_term(text: str, term: str) -> bool:
    """Whether the text holds the term as gate.py's term_found matches it: after NFKC, with
    any white space between its characters, and a term with Latin letters with its case and
    not inside a longer word, so trust does not hold Rust."""
    characters = [character for character in unicodedata.normalize("NFKC", term) if not character.isspace()]
    if not characters:
        return False
    pattern = r"\s*".join(re.escape(character) for character in characters)
    if any(character.isascii() and character.isalpha() for character in characters):
        pattern = rf"(?<![A-Za-z]){pattern}(?![A-Za-z])"
    return re.search(pattern, unicodedata.normalize("NFKC", text)) is not None


def check_spellings(where: str, spellings: object, reference: str) -> None:
    """A list of spellings: two or more different ones, the first in the reference."""
    if (
        not isinstance(spellings, list)
        or len(spellings) < 2
        or not all(isinstance(spelling, str) and spelling.strip() for spelling in spellings)
        or len(set(spellings)) != len(spellings)
    ):
        raise SetError(f"{where}: a list of spellings needs two or more different spellings, not {spellings!r}")
    if not holds_term(reference, spellings[0]):
        raise SetError(f"{where}: {spellings[0]!r}, the first spelling of its list, is not in the reference")


def parts(row: dict, where: str) -> list[tuple[str, str]]:
    """The voice and the text of each part of the sentence, one part unless "say" is a list."""
    say = row["say"]
    if isinstance(say, str):
        return [(row.get("voice", VOICES[row["language"]]), say)]
    if not isinstance(say, list) or not say or not all(
        isinstance(part, list) and len(part) == 2 and all(isinstance(value, str) and value.strip() for value in part) for part in say
    ):
        raise SetError(f"{where}: say must be a text or a list of [voice, text] parts")
    return [(voice, text) for voice, text in say]


def load_set(folder: Path) -> tuple[list[dict], list[dict], dict]:
    """The sentences, the variants and the settings of a set, checked."""
    name = label(folder)
    sentences = [json.loads(line) for line in (folder / "sentences.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    settings_file = folder / "set.json"
    settings = json.loads(settings_file.read_text(encoding="utf-8")) if settings_file.exists() else {}
    variants = settings.get("variants", ONE_VARIANT)
    if not variants or len({variant["suffix"] for variant in variants}) != len(variants):
        raise SetError(f"{name}: the variants need different suffixes")
    if "pair" in settings and settings["pair"] not in PAIRS:
        raise SetError(f"{name}: pair must be one of {', '.join(PAIRS)}")
    ids = [row["id"] for row in sentences]
    if not ids or len(ids) != len(set(ids)):
        raise SetError(f"{name}: no sentences, or duplicate sentence ids")
    for row in sentences:
        where = f"{name}/{row['id']}"
        if row["language"] not in VOICES:
            raise SetError(f"{where}: language must be one of {sorted(VOICES)}")
        parts(row, where)
        for term in row["expect_terms"]:
            if isinstance(term, str):
                if not holds_term(row["reference"], term):
                    raise SetError(f"{where}: expected term {term!r} is not in the reference")
            else:
                check_spellings(where, term, row["reference"])
        for term in row["forbid_terms"]:
            if not isinstance(term, str) or holds_term(row["reference"], term):
                raise SetError(f"{where}: forbidden term {term!r} is in the reference or not a text")
        for spellings in row.get("accepted", []):
            check_spellings(where, spellings, row["reference"])
    return sentences, variants, settings


def accepted(row: dict) -> list[list[str]]:
    """Every list of spellings of a sentence: those of its expected terms, then its own."""
    lists: list[list[str]] = []
    for spellings in [term for term in row["expect_terms"] if not isinstance(term, str)] + row.get("accepted", []):
        if spellings not in lists:
            lists.append(spellings)
    return lists


def manifest_lines(sentences: list[dict], variants: list[dict]) -> list[dict]:
    lines = []
    for row in sentences:
        spellings = accepted(row)
        for variant in variants:
            line = {
                "id": row["id"] + variant["suffix"],
                "language": row["language"],
                "reference": row["reference"],
                "context": variant.get("context", row.get("context", [])),
                "expect_terms": row["expect_terms"],
                "forbid_terms": row["forbid_terms"],
            }
            if spellings:
                line["accepted"] = spellings
            lines.append(line)
    return lines


def speak(spoken: list[tuple[str, str]], target: Path, scratch: Path) -> None:
    """Speaks each part and writes them one after another into one clip."""
    if len(spoken) == 1:
        voice, text = spoken[0]
        aiff = scratch / "speech.aiff"
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(target)], check=True)
        return
    frames = []
    for index, part in enumerate(spoken):
        piece = scratch / f"part-{index}.wav"
        speak([part], piece, scratch)
        with wave.open(str(piece), "rb") as reader:
            if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, 16000):
                raise SetError(f"{piece}: not 16 kHz mono 16 bit")
            frames.append(reader.readframes(reader.getnframes()))
    with wave.open(str(target), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(16000)
        writer.writeframes(b"".join(frames))


def make(name: str, sentences: list[dict], variants: list[dict], out: Path) -> int:
    folder = HERE / name
    target = out / name
    if target.exists():
        shutil.rmtree(target)
    (target / "clips").mkdir(parents=True)
    with tempfile.TemporaryDirectory() as scratch:
        for row in sentences:
            spoken = Path(scratch) / f"{row['id']}.wav"
            speak(parts(row, f"{name}/{row['id']}"), spoken, Path(scratch))
            for variant in variants:
                shutil.copyfile(spoken, target / "clips" / f"{row['id']}{variant['suffix']}.wav")
    lines = manifest_lines(sentences, variants)
    with open(target / "manifest.jsonl", "w", encoding="utf-8") as manifest:
        for line in lines:
            manifest.write(json.dumps(line, ensure_ascii=False) + "\n")
    for copied in COPIED:
        if (folder / copied).exists():
            shutil.copyfile(folder / copied, target / copied)
    return len(lines)


def set_names(names: list[str]) -> list[str]:
    """The sets that the names stand for, each by its folder relative to this one. A folder
    of sets, such as pairs, stands for every set in it, and no name for every set."""
    found = []
    for name in names or [""]:
        folder = (HERE / name).resolve()
        if folder != HERE and HERE not in folder.parents:
            raise SetError(f"{name}: not a folder of {HERE}")
        if (folder / "sentences.jsonl").exists():
            found.append(label(folder))
            continue
        inside = sorted(label(path.parent) for path in folder.glob("**/sentences.jsonl"))
        if not inside:
            raise SetError(f"{name}: no set there")
        found += inside
    return list(dict.fromkeys(found))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="check the sets and write nothing")
    parser.add_argument("sets", nargs="*")
    arguments = parser.parse_args()
    try:
        # Every set is checked before any is made, so a mistake in one makes none.
        loaded = {name: load_set(HERE / name) for name in set_names(arguments.sets)}
        for name, (sentences, variants, _) in loaded.items():
            if arguments.check:
                print(f"{name}: {len(manifest_lines(sentences, variants))} clips, checked")
            else:
                count = make(name, sentences, variants, arguments.out)
                print(f"{name}: {count} clips in {arguments.out / name}")
    except SetError as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
