# Scores transcripts of the speech corpus the way Voxt scores its golden files, so Orra's
# numbers and Voxt's published ones are comparable.
#
# tokens(), edit_distance() and the three groups are ported from
# sglang_omni_mlx/native/ci/check_golden.py in sglang-omni
# (https://github.com/sgl-project/sglang-omni, commit aac4b83), Copyright the sglang-omni
# authors, licensed under the Apache License 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). The scores per stratum, the timing and
# the comparison of two runs are Orra's, and so are the Japanese, Spanish and Korean groups
# for other corpora with the same layout, the rates without digits and the accepted
# spellings. Standard library only, so CI runs the tests on Linux with any python3.
#
# Usage:
#
#     python3 score.py RUN [RUN ...]            one column per run
#     python3 score.py --diff RUN_A RUN_B       clips where the two runs differ most
#
# A run is a JSON file with {"clips": {clip id: {"text": ...}}}: the file the Swift
# evaluation writes, or a Voxt golden file, read as FILE@DEVICE (the first device when no
# device is given). --field picks another text field of the clips, such as ruled_text.
#
# A clip of the manifest may list accepted spellings, other ways to write a word of its
# reference that count as right: "accepted": [["km", "킬로미터"]], each list with the form
# in the reference first. The lists among its "expect_terms" count too. A group whose clips
# have such lists also shows a lenient rate, which scores the text with each accepted
# spelling written as the reference writes it. Without lists the two rates are the same.

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
# Then CER over Japanese, WER over Spanish and CER over Korean, for a corpus such as FLEURS
# ja_jp, es_419 and ko_kr, and MER over each of the three mixed with English, for clips with
# lang ja_en, es_en or ko_en.
GROUPS = {
    "wer_en": lambda clip: clip["lang"] == "en" and clip["stratum"] not in ("silence", "noise"),
    "cer_zh": lambda clip: clip["lang"] == "zh",
    "mer_mixed": lambda clip: clip["stratum"] == "mixed",
    "cer_ja": lambda clip: clip["lang"] == "ja",
    "wer_es": lambda clip: clip["lang"] == "es",
    "cer_ko": lambda clip: clip["lang"] == "ko",
    "mer_ja_en": lambda clip: clip["lang"] == "ja_en",
    "mer_es_en": lambda clip: clip["lang"] == "es_en",
    "mer_ko_en": lambda clip: clip["lang"] == "ko_en",
}
# Groups that count only when a run has clips in them, so the speech corpus, which has none,
# scores exactly as before they were added.
LANGUAGE_GROUPS = {"cer_ja", "wer_es", "cer_ko", "mer_ja_en", "mer_es_en", "mer_ko_en"}
STRATA = ["en_short", "en_mid", "en_long", "snr10_en", "zh_short", "zh_numbers", "zh_mid", "zh_long", "snr10_zh", "mixed"]
EMPTY_STRATA = ["silence", "noise"]
# Shown only when a run has clips in them, like LANGUAGE_GROUPS.
LANGUAGE_STRATA = ["ja", "es", "ko"]
# Read speech, by the source of a clip. The rates without digits count these clips only.
READ_SOURCES = ("fleurs", "librispeech")

# Han characters, the marks 々 and 〆, and kana, one token each in Japanese and Spanish. The
# kana blocks also hold the middle dot, the double hyphen and the voicing marks, which stay
# out like punctuation. Escapes, because an editor that normalizes text turns U+F900 into
# U+8C48, and the range would then take in Hangul and other scripts.
HAN_AND_KANA = "\u3005\u3006\u3400-\u9fff\uf900-\ufaff\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fc-\u30ff\u31f0-\u31ff"
# Hangul syllables and jamo, one token each in Korean: the jamo, the compatibility jamo and
# the extended jamo blocks. NFKC comes first, so decomposed syllables count as syllables and
# half width jamo as jamo.
HANGUL = "\uac00-\ud7a3\u1100-\u11ff\u3131-\u318e\ua960-\ua97f\ud7b0-\ud7ff"
# A letter of an alphabet, Latin with or without accents or another, but not Hangul, kana or
# Han, which count one token each. Accepted spellings use it to stay out of longer words.
LETTER = rf"[^\W\d_{HAN_AND_KANA}{HANGUL}]"


