#!/usr/bin/env python3
"""The release gate's scorer and comparer. Standard library only.

run.sh runs the opt in evaluations, which write their raw output to OUT/raw. This script
turns that into one JSON file per suite in OUT, and compares two such folders case by case:

    python3 gate.py summarize OUT [--sets SETS_DIR]
    python3 gate.py compare BASELINE CANDIDATE [--only corpus,context,...]
    python3 gate.py show OUT

compare prints every metric of both folders, then every rule that failed with the IDs of
the cases that got worse, and exits 1 when a rule failed. docs/release-gate.md lists the
rules and their tolerances, which are the constants below.
"""

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
sys.path.insert(0, str(HERE.parent / "speech-eval"))
import score as speech_score  # noqa: E402  Tools/speech-eval/score.py, Voxt's normalization

SUITES = ["corpus", "context", "cleanup", "latency", "sets"]

# Tolerances. A rate is in percentage points, so 0.10 lets cer_zh go from 3.98% to 4.08%.
CORPUS_RATE_TOLERANCE = 0.10
CONTEXT_RATE_TOLERANCE = 0.25
CONTEXT_RECALL_TOLERANCE = 0.5
SET_RATE_TOLERANCE = 0.5
# A p90 may grow by 20%, and growth under the floor never counts, so a step of 0.02 ms that
# becomes 0.03 ms does not fail the gate.
LATENCY_GROWTH = 0.20
LATENCY_FLOOR_MS = 10.0
CONTEXT_LATENCY_FLOOR_S = 0.1


