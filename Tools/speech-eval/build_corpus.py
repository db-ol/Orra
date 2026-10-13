# Builds the 392 clip speech corpus that Voxt's native runtime is checked on, so Orra can be
# scored on exactly the same audio.
#
# The selection is ported from sglang_omni_mlx/native/ci/corpus/build_corpus.py and the
# download list from sglang_omni_mlx/native/ci/provision.py in sglang-omni
# (https://github.com/sgl-project/sglang-omni, commit aac4b83), Copyright the sglang-omni
# authors, licensed under the Apache License 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). The seed, the order of the random draws,
# the strata, the 0.4 s gap between joined clips and the synthetic clips are theirs, since
# any change gives other clips. The code is written again for Orra. Changes: it downloads
# and checks the sources itself, extracts the archives with tarfile's data filter, and
# checks the result against the manifest and the clip hashes in this folder.
#
# Usage, with the Python packages in requirements.txt:
#
#     python3 -I Tools/speech-eval/build_corpus.py ~/projects/orra-project/bench/speech-corpus
#
# The folder ends up with raw/ (the four downloads, about 1 GB), extracted/ and clips/ (the
# 392 WAV files, 16 kHz mono 16 bit, about 140 MB) and manifest.jsonl. Nothing is written
# inside the repository.

from __future__ import annotations

import csv
import hashlib
import io
import json
import random
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

HERE = Path(__file__).resolve().parent
SEED = 20261004
RATE = 16000
GAP_SECONDS = 0.4