def tokens(text: str, lang: str) -> list[str]:
    """English: lower case words of letters, digits and apostrophes. Japanese and Spanish: one
    token per Han character or kana and one per run of other letters and digits, accents
    kept, with apostrophes inside a word, so Japanese counts per character and Spanish per
    word. Korean: the same, and one token per Hangul syllable or jamo, so Korean counts per
    syllable with or without its spaces and an English word in it counts as a word.
    Anything else: one token per CJK character and one per run of ASCII letters, digits and
    apostrophes. NFKC first, so full width digits and letters count as ASCII and decomposed
    Hangul as its syllables. Punctuation is never a token."""
    text = unicodedata.normalize("NFKC", text).lower()
    if lang == "en":
        text = re.sub(r"[^a-z0-9' ]+", " ", text)
        return [token.strip("'") for token in text.split() if token.strip("'")]
    if lang in ("ja", "es", "ko"):
        characters = HAN_AND_KANA + HANGUL if lang == "ko" else HAN_AND_KANA
        found = re.findall(rf"[{characters}]|(?:[^\W_{characters}]|')+", text)
        return [token.strip("'") for token in found if token.strip("'")]
    # The second range starts at U+8C48, the NFC form of U+F900 (see HAN_AND_KANA), so this
    # way also counts Hangul syllables and the other scripts up to U+FAFF one per character.
    # The golden files score the same with U+F900. It stays, so that no stored rate moves.
    return re.findall(r"[㐀-鿿豈-﫿]|[a-z0-9']+", text)


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def output_tokens(text: str) -> list[str]:
    """Tokens of every script, to count output on a clip without speech: one per Han
    character, kana and Hangul syllable or jamo, and one per run of any other letters and
    digits."""
    return tokens(text, "ko")


def scoring_lang(lang: str | None) -> str:
    """How a clip in this language is scored. Japanese, Spanish and Korean mixed with English
    (ja_en, es_en and ko_en) go their language's way, which keeps English words whole.
    Chinese, the code switched clips and anything unknown go the Chinese way."""
    if lang in ("en", "ja", "es", "ko"):
        return lang
    if lang in ("ja_en", "es_en", "ko_en"):
        return lang[:2]
    return "zh"


def accepted_spellings(clip: dict) -> list[list[str]]:
    """The accepted spellings of a clip: the lists in its "accepted" field and the lists
    among its "expect_terms". Each list holds the form written in the reference first, then
    the other spellings that count as right, such as ["km", "킬로미터"]."""
    lists = list(clip.get("accepted") or []) + [term for term in clip.get("expect_terms") or [] if isinstance(term, list)]
    for forms in lists:
        if not isinstance(forms, list) or not forms or not all(isinstance(form, str) for form in forms):
            raise ValueError(f"{clip.get('id')}: accepted spellings must be lists of strings, not {forms!r}")
    return lists


def folded(text: str) -> str:
    return unicodedata.normalize("NFKC", text).lower()


def edge(character: str, before: bool) -> str:
    """What may not stand right before or after a spelling that starts or ends with this
    character: no letter next to a letter of an alphabet (LETTER) and no digit next to a
    digit, so a spelling never takes part of a longer word or number. Nothing for any other
    character, Hangul among them."""
    for kind in (LETTER, r"\d"):
        if re.fullmatch(kind, character):
            return rf"(?<!{kind})" if before else rf"(?!{kind})"
    return ""