def percentile(values: list[float], fraction: float) -> float:
    """Nearest rank, as the Swift tests compute it."""
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[min(max(math.ceil(fraction * len(ordered)) - 1, 0), len(ordered) - 1)]


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, document: dict) -> None:
    path.write_text(json.dumps(document, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")


def normalized(text: str) -> str:
    """Lower case letters, digits and CJK characters only, so "N P C" matches "NPC"."""
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(character for character in text if character.isalnum())


def term_found(term: str, text: str) -> bool:
    """Whether the text holds the term as the vocabulary writes it.

    White space inside the term is free, so "N P C" matches "NPC". A term with Latin
    letters matches case sensitively and not inside a longer word, so the plain word
    cursor is not the term Cursor and trust does not hold Rust. Other terms match as
    a substring, as Chinese has no spaces between words.
    """
    characters = [character for character in unicodedata.normalize("NFKC", term) if not character.isspace()]
    if not characters:
        return False
    pattern = r"\s*".join(re.escape(character) for character in characters)
    if any(character.isascii() and character.isalpha() for character in characters):
        pattern = rf"(?<![A-Za-z]){pattern}(?![A-Za-z])"
    return re.search(pattern, unicodedata.normalize("NFKC", text)) is not None


def rate(errors: int, tokens: int) -> float:
    return round(100 * errors / tokens, 3) if tokens else 0.0


# Summaries, one per suite, from OUT/raw.


def summarize_corpus(raw: dict, manifest: dict[str, dict]) -> dict:
    clips = {}
    groups = {}
    for field in ("text", "ruled_text"):
        totals = {name: [0, 0] for name in speech_score.GROUPS}
        for clip_id, row in raw["clips"].items():
            clip = manifest[clip_id]
            text = row.get(field, "")
            entry = clips.setdefault(clip_id, {"audio_seconds": row.get("audio_seconds"), "decode_seconds": row.get("decode_seconds", 0.0)})
            if clip["reference"]:
                errors, count = speech_score.clip_errors(clip, text)
                entry["tokens"] = count
            else:
                # Silence and noise: any output is an error.
                errors, count = len(speech_score.tokens(text, "zh")), 0
                entry["tokens"] = 0
            entry["errors" if field == "text" else "ruled_errors"] = errors
            for name, keep in speech_score.GROUPS.items():
                if keep(clip):
                    totals[name][0] += errors
                    totals[name][1] += count
        groups[field] = {name: rate(*values) for name, values in totals.items()}
    decode = [row["decode_seconds"] for row in raw["clips"].values() if not row.get("skipped_silent")]
    return {
        "suite": "corpus",
        "build": raw.get("build"),
        "groups": groups,
        "decode_median_s": statistics.median(decode) if decode else None,
        "decode_p90_s": percentile(decode, 0.9),
        "clips": clips,
    }


def summarize_context(raw: dict) -> dict:
    sets: dict[str, dict] = {}
    clips = {}
    for row in raw["clips"]:
        total = sets.setdefault(row["set"], {"clips": 0, "terms": 0, "distractors": 0, "reference_tokens": 0, "plain": {"found": 0, "inserted": 0, "errors": 0, "seconds": []}, "context": {"found": 0, "inserted": 0, "errors": 0, "seconds": []}})
        total["clips"] += 1
        total["terms"] += row["terms"]
        total["distractors"] += row["distractors"]
        total["reference_tokens"] += row["reference_tokens"]
        for way in ("plain", "context"):
            for key in ("found", "inserted", "errors"):
                total[way][key] += row[way][key]
            total[way]["seconds"].append(row[way]["seconds"])
        clips[f"{row['set']}/{row['id']}"] = {
            "terms": row["terms"],
            "found": row["context"]["found"],
            "inserted": row["context"]["inserted"],
            "errors": row["context"]["errors"],
            "errors_plain": row["plain"]["errors"],
            "seconds": row["context"]["seconds"],
            "seconds_plain": row["plain"]["seconds"],
            "audio_seconds": row["audio_seconds"],
        }
    for total in sets.values():
        for way in ("plain", "context"):
            seconds = total[way].pop("seconds")
            total[way]["recall"] = rate(total[way]["found"], total["terms"])
            total[way]["error_rate"] = rate(total[way]["errors"], total["reference_tokens"])
            total[way]["median_s"] = percentile(seconds, 0.5)
            total[way]["p90_s"] = percentile(seconds, 0.9)
            total[way]["p95_s"] = percentile(seconds, 0.95)
    return {"suite": "context", "build": raw.get("build"), "sets": sets, "summary": raw.get("summary", {}), "clips": clips}


def summarize_cleanup(raw: dict) -> dict:
    groups: dict[str, dict] = {}
    cases = {}
    for row in raw["cases"]:
        key = f"{row['set']}/{row['mode']}"
        group = groups.setdefault(key, {"cases": 0, "exact": 0, "obeyed": 0, "seconds": []})
        group["cases"] += 1
        group["exact"] += bool(row["exact"])
        group["obeyed"] += bool(row["obeyed"])
        group["seconds"].append(row["seconds"])
        cases[f"{key}/{row['id']}"] = {"exact": bool(row["exact"]), "obeyed": bool(row["obeyed"]), "outcome": row["outcome"]}
    for group in groups.values():
        seconds = group.pop("seconds")
        group["median_s"] = percentile(seconds, 0.5)
        group["p90_s"] = percentile(seconds, 0.9)
    return {"suite": "cleanup", "build": raw.get("build"), "groups": groups, "cases": cases}


def summarize_latency(raw: dict) -> dict:
    return {"suite": "latency", "build": raw.get("build"), "rounds": raw.get("rounds"), "modes": raw["modes"]}


def load_set_manifest(folder: Path) -> dict[str, dict]:
    rows = {}
    for line in (folder / "manifest.jsonl").read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            rows[row["id"]] = row
    return rows


def score_set_clip(clip: dict, text: str) -> dict:
    lang = "en" if clip.get("language") == "en" else "zh"
    reference = speech_score.tokens(clip.get("reference", ""), lang)
    errors = speech_score.edit_distance(reference, speech_score.tokens(text, lang))
    expect = [term for term in clip.get("expect_terms", []) if normalized(term)]
    forbid = [term for term in clip.get("forbid_terms", []) if normalized(term)]
    return {
        "errors": errors,
        "tokens": len(reference),
        "missing_terms": [term for term in expect if not term_found(term, text)],
        "expect_terms": len(expect),
        "forbidden_found": [term for term in forbid if term_found(term, text)],
    }


def summarize_sets(raw: dict, sets_dir: Path) -> dict:
    manifests: dict[str, dict] = {}
    clips = {}
    sets: dict[str, dict] = {}
    for row in raw["clips"]:
        name = row["set"]
        if name not in manifests:
            manifests[name] = load_set_manifest(sets_dir / name)
        scored = score_set_clip(manifests[name][row["id"]], row["text"])
        scored["total_ms"] = row.get("total_ms")
        clips[f"{name}/{row['id']}"] = scored
        total = sets.setdefault(name, {"clips": 0, "errors": 0, "tokens": 0, "expect_terms": 0, "missing_terms": 0, "forbidden_found": 0, "exact_clips": 0})
        total["clips"] += 1
        total["errors"] += scored["errors"]
        total["tokens"] += scored["tokens"]
        total["expect_terms"] += scored["expect_terms"]
        total["missing_terms"] += len(scored["missing_terms"])
        total["forbidden_found"] += len(scored["forbidden_found"])
        total["exact_clips"] += scored["errors"] == 0
    for total in sets.values():
        total["error_rate"] = rate(total["errors"], total["tokens"])
        total["expect_recall"] = rate(total["expect_terms"] - total["missing_terms"], total["expect_terms"]) if total["expect_terms"] else 100.0
    return {"suite": "sets", "build": raw.get("build"), "sets": sets, "clips": clips}


def summarize(out: Path, sets_dir: Path | None, corpus_manifest: Path) -> list[str]:
    raw = out / "raw"
    written = []
    corpus = raw / "corpus.json"
    if corpus.exists():
        write_json(out / "corpus.json", summarize_corpus(read_json(corpus), speech_score.load_manifest(corpus_manifest)))
        written.append("corpus")
    for suite, function in (("context", summarize_context), ("cleanup", summarize_cleanup), ("latency", summarize_latency)):
        path = raw / f"{suite}.json"
        if path.exists():
            write_json(out / f"{suite}.json", function(read_json(path)))
            written.append(suite)
    sets_raw = raw / "sets-raw.json"
    if sets_raw.exists():
        if sets_dir is None:
            raise SystemExit("--sets is needed to score the gate sets")
        write_json(out / "sets.json", summarize_sets(read_json(sets_raw), sets_dir))
        written.append("sets")
    return written


# Comparison. Each function returns lines to show and failures, each failure a rule and the
# IDs of the cases behind it.


class Result:
    def __init__(self) -> None:
        self.lines: list[str] = []
        self.failures: list[tuple[str, list[str]]] = []
        self.worse: list[str] = []

    def fail(self, rule: str, ids: list[str] | None = None) -> None:
        self.failures.append((rule, sorted(ids or [])))


def compare_corpus(base: dict, cand: dict, result: Result) -> None:
    for field in ("text", "ruled_text"):
        for name, value in cand["groups"][field].items():
            old = base["groups"][field].get(name)
            result.lines.append(f"corpus {field} {name}: {old:.2f}% -> {value:.2f}%")
            if old is not None and value - old > CORPUS_RATE_TOLERANCE:
                result.fail(f"corpus {field} {name} rose by {value - old:.2f} points, more than {CORPUS_RATE_TOLERANCE}")
    result.lines.append(f"corpus decode p90: {base.get('decode_p90_s', 0):.3f} s -> {cand.get('decode_p90_s', 0):.3f} s")
    newly_wrong = []
    for clip_id, row in cand["clips"].items():
        old = base["clips"].get(clip_id)
        if old is None:
            continue
        for key in ("errors", "ruled_errors"):
            if row[key] > old[key]:
                result.worse.append(f"corpus/{clip_id} {key} {old[key]} -> {row[key]}")
                if old[key] == 0:
                    newly_wrong.append(f"corpus/{clip_id}")
    if newly_wrong:
        result.fail("corpus clips that were right and are now wrong", sorted(set(newly_wrong)))


def compare_context(base: dict, cand: dict, result: Result) -> None:
    for name, total in cand["sets"].items():
        old = base["sets"].get(name)
        if old is None:
            result.lines.append(f"context {name}: new set")
            continue
        new_way, old_way = total["context"], old["context"]
        result.lines.append(
            f"context {name}: recall {old_way['recall']:.1f}% -> {new_way['recall']:.1f}%, inserted {old_way['inserted']} -> {new_way['inserted']}, "
            f"error {old_way['error_rate']:.2f}% -> {new_way['error_rate']:.2f}%, p90 {old_way['p90_s']:.2f} s -> {new_way['p90_s']:.2f} s"
        )
        if old_way["recall"] - new_way["recall"] > CONTEXT_RECALL_TOLERANCE:
            result.fail(f"context {name} term recall fell by {old_way['recall'] - new_way['recall']:.1f} points")
        if new_way["error_rate"] - old_way["error_rate"] > CONTEXT_RATE_TOLERANCE:
            result.fail(f"context {name} error rate rose by {new_way['error_rate'] - old_way['error_rate']:.2f} points")
        for way in ("plain", "context"):
            if total[way]["p90_s"] > old[way]["p90_s"] * (1 + LATENCY_GROWTH) and total[way]["p90_s"] - old[way]["p90_s"] > CONTEXT_LATENCY_FLOOR_S:
                result.fail(f"context {name} {way} p90 rose from {old[way]['p90_s']:.2f} s to {total[way]['p90_s']:.2f} s")
    missed, inserted = [], []
    for clip_id, row in cand["clips"].items():
        old = base["clips"].get(clip_id)
        if old is None:
            continue
        if row["found"] < old["found"]:
            result.worse.append(f"context/{clip_id} terms found {old['found']} -> {row['found']}")
            if old["found"] == old["terms"]:
                missed.append(f"context/{clip_id}")
        if row["inserted"] > old["inserted"]:
            inserted.append(f"context/{clip_id}")
        if row["errors"] > old["errors"]:
            result.worse.append(f"context/{clip_id} errors {old['errors']} -> {row['errors']}")
    if missed:
        result.fail("context clips that found all their terms and now miss one", missed)
    if inserted:
        result.fail("context clips with more distractors inserted", inserted)
    for key, field in (("ascend_mixed", "inserted"), ("no_speech", "gave_text")):
        old = base.get("summary", {}).get(key, {}).get(field)
        new = cand.get("summary", {}).get(key, {}).get(field)
        if old is not None and new is not None:
            result.lines.append(f"context {key} {field}: {old} -> {new}")
            if new > old:
                result.fail(f"context {key} {field} rose from {old} to {new}")


def compare_cleanup(base: dict, cand: dict, result: Result) -> None:
    for key, group in sorted(cand["groups"].items()):
        old = base["groups"].get(key)
        if old is None:
            result.lines.append(f"cleanup {key}: new")
            continue
        result.lines.append(f"cleanup {key}: exact {old['exact']} -> {group['exact']} of {group['cases']}, obeyed {old['obeyed']} -> {group['obeyed']}, median {old['median_s']:.3f} s -> {group['median_s']:.3f} s")
        if group["exact"] < old["exact"]:
            result.fail(f"cleanup {key} exact count fell from {old['exact']} to {group['exact']}")
    newly_wrong, obeyed = [], []
    for case_id, row in cand["cases"].items():
        if row["obeyed"]:
            obeyed.append(f"cleanup/{case_id}")
        old = base["cases"].get(case_id)
        if old is not None and old["exact"] and not row["exact"]:
            newly_wrong.append(f"cleanup/{case_id}")
            result.worse.append(f"cleanup/{case_id} exact -> {row['outcome']}")
    if newly_wrong:
        result.fail("cleanup cases that were exact and are not now", newly_wrong)
    if obeyed:
        result.fail("adversarial cleanups that look obeyed", obeyed)


def compare_latency(base: dict, cand: dict, result: Result) -> None:
    for mode, data in sorted(cand["modes"].items()):
        old_mode = base["modes"].get(mode)
        if old_mode is None:
            continue
        for step, values in data["steps"].items():
            old = old_mode["steps"].get(step)
            if old is None:
                continue
            if step == "total" or values["p90"] >= 1 or old["p90"] >= 1:
                result.lines.append(f"latency {mode} {step}: median {old['median']:.1f} -> {values['median']:.1f} ms, p90 {old['p90']:.1f} -> {values['p90']:.1f} ms")
            if values["p90"] > old["p90"] * (1 + LATENCY_GROWTH) and values["p90"] - old["p90"] > LATENCY_FLOOR_MS:
                result.fail(f"latency {mode} {step} p90 rose from {old['p90']:.1f} to {values['p90']:.1f} ms, more than {LATENCY_GROWTH:.0%}")
        slower = [f"latency/{mode}/{clip}" for clip, row in data.get("clips", {}).items()
                  if clip in old_mode.get("clips", {}) and row["median"] > old_mode["clips"][clip]["median"] * (1 + LATENCY_GROWTH) and row["median"] - old_mode["clips"][clip]["median"] > LATENCY_FLOOR_MS]
        result.worse += [f"{clip} median more than {LATENCY_GROWTH:.0%} slower" for clip in slower]


def compare_sets(base: dict, cand: dict, result: Result) -> None:
    for name, total in sorted(cand["sets"].items()):
        old = base["sets"].get(name)
        if old is None:
            result.lines.append(f"sets {name}: new, error {total['error_rate']:.2f}%, terms {total['expect_recall']:.1f}%, forbidden {total['forbidden_found']}")
            continue
        result.lines.append(
            f"sets {name}: error {old['error_rate']:.2f}% -> {total['error_rate']:.2f}%, exact clips {old['exact_clips']} -> {total['exact_clips']} of {total['clips']}, "
            f"terms {old['expect_recall']:.1f}% -> {total['expect_recall']:.1f}%, forbidden {old['forbidden_found']} -> {total['forbidden_found']}"
        )
        if total["error_rate"] - old["error_rate"] > SET_RATE_TOLERANCE:
            result.fail(f"sets {name} error rate rose by {total['error_rate'] - old['error_rate']:.2f} points")
    newly_wrong, missing, forbidden = [], [], []
    for clip_id, row in cand["clips"].items():
        old = base["clips"].get(clip_id)
        new_forbidden = set(row["forbidden_found"]) - set(old["forbidden_found"] if old else [])
        if new_forbidden:
            forbidden.append(f"sets/{clip_id}")
        if old is None:
            continue
        if row["errors"] > old["errors"]:
            result.worse.append(f"sets/{clip_id} errors {old['errors']} -> {row['errors']}")
            if old["errors"] == 0:
                newly_wrong.append(f"sets/{clip_id}")
        if set(row["missing_terms"]) - set(old["missing_terms"]):
            missing.append(f"sets/{clip_id}")
    if newly_wrong:
        result.fail("set clips that were right and are now wrong", newly_wrong)
    if missing:
        result.fail("set clips that lost an expected term", missing)
    if forbidden:
        result.fail("set clips with a forbidden term inserted", forbidden)


COMPARERS = {"corpus": compare_corpus, "context": compare_context, "cleanup": compare_cleanup, "latency": compare_latency, "sets": compare_sets}


def compare(baseline: Path, candidate: Path, only: list[str]) -> Result:
    result = Result()
    for suite in only:
        base_file, cand_file = baseline / f"{suite}.json", candidate / f"{suite}.json"
        if not cand_file.exists():
            result.fail(f"{suite}: no result in {candidate}")
            continue
        if not base_file.exists():
            result.lines.append(f"{suite}: no baseline, nothing to compare")
            continue
        COMPARERS[suite](read_json(base_file), read_json(cand_file), result)
    return result


def show(out: Path) -> None:
    """The headline numbers of one folder."""
    for suite in SUITES:
        path = out / f"{suite}.json"
        if path.exists():
            # Comparing a folder with itself prints its numbers and never fails.
            data = read_json(path)
            result = Result()
            COMPARERS[suite](data, data, result)
            for line in result.lines:
                print(line)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("summarize")
    s.add_argument("out", type=Path)
    s.add_argument("--sets", type=Path)
    s.add_argument("--corpus-manifest", type=Path, default=HERE.parent / "speech-eval" / "manifest.jsonl")
    c = sub.add_parser("compare")
    c.add_argument("baseline", type=Path)
    c.add_argument("candidate", type=Path)
    c.add_argument("--only", default=",".join(SUITES))
    w = sub.add_parser("show")
    w.add_argument("out", type=Path)
    arguments = parser.parse_args()

    if arguments.command == "summarize":
        written = summarize(arguments.out, arguments.sets, arguments.corpus_manifest)
        print("summarized: " + (", ".join(written) or "nothing"))
    elif arguments.command == "show":
        show(arguments.out)
    else:
        only = [suite for suite in arguments.only.split(",") if suite]
        unknown = set(only) - set(SUITES)
        if unknown:
            raise SystemExit(f"unknown suites: {', '.join(sorted(unknown))}")
        result = compare(arguments.baseline, arguments.candidate, only)
        print("\n".join(result.lines))
        if result.worse:
            print(f"\n{len(result.worse)} cases got worse:")
            print("\n".join(f"  {line}" for line in result.worse))
        if result.failures:
            print(f"\nFAILED, {len(result.failures)} rules:")
            for rule, ids in result.failures:
                print(f"  {rule}" + (f": {' '.join(ids)}" if ids else ""))
            sys.exit(1)
        print("\nPASSED")


if __name__ == "__main__":
    main()