SOURCES = {
    "librispeech-test-clean.tar.gz": "https://www.openslr.org/resources/12/test-clean.tar.gz",
    "fleurs-cmn-test.tar.gz": "https://huggingface.co/datasets/google/fleurs/resolve/main/data/cmn_hans_cn/audio/test.tar.gz",
    "fleurs-cmn-test.tsv": "https://huggingface.co/datasets/google/fleurs/resolve/main/data/cmn_hans_cn/test.tsv",
    "ascend-test.parquet": "https://huggingface.co/datasets/CAiRE/ASCEND/resolve/main/main/test-00000-of-00001.parquet",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_hashes(path: Path) -> dict[str, str]:
    hashes = {}
    for line in path.read_text().splitlines():
        if line.strip():
            digest, name = line.split(maxsplit=1)
            hashes[name] = digest
    return hashes


def fetch_sources(raw: Path) -> None:
    """Downloads each source unless a copy with the pinned hash is already there."""
    raw.mkdir(parents=True, exist_ok=True)
    pinned = read_hashes(HERE / "raw.sha256")
    for name, url in SOURCES.items():
        target = raw / name
        if target.exists() and sha256(target) == pinned[name]:
            print(f"have {name}")
            continue
        print(f"downloading {url}")
        partial = target.with_suffix(target.suffix + ".partial")
        urllib.request.urlretrieve(url, partial)
        actual = sha256(partial)
        if actual != pinned[name]:
            raise SystemExit(f"{name}: SHA-256 {actual} is not the pinned {pinned[name]}")
        partial.rename(target)


def extract(raw: Path, extracted: Path) -> None:
    marker = extracted / ".done"
    if marker.exists():
        return
    extracted.mkdir(parents=True, exist_ok=True)
    with tarfile.open(raw / "librispeech-test-clean.tar.gz") as archive:
        archive.extractall(extracted, filter="data")
    # The FLEURS archive holds test/<file>.wav.
    with tarfile.open(raw / "fleurs-cmn-test.tar.gz") as archive:
        archive.extractall(extracted, filter="data")
    marker.write_text("")


def to_16k_mono(audio: np.ndarray, rate: int) -> np.ndarray:
    """Every source is 16 kHz already. The linear fallback matches the original builder."""
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if rate == RATE:
        return audio.astype(np.float32)
    seconds = len(audio) / rate
    old = np.linspace(0, seconds, num=len(audio), endpoint=False)
    new = np.linspace(0, seconds, num=int(round(seconds * RATE)), endpoint=False)
    return np.interp(new, old, audio).astype(np.float32)


def read_audio(source) -> np.ndarray:
    audio, rate = sf.read(io.BytesIO(source) if isinstance(source, (bytes, bytearray)) else str(source), dtype="float32")
    return to_16k_mono(audio, rate)


def librispeech_items(extracted: Path) -> list[dict]:
    items = []
    for transcript in sorted(extracted.glob("LibriSpeech/test-clean/*/*/*.trans.txt")):
        for line in transcript.read_text().splitlines():
            uid, text = line.split(" ", 1)
            flac = transcript.parent / f"{uid}.flac"
            info = sf.info(str(flac))
            items.append({
                "source": "librispeech-test-clean",
                "source_id": uid,
                "chapter": "-".join(uid.split("-")[:2]),
                "lang": "en",
                "reference": text,
                "duration": info.frames / info.samplerate,
                "path": flac,
            })
    return items


def fleurs_items(extracted: Path, tsv: Path) -> list[dict]:
    """One recording per sentence: the first row of each sentence id in the TSV."""
    items = []
    sentences = set()
    with tsv.open() as handle:
        for row in csv.reader(handle, delimiter="\t", quoting=csv.QUOTE_NONE):
            if row[0] in sentences:
                continue
            sentences.add(row[0])
            wav = extracted / "test" / row[1]
            info = sf.info(str(wav))
            items.append({
                "source": "fleurs-cmn_hans_cn-test",
                "source_id": row[1].removesuffix(".wav"),
                "lang": "zh",
                "reference": row[2],
                "duration": info.frames / info.samplerate,
                "path": wav,
            })
    return sorted(items, key=lambda item: item["source_id"])


def ascend_items(parquet: Path) -> list[dict]:
    return [
        {
            "source": "ascend-test",
            "source_id": row["id"],
            "lang": row["language"],
            "reference": row["transcription"],
            "duration": float(row["duration"]),
            "bytes": row["audio"]["bytes"],
        }
        for row in pq.read_table(parquet).to_pylist()
    ]


def between(items: list[dict], low: float, high: float) -> list[dict]:
    return [item for item in items if low <= item["duration"] <= high]


def key(item: dict) -> tuple[str, str]:
    return item["source"], item["source_id"]


def draw(rng: random.Random, items: list[dict], count: int, used: set) -> list[dict]:
    pool = [item for item in items if key(item) not in used]
    chosen = rng.sample(pool, min(count, len(pool)))
    used.update(key(item) for item in chosen)
    return chosen


def joined(rng: random.Random, items: list[dict], group, count: int, low: float, high: float, used: set, separator: str) -> list[dict]:
    """Long clips: consecutive unused utterances of one group, joined with a 0.4 s gap,
    until the total reaches `low`. A group whose total ends above `high` is skipped."""
    groups: dict[str, list[dict]] = {}
    for item in items:
        groups.setdefault(group(item), []).append(item)
    names = sorted(groups)
    rng.shuffle(names)
    chosen = []
    for name in names:
        parts, total = [], 0.0
        for item in sorted(groups[name], key=lambda it: it["source_id"]):
            if key(item) in used:
                continue
            parts.append(item)
            total += item["duration"] + GAP_SECONDS
            if total >= low:
                break
        if low <= total <= high:
            used.update(key(item) for item in parts)
            chosen.append(parts)
        if len(chosen) == count:
            break
    return [
        {
            "source": parts[0]["source"],
            "source_id": "+".join(part["source_id"] for part in parts),
            "lang": parts[0]["lang"],
            "reference": separator.join(part["reference"] for part in parts),
            "parts": parts,
        }
        for parts in chosen
    ]


def select(extracted: Path, raw: Path) -> tuple[list[tuple[str, dict]], random.Random]:
    """The order of the draws matters: each one advances the one random generator."""
    rng = random.Random(SEED)
    used: set = set()
    english = librispeech_items(extracted)
    chinese = fleurs_items(extracted, raw / "fleurs-cmn-test.tsv")
    ascend = ascend_items(raw / "ascend-test.parquet")
    with_digits = [item for item in chinese if re.search(r"[0-9０-９]", item["reference"])]

    selection = [("en_short", item) for item in draw(rng, between(english, 2, 5), 64, used)]
    selection += [("en_mid", item) for item in draw(rng, between(english, 10, 20), 64, used)]
    selection += [("zh_numbers", item) for item in draw(rng, with_digits, 24, used)]
    selection += [("zh_short", item) for item in draw(rng, between(chinese, 2, 7), 40, used)]
    selection += [("zh_mid", item) for item in draw(rng, between(chinese, 10, 20), 64, used)]
    ascend_chinese = [item for item in between(ascend, 2, 7) if item["lang"] == "zh"]
    selection += [("zh_short", item) for item in draw(rng, ascend_chinese, 30, used)]
    ascend_mixed = [item for item in between(ascend, 2, 20) if item["lang"] == "mixed"]
    selection += [("mixed", item) for item in draw(rng, ascend_mixed, 64, used)]
    selection += [("en_long", item) for item in joined(rng, english, lambda it: it["chapter"], 16, 60, 120, used, " ")]
    selection += [("zh_long", item) for item in joined(rng, chinese, lambda it: str(int(it["source_id"]) % 24), 16, 60, 120, used, "")]
    return selection, rng


def write(path: Path, audio: np.ndarray) -> None:
    sf.write(path, audio, RATE, subtype="PCM_16")


def build(work: Path) -> None:
    raw, extracted, clips = work / "raw", work / "extracted", work / "clips"
    fetch_sources(raw)
    extract(raw, extracted)
    clips.mkdir(parents=True, exist_ok=True)
    selection, rng = select(extracted, raw)

    records = []
    gap = np.zeros(int(GAP_SECONDS * RATE), dtype=np.float32)
    for index, (stratum, item) in enumerate(selection):
        if "parts" in item:
            pieces = []
            for part in item["parts"]:
                pieces += [read_audio(part["path"]), gap]
            audio = np.concatenate(pieces[:-1])
        else:
            audio = read_audio(item.get("bytes") or item["path"])
        clip_id = f"{index:04d}_{stratum}"
        write(clips / f"{clip_id}.wav", audio)
        records.append({
            "id": clip_id,
            "stratum": stratum,
            "lang": item["lang"],
            "source": item["source"],
            "source_id": item["source_id"],
            "duration": round(len(audio) / RATE, 3),
            "reference": item["reference"],
        })

    # Synthetic clips: 5 s of silence and 5 s of quiet white noise, four each, then eight
    # mid length clips again with white noise at 10 dB SNR. One NumPy generator with the
    # same seed draws all the noise, in this order.
    noise_rng = np.random.default_rng(SEED)
    for index in range(4):
        clip_id = f"{len(records):04d}_silence"
        write(clips / f"{clip_id}.wav", np.zeros(5 * RATE, np.float32))
        records.append({"id": clip_id, "stratum": "silence", "lang": "none", "source": "synthetic", "source_id": f"silence-{index}", "duration": 5.0, "reference": ""})
    for index in range(4):
        clip_id = f"{len(records):04d}_noise"
        write(clips / f"{clip_id}.wav", noise_rng.normal(0, 0.01, 5 * RATE).astype(np.float32))
        records.append({"id": clip_id, "stratum": "noise", "lang": "none", "source": "synthetic", "source_id": f"noise-{index}", "duration": 5.0, "reference": ""})
    middle = [record for record in records if record["stratum"] in ("en_mid", "zh_mid")]
    for base in rng.sample(middle, 8):
        # Read back the written 16 bit clip, as the original does.
        audio, _ = sf.read(clips / f"{base['id']}.wav", dtype="float32")
        power = float(np.mean(audio**2))
        noisy = np.clip(audio + noise_rng.normal(0, np.sqrt(power / 10), len(audio)).astype(np.float32), -1, 1)
        clip_id = f"{len(records):04d}_snr10_{base['lang']}"
        write(clips / f"{clip_id}.wav", noisy)
        records.append({**base, "id": clip_id, "stratum": f"snr10_{base['lang']}"})

    manifest = work / "manifest.jsonl"
    with manifest.open("w") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    verify(work)


def verify(work: Path) -> None:
    """Compares the built manifest and every clip with the copies pinned in this folder."""
    problems = []
    if (work / "manifest.jsonl").read_bytes() != (HERE / "manifest.jsonl").read_bytes():
        problems.append("manifest.jsonl differs from Tools/speech-eval/manifest.jsonl")
    pinned = read_hashes(HERE / "clips.sha256")
    for name, digest in pinned.items():
        path = work / name
        if not path.exists():
            problems.append(f"{name} is missing")
        elif sha256(path) != digest:
            problems.append(f"{name} differs from its pinned hash")
    total = sum(json.loads(line)["duration"] for line in (work / "manifest.jsonl").read_text().splitlines())
    print(f"{len(pinned)} files checked, {total:.1f} s of audio")
    if problems:
        print("\n".join(problems[:20]))
        raise SystemExit(f"{len(problems)} problems")
    print("the corpus matches the pinned hashes")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        verify(Path(sys.argv[2]).expanduser())
    elif len(sys.argv) == 2:
        build(Path(sys.argv[1]).expanduser())
    else:
        raise SystemExit("usage: build_corpus.py <work folder> | --verify <work folder>")