def lenient_text(text: str, lists: list[list[str]]) -> str:
    """The text with each accepted spelling in it written as the reference writes it, the
    longest spellings first, so with ["km", "킬로미터"] and ["m", "미터"] the text 5킬로미터
    becomes 5km, not 5킬로m. The form in the reference counts as a spelling too, so no
    shorter spelling replaces part of it. White space inside a spelling is free. A spelling
    never takes part of a longer word or number (see edge), so Slack is not found in Slacker,
    30,000 not in 130,000 and es de 20 not in es de 200, while km is found in 80km. Hangul
    has no such edge, since Korean writes particles right after a word and a missing space
    must not count. The text comes back in NFKC lower case, which tokens() reads the same
    way."""
    text = folded(text)
    spellings = sorted(((spelling, forms[0]) for forms in lists for spelling in forms), key=lambda pair: -len("".join(folded(pair[0]).split())))
    taken = [False] * len(text)
    found = []
    for spelling, form in spellings:
        characters = [character for character in folded(spelling) if not character.isspace()]
        if not characters:
            continue
        pattern = edge(characters[0], True) + r"\s*".join(re.escape(character) for character in characters) + edge(characters[-1], False)
        compiled = re.compile(pattern)
        position = 0
        while match := compiled.search(text, position):
            start, end = match.span()
            if any(taken[start:end]):
                position = start + 1
                continue
            taken[start:end] = [True] * (end - start)
            found.append((start, end, folded(form)))
            position = end
    for start, end, form in sorted(found, reverse=True):
        text = text[:start] + form + text[end:]
    return text


def clip_errors(clip: dict, text: str, lenient: bool = False) -> tuple[int, int]:
    """Errors and reference tokens of one clip. Lenient scores the text with the clip's
    accepted spellings written as the reference writes them."""
    lang = scoring_lang(clip["lang"])
    reference = tokens(clip["reference"], lang)
    lists = accepted_spellings(clip) if lenient else []
    if lists:
        text = lenient_text(text, lists)
    return edit_distance(reference, tokens(text, lang)), len(reference)


def read_without_digits(clip: dict) -> bool:
    """Whether a clip is read speech, from FLEURS or LibriSpeech, whose reference holds no
    digit. Digits never match the words a reader may say for them, nor the words a model may
    write, so the rate without digits leaves such clips out."""
    return str(clip.get("source", "")).startswith(READ_SOURCES) and not re.search(r"\d", unicodedata.normalize("NFKC", clip["reference"]))


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
    # Timing reads the time of the pass that wrote the field when the run holds one, such as
    # decode_seconds_japanese for text_japanese, and decode_seconds otherwise.
    seconds = "decode_seconds" + field[len("text"):] if field.startswith("text_") else "decode_seconds"
    return label, {clip_id: {**row, "text": row[field], **({"decode_seconds": row[seconds]} if seconds in row else {})} for clip_id, row in clips.items()}


def metrics(manifest: dict[str, dict], texts: dict[str, str], lenient: bool = False) -> dict[str, float]:
    """Voxt's three error rates, rounded as Voxt rounds them, and the Japanese and Spanish
    ones, and the Korean and mixed ones, when the run has such clips. Lenient scores with the
    accepted spellings."""
    result = {}
    for name, keep in GROUPS.items():
        errors = total = 0
        for clip_id, text in texts.items():
            clip = manifest[clip_id]
            if keep(clip):
                found, count = clip_errors(clip, text, lenient)
                errors += found
                total += count
        if total or name not in LANGUAGE_GROUPS:
            result[name] = round(errors / total, 5) if total else 0.0
    return result


def without_digits(manifest: dict[str, dict], texts: dict[str, str], lenient: bool = False) -> dict[str, tuple[float, int]]:
    """Each group's error rate, rounded as metrics() rounds, and clip count over its read
    speech without digits (read_without_digits). A group without such clips, such as
    mer_mixed, which is spontaneous speech, is left out."""
    result = {}
    for name, keep in GROUPS.items():
        errors = total = clips = 0
        for clip_id, text in texts.items():
            clip = manifest[clip_id]
            if keep(clip) and read_without_digits(clip):
                found, count = clip_errors(clip, text, lenient)
                errors, total, clips = errors + found, total + count, clips + 1
        if clips:
            result[name] = (round(errors / total, 5) if total else 0.0, clips)
    return result


