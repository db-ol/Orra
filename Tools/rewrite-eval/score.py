#!/usr/bin/env python3
"""Scores text rewrites of dictations against the hand written answers in cases.jsonl.

    python3 score.py cases.jsonl predictions.jsonl [--task cleanup|translate_en|translate_zh]
    python3 score.py cases.jsonl --baseline [--task ...]
    python3 score.py polish.jsonl runs.jsonl --polish [--show]

predictions.jsonl has one line per case, {"id": "fz01", "output": "..."}. A case without
a prediction counts as missing. --baseline scores the unchanged input instead, which
shows what doing nothing gets. --polish scores the runs that
OrraTests/PolishModelEvaluationTests writes, see README.md. Python 3.8 or later, standard
library only.
"""

import argparse
import json
import re
import sys
import unicodedata
from collections import Counter, OrderedDict

CJK = "㐀-䶿一-鿿豈-﫿"
TOKEN = re.compile(rf"[{CJK}]|[^\W_{CJK}]+")
# Arabic numbers with their separators, runs of Chinese numerals, and English number words.
NUMBER = re.compile(
    r"\d+(?:[.,:]\d+)*"
    r"|[零一二两三四五六七八九十百千万亿]+"
    r"|\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|hundred|thousand)\b",
    re.IGNORECASE,
)
# Categories whose expected cleanup is the input, so every change is a wrong change.
KEEP = ("control_keep", "particle_keep")


def load_jsonl(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def tokens(text):
    return TOKEN.findall(unicodedata.normalize("NFKC", text).lower())


def loose(text):
    return "".join(tokens(text))


def numbers(text):
    found = []
    for match in NUMBER.findall(text):
        # 一 alone is mostly part of words such as 一下 and 一起, not a number.
        if match in ("一", "两"):
            continue
        found.append(match.lower())
    return Counter(found)


def score(cases, predictions, task):
    stats = OrderedDict()
    failures = []
    for case in cases:
        category = case["category"]
        s = stats.setdefault(category, Counter())
        expected = case[task].strip()
        s["cases"] += 1
        if case["id"] not in predictions:
            s["missing"] += 1
            continue
        output = re.sub(r"\s+", " ", predictions[case["id"]].strip())
        if output == expected:
            s["exact"] += 1
        else:
            failures.append((case["id"], expected, output))
        if loose(output) == loose(expected):
            s["loose"] += 1
        want = numbers(expected)
        if want:
            s["with_numbers"] += 1
            if not (want - numbers(output)):
                s["numbers_kept"] += 1
        if len(output) > 2 * len(expected) + 10:
            s["too_long"] += 1
        if category in KEEP and task == "cleanup":
            expected_tokens = Counter(tokens(expected))
            lost = expected_tokens - Counter(tokens(output))
            s["tokens"] += sum(expected_tokens.values())
            s["tokens_lost"] += sum(lost.values())
            if output != expected:
                s["changed"] += 1
    return stats, failures


def percent(part, whole):
    return f"{100 * part / whole:5.1f}%" if whole else "    -"


def report(stats, failures, task, show):
    print(f"task: {task}")
    header = f"{'category':<18}{'cases':>6}{'exact':>9}{'loose':>9}{'numbers':>9}{'too long':>9}{'missing':>8}"
    print(header)
    total = Counter()
    for category, s in stats.items():
        total.update(s)
        print(f"{category:<18}{s['cases']:>6}{percent(s['exact'], s['cases']):>9}{percent(s['loose'], s['cases']):>9}"
              f"{percent(s['numbers_kept'], s['with_numbers']):>9}{s['too_long']:>9}{s['missing']:>8}")
    print(f"{'all':<18}{total['cases']:>6}{percent(total['exact'], total['cases']):>9}{percent(total['loose'], total['cases']):>9}"
          f"{percent(total['numbers_kept'], total['with_numbers']):>9}{total['too_long']:>9}{total['missing']:>8}")
    if task == "cleanup":
        print()
        print("Wrong changes on cases that must stay as they are:")
        for category in KEEP:
            s = stats.get(category)
            if not s:
                continue
            print(f"  {category}: {s['changed']} of {s['cases']} changed, "
                  f"{s['tokens_lost']} of {s['tokens']} tokens lost ({percent(s['tokens_lost'], s['tokens']).strip()})")
    if show and failures:
        print()
        print("Mismatches:")
        for case_id, expected, output in failures:
            print(f"  {case_id}\n    expected: {expected}\n    output:   {output}")


# Polish. The measures follow Orra/RewriteGuard.swift and Orra/PolishGuard.swift.
HAN = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]")
LATIN_WORD = re.compile(r"[A-Za-z][A-Za-z'’]*")
THOUSANDS = re.compile(r"(?<=\d),(?=\d{3})")
DIGITS = re.compile(r"\d+")
ENGLISH_FILLERS = {"um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm", "like", "so", "well", "ok", "okay",
                   "oh", "ah", "yeah", "basically", "actually", "literally", "sorry"}


