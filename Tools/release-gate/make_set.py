#!/usr/bin/env python3
"""Makes the clips of a release gate test set with macOS say. Standard library only.

    python3 make_set.py SET [SET ...] [--out ~/projects/orra-project/bench/gate-sets]
    python3 make_set.py --all

Reads sets/SET/sentences.jsonl next to this script, one JSON object per clip with id,
language ("zh", "en" or "mixed"), voice (a say voice), say (the text spoken), reference
(the text Orra should paste with cleanup off, the say text when left out), context,
expect_terms and forbid_terms. Writes OUT/SET/clips/<id>.wav, 16 kHz mono 16 bit, and
OUT/SET/manifest.jsonl in the format of docs/release-gate.md. The audio is synthetic and
stays outside the repository.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = Path.home() / "projects/orra-project/bench/gate-sets"
FIELDS = ("id", "language", "reference", "context", "expect_terms", "forbid_terms")


def make(name: str, out: Path) -> int:
    rows = [json.loads(line) for line in (HERE / "sets" / name / "sentences.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    folder = out / name
    (folder / "clips").mkdir(parents=True, exist_ok=True)
    manifest = []
    for row in rows:
        if row["language"] not in ("zh", "en", "mixed"):
            raise SystemExit(f"{name}/{row['id']}: language must be zh, en or mixed")
        clip = folder / "clips" / f"{row['id']}.wav"
        subprocess.run(["say", "-v", row["voice"], "-o", str(clip), "--data-format=LEI16@16000", row["say"]], check=True)
        with wave.open(str(clip)) as audio:
            if audio.getframerate() != 16000 or audio.getnchannels() != 1:
                raise SystemExit(f"{clip}: not 16 kHz mono")
        entry = {**row, "reference": row.get("reference") or row["say"]}
        manifest.append({key: entry.get(key, []) for key in FIELDS})
    (folder / "manifest.jsonl").write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in manifest), encoding="utf-8")
    return len(manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sets", nargs="*")
    parser.add_argument("--all", action="store_true", help="every set under sets/")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    arguments = parser.parse_args()
    names = sorted(path.name for path in (HERE / "sets").iterdir() if (path / "sentences.jsonl").exists()) if arguments.all else arguments.sets
    if not names:
        parser.error("name a set or pass --all")
    for name in names:
        print(f"{name}: {make(name, arguments.out.expanduser())} clips in {arguments.out / name}")


if __name__ == "__main__":
    main()
