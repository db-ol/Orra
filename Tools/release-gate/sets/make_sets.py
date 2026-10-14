#!/usr/bin/env python3
"""Makes the synthetic test sets of the release gate with the macOS voices.

Each folder next to this script is one set: sentences.jsonl with one sentence per line
({"id", "language", "say", "reference", "expect_terms", "forbid_terms"}, optional "voice")
and set.json with its context variants. Every sentence is spoken once with `say`, then
afconvert writes it as 16 kHz mono 16 bit WAVE. Each variant adds one clip and one manifest
line per sentence, with the variant's suffix after the sentence id and its context.

The output folder of a set holds clips/<id>.wav and manifest.jsonl, one line per clip:
{"id", "language", "reference", "context", "expect_terms", "forbid_terms"}. The clips stay
outside the repository.

Usage (macOS only, standard library only):

    python3 Tools/release-gate/sets/make_sets.py [--out FOLDER] [SET ...]

The default output folder is ../bench/gate-sets next to the repository, as in the
maintainer's checkout. With no set named, every set is made.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = HERE.parents[3] / "bench" / "gate-sets"
VOICES = {"en": "Samantha", "zh": "Tingting", "mixed": "Tingting"}


def load_set(folder: Path) -> tuple[list[dict], list[dict]]:
    sentences = [json.loads(line) for line in (folder / "sentences.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    variants = json.loads((folder / "set.json").read_text(encoding="utf-8"))["variants"]
    ids = [row["id"] for row in sentences]
    if len(ids) != len(set(ids)):
        sys.exit(f"{folder.name}: duplicate sentence ids")
    for row in sentences:
        if row["language"] not in VOICES:
            sys.exit(f"{folder.name}/{row['id']}: language must be one of {sorted(VOICES)}")
        for term in row["expect_terms"]:
            if term not in row["reference"]:
                sys.exit(f"{folder.name}/{row['id']}: expected term {term!r} is not in the reference")
    return sentences, variants


def speak(text: str, voice: str, target: Path, scratch: Path) -> None:
    aiff = scratch / "speech.aiff"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(target)], check=True)


def make(folder: Path, out: Path) -> int:
    sentences, variants = load_set(folder)
    target = out / folder.name
    if target.exists():
        shutil.rmtree(target)
    (target / "clips").mkdir(parents=True)
    lines = []
    with tempfile.TemporaryDirectory() as scratch:
        for row in sentences:
            spoken = Path(scratch) / f"{row['id']}.wav"
            speak(row["say"], row.get("voice", VOICES[row["language"]]), spoken, Path(scratch))
            for variant in variants:
                clip_id = row["id"] + variant["suffix"]
                shutil.copyfile(spoken, target / "clips" / f"{clip_id}.wav")
                lines.append({
                    "id": clip_id,
                    "language": row["language"],
                    "reference": row["reference"],
                    "context": variant["context"],
                    "expect_terms": row["expect_terms"],
                    "forbid_terms": row["forbid_terms"],
                })
    with open(target / "manifest.jsonl", "w", encoding="utf-8") as manifest:
        for line in lines:
            manifest.write(json.dumps(line, ensure_ascii=False) + "\n")
    return len(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("sets", nargs="*")
    arguments = parser.parse_args()
    names = arguments.sets or sorted(p.name for p in HERE.iterdir() if (p / "sentences.jsonl").exists())
    for name in names:
        count = make(HERE / name, arguments.out)
        print(f"{name}: {count} clips in {arguments.out / name}")


if __name__ == "__main__":
    main()