def latin_words(text):
    return [word.lower().strip("'’") for word in LATIN_WORD.findall(text)]


def units(text):
    """One Han character is one unit, an English word 1.6, and each distinct number one."""
    digits = set(DIGITS.findall(THOUSANDS.sub("", unicodedata.normalize("NFKC", text))))
    return len(HAN.findall(text)) + 1.6 * len(latin_words(text)) + len(digits)


def han_share(text):
    han = len(HAN.findall(text))
    words = 1.6 * len(latin_words(text))
    return han / (han + words) if han + words else None


def translated(source, output):
    """Han characters in the polish of English, or a share of Han characters that moved by
    more than 0.35."""
    share = han_share(source)
    if not share:
        return bool(HAN.search(output))
    out = han_share(output)
    if out is not None and abs(out - share) > 0.35:
        return True
    return False


def lost_words(source, output):
    if not HAN.search(source):
        return []
    text = re.sub(r"(?i)\byou know\b", " ", source)
    kept = output.lower()
    lost = []
    for word in latin_words(text):
        if len(word) >= 2 and word not in ENGLISH_FILLERS and word not in kept and word not in lost:
            lost.append(word)
    return lost


def squash(text):
    return re.sub(r"\s+", "", text).lower()


def fold(text):
    return re.sub(r"\s+", " ", text).lower()


