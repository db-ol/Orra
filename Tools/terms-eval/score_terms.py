# Scores runs of OrraTests/SpeechCorpusEvaluationTests on the built-in terms clips.
#
#     python3 Tools/terms-eval/score_terms.py RUN [RUN ...]
#
# Per run: the share of spoken terms written exactly (same letters and case) and loosely
# (ignoring case, spaces and punctuation), WER over the English clips, CER over the
# Chinese and MER over the mixed ones (Tools/speech-eval/score.py's tokens), built-in terms
# that appear in a control clip without being said, and the decode time.
from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "speech-eval"))
from score import edit_distance, tokens  # noqa: E402


def builtin_terms() -> list[str]:
    source = (HERE.parent.parent / "Orra" / "BuiltinTerms.swift").read_text(encoding="utf-8")
    lists = source.split("static let common")[1].split("static let all")[0]
    return re.findall(r'"([^"]+)"', lists)


def loose(text: str) -> str:
    return "".join(character for character in text.lower() if character.isalnum())


def written(term: str, text: str) -> bool:
    """The term in the text with the same case, not inside a longer Latin word."""
    pattern = re.escape(term)
    if re.match(r"[A-Za-z0-9]", term[0]):
        pattern = r"(?<![A-Za-z0-9])" + pattern
    if re.match(r"[A-Za-z0-9]", term[-1]):
        pattern += r"(?![A-Za-z0-9])"
    return re.search(pattern, text) is not None


def score(rows: list[dict], clips: dict[str, dict], terms: list[str]) -> dict[str, str]:
    exact = looseFound = spoken = 0
    errors = {"en": [0, 0], "zh": [0, 0], "mixed": [0, 0]}
    control_errors = [0, 0]
    inserted = 0
    decode = []
    for row in rows:
        text = clips[row["id"]]["text"]
        decode.append(clips[row["id"]]["decode_seconds"])
        lang = "en" if row["lang"] == "en" else "zh"
        found, count = edit_distance(tokens(row["reference"], lang), tokens(text, lang)), len(tokens(row["reference"], lang))
        if row["control"]:
            control_errors[0] += found
            control_errors[1] += count
            inserted += sum(1 for term in terms if written(term, text) and not written(term, row["reference"]))
            continue
        errors[row["lang"]][0] += found
        errors[row["lang"]][1] += count
        for term in row["terms"]:
            spoken += 1
            exact += written(term, text)
            looseFound += loose(term) in loose(text)
    rate = lambda pair: f"{100 * pair[0] / max(pair[1], 1):.2f}%"
    decode.sort()
    return {
        "terms written exactly": f"{exact}/{spoken} ({100 * exact / spoken:.1f}%)",
        "terms, ignoring case and spaces": f"{looseFound}/{spoken} ({100 * looseFound / spoken:.1f}%)",
        "wer_en (term clips)": rate(errors["en"]),
        "cer_zh (term clips)": rate(errors["zh"]),
        "mer_mixed (term clips)": rate(errors["mixed"]),
        "control error rate": rate(control_errors),
        "terms inserted in controls": str(inserted),
        "decode, median": f"{decode[len(decode) // 2]:.3f} s",
        "decode, mean": f"{statistics.mean(decode):.3f} s",
    }


def main(paths: list[str]) -> None:
    rows = [json.loads(line) for line in (HERE / "sentences.jsonl").read_text(encoding="utf-8").splitlines()]
    terms = builtin_terms()
    columns = []
    for path in paths:
        run = json.loads(Path(path).read_text(encoding="utf-8"))
        columns.append((f"{Path(path).stem} ({run.get('vocabulary_terms', 0)})", score(rows, run["clips"], terms)))
    keys = list(columns[0][1])
    print("| | " + " | ".join(name for name, _ in columns) + " |")
    print("|---" * (len(columns) + 1) + "|")
    for key in keys:
        print(f"| {key} | " + " | ".join(values[key] for _, values in columns) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