def strata(manifest: dict[str, dict], texts: dict[str, str]) -> dict[str, tuple[float, int]]:
    """Error rate and clip count per stratum. Silence and noise give the number of clips
    with any output in any script instead, since they have no reference."""
    result = {}
    for stratum in STRATA + LANGUAGE_STRATA:
        errors = total = clips = 0
        for clip_id, text in texts.items():
            if manifest[clip_id]["stratum"] == stratum:
                found, count = clip_errors(manifest[clip_id], text)
                errors, total, clips = errors + found, total + count, clips + 1
        if clips or stratum not in LANGUAGE_STRATA:
            result[stratum] = (errors / total if total else 0.0, clips)
    for stratum in EMPTY_STRATA:
        ids = [clip_id for clip_id in texts if manifest[clip_id]["stratum"] == stratum]
        result[stratum] = (sum(1 for clip_id in ids if output_tokens(texts[clip_id])), len(ids))
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
    # A group or stratum without clips in any run, such as cer_zh for a run of Spanish clips,
    # is left out, and a run without clips in it shows n/a. Below each group, its lenient
    # rate when its clips have accepted spellings, and its rate on read speech without digits
    # when it has such clips.
    all_metrics = [metrics(manifest, run) for run in texts]
    with_lists = {name for name, keep in GROUPS.items() if any(keep(manifest[clip_id]) and accepted_spellings(manifest[clip_id]) for run in texts for clip_id in run)}
    all_lenient = [metrics(manifest, run, lenient=True) for run in texts] if with_lists else []
    all_read = [without_digits(manifest, run) for run in texts]
    all_read_lenient = [without_digits(manifest, run, lenient=True) for run in texts] if with_lists else []
    for name, keep in GROUPS.items():
        present = [name in m and any(keep(manifest[clip_id]) for clip_id in run) for m, run in zip(all_metrics, texts)]
        if not any(present):
            continue
        lines.append(f"| {name} | " + " | ".join(f"{m[name]:.2%}" if has else "n/a" for m, has in zip(all_metrics, present)) + " |")
        if name in with_lists:
            lines.append(f"| {name}, lenient | " + " | ".join(f"{m[name]:.2%}" if has else "n/a" for m, has in zip(all_lenient, present)) + " |")
        counts = [rates[name][1] if name in rates else 0 for rates in all_read]
        if any(counts):
            count = next(filter(None, counts))
            for title, runs_rates in [("", all_read)] + ([(", lenient", all_read_lenient)] if name in with_lists else []):
                lines.append(f"| {name}, read speech without digits{title} ({count}) | " + " | ".join(f"{rates[name][0]:.2%}" if name in rates else "n/a" for rates in runs_rates) + " |")
    all_strata = [strata(manifest, run) for run in texts]
    for stratum in STRATA + LANGUAGE_STRATA + EMPTY_STRATA:
        counts = [s[stratum][1] if stratum in s else 0 for s in all_strata]
        if not any(counts):
            continue
        count = next(filter(None, counts))
        if stratum in EMPTY_STRATA:
            lines.append(f"| {stratum}, clips with output (of {count}) | " + " | ".join(str(s[stratum][0]) if clips else "n/a" for s, clips in zip(all_strata, counts)) + " |")
        else:
            lines.append(f"| {stratum} ({count}) | " + " | ".join(f"{s[stratum][0]:.2%}" if clips else "n/a" for s, clips in zip(all_strata, counts)) + " |")
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
            a, b, total = len(output_tokens(a_text)), len(output_tokens(b_text)), 0
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
