# Speaks every sentence of sentences.jsonl with macOS `say` into a folder outside the
# repository, as 16 kHz mono WAV, with a manifest.jsonl in the format of the speech corpus,
# so OrraTests/SpeechCorpusEvaluationTests can run on it.
#
#     python3 Tools/terms-eval/build_clips.py ~/projects/orra-project/bench/terms-eval
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
STRATUM = {"en": "en_short", "zh": "zh_short", "mixed": "mixed"}


def main(folder: Path) -> None:
    clips = folder / "clips"
    clips.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(line) for line in (HERE / "sentences.jsonl").read_text(encoding="utf-8").splitlines()]
    manifest = []
    with tempfile.TemporaryDirectory() as temporary:
        for row in rows:
            aiff = Path(temporary) / f"{row['id']}.aiff"
            wav = clips / f"{row['id']}.wav"
            subprocess.run(["say", "-v", row["voice"], "-o", str(aiff), row.get("say", row["reference"])], check=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
            info = subprocess.run(["afinfo", str(wav)], check=True, capture_output=True, text=True).stdout
            duration = float(next(line.split()[-2] for line in info.splitlines() if "estimated duration" in line))
            manifest.append({"id": row["id"], "stratum": STRATUM[row["lang"]], "lang": row["lang"],
                             "source": "say", "duration": duration, "reference": row["reference"]})
    (folder / "manifest.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in manifest), encoding="utf-8")
    print(len(manifest), "clips,", round(sum(row["duration"] for row in manifest), 1), "s")


if __name__ == "__main__":
    main(Path(sys.argv[1]).expanduser())
