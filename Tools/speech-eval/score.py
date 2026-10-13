# Scores transcripts of the speech corpus the way Voxt scores its golden files, so Orra's
# numbers and Voxt's published ones are comparable.
#
# tokens(), edit_distance() and the three groups are ported from
# sglang_omni_mlx/native/ci/check_golden.py in sglang-omni
# (https://github.com/sgl-project/sglang-omni, commit aac4b83), Copyright the sglang-omni
# authors, licensed under the Apache License 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). The scores per stratum, the timing and
# the comparison of two runs are Orra's. Standard library only, so CI runs the tests on
# Linux with any python3.
#
# Usage:
#
#     python3 score.py RUN [RUN ...]            one column per run
#     python3 score.py --diff RUN_A RUN_B       clips where the two runs differ most
#
# A run is a JSON file with {"clips": {clip id: {"text": ...}}}: the file the Swift
# evaluation writes, or a Voxt golden file, read as FILE@DEVICE (the first device when no
# device is given). --field picks another text field of the clips, such as ruled_text.

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Voxt's three numbers: WER over English (LibriSpeech, the 10 dB copies included), CER over
# Chinese (FLEURS and the Chinese only ASCEND clips) and MER over code switched ASCEND.
GROUPS = {
    "wer_en": lambda clip: clip["lang"] == "en" and clip["stratum"] not in ("silence", "noise"),
    "cer_zh": lambda clip: clip["lang"] == "zh",
    "mer_mixed": lambda clip: clip["stratum"] == "mixed",
}
STRATA = ["en_short", "en_mid", "en_long", "snr10_en", "zh_short", "zh_numbers", "zh_mid", "zh_long", "snr10_zh", "mixed"]
EMPTY_STRATA = ["silence", "noise"]


def tokens(text: str, lang: str) -> list[str]:
    """English: lower case words of letters, digits and apostrophes. Anything else: one token
    per CJK character and one per run of letters, digits and apostrophes. NFKC first, so
    full width digits and letters count as ASCII. Punctuation is never a token."""
    text = unicodedata.normalize("NFKC", text).lower()
    if lang == "en":
        text = re.sub(r"[^a-z0-9' ]+", " ", text)
        return [token.strip("'") for token in text.split() if token.strip("'")]
    return re.findall(r"[㐀-鿿豈-﫿]|[a-z0-9']+", text)


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def scoring_lang(clip: dict) -> str:
    return "en" if clip["lang"] == "en" else "zh"


def clip_errors(clip: dict, text: str) -> tuple[int, int]:
    """Errors and reference tokens of one clip."""
    lang = scoring_lang(clip)
    reference = tokens(clip["reference"], lang)
    return edit_distance(reference, tokens(text, lang)), len(reference)


def load_manifest(path: Path = HERE / "manifest.jsonl") -> dict[str, dict]:
    return {row["id"]: row for row in map(json.loads, path.read_text(encoding="utf-8").splitlines())}


def load_run(spec: str, field: str = "text") -> tuple[str, dict[str, dict]]:
    """Returns a label and the clips of a run, each with its text under "text". A Voxt
    golden file has only "text"."""
    path, _, device = spec.partition("@")
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    label = Path(path).stem
    if "devices" in data:
        device = device or next(iter(data["devices"]))
        clips = data["devices"][device]["clips"]
        label += f" ({device})"
        field = "text"
    else:
        clips = data["clips"]
    if field != "text":
        label += f" [{field}]"
    return label, {clip_id: {**row, "text": row[field]} for clip_id, row in clips.items()}


def metrics(manifest: dict[str, dict], texts: dict[str, str]) -> dict[str, float]:
    """Voxt's three error rates, rounded as Voxt rounds them."""
    result = {}
    for name, keep in GROUPS.items():
        errors = total = 0
        for clip_id, text in texts.items():
            clip = manifest[clip_id]
            if keep(clip):
                found, count = clip_errors(clip, text)
                errors += found
                total += count
        result[name] = round(errors / total, 5) if total else 0.0
    return result


def strata(manifest: dict[str, dict], texts: dict[str, str]) -> dict[str, tuple[float, int]]:
    """Error rate and clip count per stratum. Silence and noise give the number of clips
    with any output instead, since they have no reference."""
    result = {}
    for stratum in STRATA:
        errors = total = clips = 0
        for clip_id, text in texts.items():
            if manifest[clip_id]["stratum"] == stratum:
                found, count = clip_errors(manifest[clip_id], text)
                errors, total, clips = errors + found, total + count, clips + 1
        result[stratum] = (errors / total if total else 0.0, clips)
    for stratum in EMPTY_STRATA:
        ids = [clip_id for clip_id in texts if manifest[clip_id]["stratum"] == stratum]
        result[stratum] = (sum(1 for clip_id in ids if tokens(texts[clip_id], "zh")), len(ids))
    return result


