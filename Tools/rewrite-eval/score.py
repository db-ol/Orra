#!/usr/bin/env python3
"""Scores text rewrites of dictations against the hand written answers in cases.jsonl.

    python3 score.py cases.jsonl predictions.jsonl [--task cleanup|translate_en|translate_zh]
    python3 score.py cases.jsonl --baseline [--task ...]

predictions.jsonl has one line per case, {"id": "fz01", "output": "..."}. A case without
a prediction counts as missing. --baseline scores the unchanged input instead, which
shows what doing nothing gets. Python 3.8 or later, standard library only.
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cases")
    parser.add_argument("predictions", nargs="?")
    parser.add_argument("--task", default="cleanup", choices=("cleanup", "translate_en", "translate_zh"))
    parser.add_argument("--baseline", action="store_true", help="score the unchanged input")
    parser.add_argument("--category", action="append", help="score only this category, may repeat")
    parser.add_argument("--show", action="store_true", help="print every mismatch")
    args = parser.parse_args()
    cases = load_jsonl(args.cases)
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