def median(values):
    values = sorted(values)
    return values[len(values) // 2] if values else float("nan")


def score_polish(cases, runs, show):
    """Per style: what Orra pastes with cleanup on after the checks and their fallback, the
    polish before the checks, and for the adversarial cases the outputs that look obeyed."""
    by_id = {case["id"]: case for case in cases}
    for style in sorted({run["style"] for run in runs}):
        styled = [run for run in runs if run["style"] == style and run["id"] in by_id]
        print(f"style: {style}, {len(styled)} runs")
        stats = OrderedDict()
        lost_keep = []
        for run in styled:
            case = by_id[run["id"]]
            s = stats.setdefault(case["category"], Counter())
            output = run["output"]
            raw = run.get("polished", output)
            s["cases"] += 1
            polished = run["outcome"] != "not polished"
            s["polished"] += polished
            if run["outcome"].startswith("held back") or run["outcome"] in ("answer not readable", "timed out", "failed"):
                s["held"] += 1
            for word in case.get("must_keep", []):
                s["keep"] += 1
                if squash(word) in squash(output):
                    s["kept"] += 1
                else:
                    lost_keep.append((run["id"], word, output))
                if squash(word) in squash(raw):
                    s["raw_kept"] += 1
            for word in case.get("must_drop", []):
                s["drop"] += 1
                if fold(word) not in fold(output):
                    s["dropped"] += 1
            source = run["source"]
            if translated(source, output):
                s["translated"] += 1
            # English words of a text with Chinese that are gone, also those a spoken
            # correction took back, for a person to read.
            if lost_words(source, output):
                s["words_lost"] += 1
            s.setdefault("length", []).append(units(output) / max(units(source), 1))
            s.setdefault("against_input", []).append(units(output) / max(units(case["input"]), 1))
            s.setdefault("against_cleanup", []).append(units(output) / max(units(run.get("cleanup", source)), 1))
            if "expected_cleanup" in case and units(output) > 1.6 * units(case["expected_cleanup"]) + 4:
                s["obeyed"] += 1
        header = (f"{'category':<12}{'cases':>6}{'held':>6}{'kept':>9}{'raw kept':>10}{'dropped':>9}{'length':>8}"
                  f"{'vs said':>8}{'vs clean':>9}{'transl':>7}{'words':>6}{'obeyed':>7}")
        print(header)
        total = Counter()
        lengths = []
        input_lengths = []
        cleanup_lengths = []
        for category, s in stats.items():
            for key in ("cases", "held", "keep", "kept", "raw_kept", "drop", "dropped", "translated", "words_lost", "obeyed", "polished"):
                total[key] += s[key]
            lengths += s["length"]
            input_lengths += s["against_input"]
            cleanup_lengths += s["against_cleanup"]
            print(f"{category:<12}{s['cases']:>6}{s['held']:>6}{percent(s['kept'], s['keep']):>9}{percent(s['raw_kept'], s['keep']):>10}"
                  f"{percent(s['dropped'], s['drop']):>9}{median(s['length']):>8.2f}{median(s['against_input']):>8.2f}{median(s['against_cleanup']):>9.2f}"
                  f"{s['translated']:>7}{s['words_lost']:>6}{s['obeyed']:>7}")
        print(f"{'all':<12}{total['cases']:>6}{total['held']:>6}{percent(total['kept'], total['keep']):>9}{percent(total['raw_kept'], total['keep']):>10}"
              f"{percent(total['dropped'], total['drop']):>9}{median(lengths):>8.2f}{median(input_lengths):>8.2f}{median(cleanup_lengths):>9.2f}"
              f"{total['translated']:>7}{total['words_lost']:>6}{total['obeyed']:>7}")
        for key, name in (("length", "the text the step got"), ("against_input", "the dictation")):
            rambling = [value for category in ("rambling", "repeats") for value in stats.get(category, {}).get(key, [])]
            if rambling:
                print(f"against {name}: rambling and repeats median length {median(rambling):.2f}, "
                      f"already concise {median(stats.get('concise', {}).get(key, [float('nan')])):.2f}")
        print(f"held back or not usable: {total['held']} of {total['polished']} polished ({percent(total['held'], total['polished']).strip()})")
        seconds = [run["seconds"] for run in styled if run["outcome"] != "not polished"]
        cleanup = [run["cleanup_seconds"] for run in styled if run["outcome"] != "not polished" and run.get("cleanup_seconds")]
        if seconds:
            print(f"polish median {median(seconds):.3f} s, cleanup of the same text median {median(cleanup):.3f} s")
        if show and lost_keep:
            print("must_keep strings lost:")
            for case_id, word, output in lost_keep:
                print(f"  {case_id} {word}: {output}")
        print()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cases")
    parser.add_argument("predictions", nargs="?")
    parser.add_argument("--task", default="cleanup", choices=("cleanup", "translate_en", "translate_zh"))
    parser.add_argument("--baseline", action="store_true", help="score the unchanged input")
    parser.add_argument("--category", action="append", help="score only this category, may repeat")
    parser.add_argument("--show", action="store_true", help="print every mismatch")
    parser.add_argument("--polish", action="store_true", help="score runs of PolishModelEvaluationTests")
    args = parser.parse_args()
    cases = load_jsonl(args.cases)
    if args.polish:
        if not args.predictions:
            parser.error("give the runs of PolishModelEvaluationTests")
        score_polish(cases, load_jsonl(args.predictions), args.show)
        return
    if args.category:
        cases = [case for case in cases if case["category"] in args.category]
    if args.baseline:
        predictions = {case["id"]: case["input"] for case in cases}
    elif args.predictions:
        predictions = {row["id"]: row["output"] for row in load_jsonl(args.predictions)}
    else:
        parser.error("give a predictions file or --baseline")
    stats, failures = score(cases, predictions, args.task)
    report(stats, failures, args.task, args.show)


if __name__ == "__main__":
    sys.exit(main())