def percentile(values: list[float], fraction: float) -> float:
    """Nearest rank."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def timing(clips: dict[str, dict]) -> dict[str, float] | None:
    # A clip of pure zeros is skipped like a dictation of a dead microphone, so it has no time.
    rows = [row for row in clips.values() if "decode_seconds" in row and "audio_seconds" in row and not row.get("skipped_silent")]
    if not rows:
        return None
    decode = [row["decode_seconds"] for row in rows]
    factors = [row["decode_seconds"] / row["audio_seconds"] for row in rows if row["audio_seconds"] > 0]
    return {
        "decode_median": statistics.median(decode),
        "decode_p95": percentile(decode, 0.95),
        "rtf_median": statistics.median(factors),
        "rtf_p95": percentile(factors, 0.95),
        "rtf_total": sum(decode) / sum(row["audio_seconds"] for row in rows),
    }


def table(manifest: dict[str, dict], runs: list[tuple[str, dict[str, dict]]]) -> str:
    texts = [{clip_id: row["text"] for clip_id, row in clips.items()} for _, clips in runs]
    for (label, clips) in runs:
        missing = set(manifest) - set(clips)
        if missing:
            print(f"warning: {label} lacks {len(missing)} clips", file=sys.stderr)
    lines = ["| | " + " | ".join(label for label, _ in runs) + " |", "|---" * (len(runs) + 1) + "|"]
    all_metrics = [metrics(manifest, run) for run in texts]
    for name in GROUPS:
        lines.append(f"| {name} | " + " | ".join(f"{m[name]:.2%}" for m in all_metrics) + " |")
    all_strata = [strata(manifest, run) for run in texts]
    for stratum in STRATA:
        count = all_strata[0][stratum][1]
        lines.append(f"| {stratum} ({count}) | " + " | ".join(f"{s[stratum][0]:.2%}" for s in all_strata) + " |")
    for stratum in EMPTY_STRATA:
        count = all_strata[0][stratum][1]
        lines.append(f"| {stratum}, clips with output (of {count}) | " + " | ".join(str(s[stratum][0]) for s in all_strata) + " |")
    timings = [timing(clips) for _, clips in runs]
    if any(timings):
        for key, title, unit in [
            ("decode_median", "decode median", "s"),
            ("decode_p95", "decode p95", "s"),
            ("rtf_median", "real time factor, median", ""),
            ("rtf_p95", "real time factor, p95", ""),
            ("rtf_total", "real time factor, all audio", ""),
        ]:
            lines.append(f"| {title} | " + " | ".join(f"{t[key]:.3f}{' ' + unit if unit else ''}" if t else "n/a" for t in timings) + " |")
    return "\n".join(lines)


def diff(manifest: dict[str, dict], first: tuple[str, dict], second: tuple[str, dict], top: int, show_text: bool) -> str:
    """Clips sorted by how many more errors the first run has than the second."""
    rows = []
    for clip_id, clip in manifest.items():
        if clip_id not in first[1] or clip_id not in second[1]:
            continue
        a_text, b_text = first[1][clip_id]["text"], second[1][clip_id]["text"]
        if clip["reference"]:
            a, total = clip_errors(clip, a_text)
            b, _ = clip_errors(clip, b_text)
        else:
            a, b, total = len(tokens(a_text, "zh")), len(tokens(b_text, "zh")), 0
        if a != b:
            rows.append((a - b, clip_id, a, b, total, clip, a_text, b_text))
    rows.sort(key=lambda row: (-abs(row[0]), row[1]))
    worse = sum(1 for row in rows if row[0] > 0)
    lines = [f"{first[0]} against {second[0]}: {len(rows)} clips differ in errors, {worse} worse, {len(rows) - worse} better"]
    for delta, clip_id, a, b, total, clip, a_text, b_text in rows[:top]:
        lines.append(f"{clip_id} {clip['stratum']} {clip['duration']} s: {a} against {b} errors of {total} ({delta:+d})")
        if show_text:
            lines += [f"  ref: {clip['reference']}", f"  A:   {a_text}", f"  B:   {b_text}"]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Scores runs on the speech corpus.")
    parser.add_argument("runs", nargs="+", help="JSON files, FILE@DEVICE for a Voxt golden file")
    parser.add_argument("--manifest", type=Path, default=HERE / "manifest.jsonl")
    parser.add_argument("--field", default="text", help="the text field of the clips to score")
    parser.add_argument("--diff", action="store_true", help="compare two runs clip by clip")
    parser.add_argument("--top", type=int, default=30)
    parser.add_argument("--text", action="store_true", help="print the texts with --diff")
    arguments = parser.parse_args()
    manifest = load_manifest(arguments.manifest)
    runs = [load_run(spec, arguments.field) for spec in arguments.runs]
    if arguments.diff:
        if len(runs) != 2:
            raise SystemExit("--diff takes two runs")
        print(diff(manifest, runs[0], runs[1], arguments.top, arguments.text))
    else:
        print(table(manifest, runs))


if __name__ == "__main__":
    main()
