#!/usr/bin/env python3
"""Builds sets/contextasr_zh and sets/contextasr_en from ContextASR-Bench.

ContextASR-Bench (MIT, huggingface.co/datasets/MrSupW/ContextASR-Bench) pairs each clip
with the named entities it contains, so it can test a vocabulary given to the model as
context. The audio is synthesized speech, so it tests the mechanism, not a person's voice.

Expects in ORRA_EVAL_DIR/contextasr: the Speech label files and one or more audio
archives, complete or cut off by a broken download, for example ContextASR-Speech_Mandarin.jsonl and
ContextASR-Speech_Mandarin_1.tar. Takes COUNT clips, evenly spaced by id, whose audio is in an
archive and that are shorter than 60 s, converts them to 16 kHz mono WAV with afconvert,
and writes refs.tsv (file, reference) and terms.tsv (file, terms joined by |).
"""
import json
import os
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(os.environ.get("ORRA_EVAL_DIR", Path.home() / "projects/orra-project/eval"))
COUNT = int(os.environ.get("COUNT", "100"))
SOURCE = ROOT / "contextasr"


def build(language: str, short: str) -> None:
    labels = SOURCE / f"ContextASR-Speech_{language}.jsonl"
    archives = sorted(SOURCE.glob(f"ContextASR-Speech_{language}_*.tar"))
    if not labels.exists() or not archives:
        print(f"skipping {language}: labels or archive missing")
        return
    members = {}
    for archive in archives:
        # A download that broke off leaves a partial archive. Its complete files are used.
        size = archive.stat().st_size
        with tarfile.open(archive) as tar:
            try:
                for member in tar:
                    if member.isfile() and member.name.endswith(".wav") and member.offset_data + member.size <= size:
                        members[Path(member.name).stem] = (archive, member.offset_data, member.size)
            except (tarfile.ReadError, EOFError):
                pass
    rows = []
    for line in labels.read_text(encoding="utf-8").splitlines():
        item = json.loads(line)
        stem = Path(item["audio"]).stem
        if stem in members and item["duration"] < 60 and item["entity_list"]:
            rows.append((stem, item))
    rows.sort(key=lambda row: row[0])
    # Evenly spaced, so the ids, which start with the source and domain, are all covered.
    step = max(1, len(rows) // COUNT)
    rows = rows[::step][:COUNT]
    target = ROOT / "sets" / f"contextasr_{short}"
    target.mkdir(parents=True, exist_ok=True)
    refs, terms = [], []
    for stem, item in rows:
        archive, offset, length = members[stem]
        wav = target / f"{stem}.wav"
        if not wav.exists():
            raw = target / f"{stem}.source.wav"
            with open(archive, "rb") as source, open(raw, "wb") as out:
                source.seek(offset)
                out.write(source.read(length))
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(raw), str(wav)], check=True)
            raw.unlink()
        refs.append(f"{stem}.wav\t{item['text'].replace(chr(9), ' ').replace(chr(10), ' ')}")
        terms.append(f"{stem}.wav\t{'|'.join(term.replace('|', ' ') for term in item['entity_list'])}")
    (target / "refs.tsv").write_text("\n".join(refs) + "\n", encoding="utf-8")
    (target / "terms.tsv").write_text("\n".join(terms) + "\n", encoding="utf-8")
    print(f"{target.name}: {len(rows)} clips")


if __name__ == "__main__":
    for language, short in (("Mandarin", "zh"), ("English", "en")):
        if len(sys.argv) == 1 or short in sys.argv[1:]:
            build(language, short)
