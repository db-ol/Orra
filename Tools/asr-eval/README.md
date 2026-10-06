# ASR evaluation tools

Scripts that compare speech recognition engines for Orra, first on public test sets and
later on the maintainer's own recordings. Nothing here is part of the app build. Data,
models and results live outside the repository, in `ORRA_EVAL_DIR`, which defaults to
`~/projects/orra-project/eval`. Results of the first run are in docs/asr-baseline.md.

Requirements: macOS 26 or later for the Apple baseline, Homebrew for the `speech`
command line tool, the built in `afconvert` and `afinfo`, and `/usr/bin/python3` with no
extra packages.

## Steps

1. `./download.sh` installs the Homebrew formula `speech` 0.0.28 and downloads the
   sherpa-onnx 1.13.8 command line tool, three sherpa-onnx models (X-ASR, SenseVoice,
   Fun-ASR-Nano) and the FLEURS Chinese, FLEURS English and ASCEND test sets. About
   2.4 GB. The `speech` tool fetches the Qwen3-ASR weights on first use, about 4.2 GB
   for the three builds.
2. `python3 prep.py` builds `sets/fleurs_zh`, `sets/fleurs_en` and `sets/ascend_mixed`,
   200 clips each as 16 kHz mono WAV, with a `refs.tsv` per set.
3. `./run_all.sh` runs every engine on every set, one at a time, into `results/`.
4. `python3 score.py` prints the tables and writes `results/<engine>.<set>.scored.tsv`,
   worst clips first, for reading the failures.
5. `./bench.sh`, then `python3 bench_report.py`, times one dictation per process on 30
   clips, the way one fn release would run.

## Scoring rules

- Punctuation is removed and case is folded. Chinese counts per character, English per
  word, and acronyms spelled letter by letter ("i s m") count as one word.
- For ASCEND, fillers such as 呃 and 嗯 and the `[UNK]` marker are removed on both sides.
- "Capped error" counts at most the reference length of errors per clip, so one runaway
  clip cannot dominate a set.
- "Clean refs" leaves out references with digits, because "2011" and "二零一一" are the
  same speech. For FLEURS Chinese it also leaves out references with Latin letters,
  because they keep English names in parentheses that the speakers do not read.
- For sets whose name contains `mixed`, the score also counts whole clip failures:
  Chinese that came out as English, English that disappeared (usually translated into
  Chinese), loops, and empty output, plus how many English words were kept.
- "Traditional" counts outputs with traditional Chinese characters.

## Adding your own recordings

1. Convert each recording: `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a out.wav`.
2. Put the WAV files in a folder under `sets/`, for example `sets/aaron_mixed`, with a
   `refs.tsv` of lines `file.wav<TAB>text exactly as it should be typed`.
3. Run `SETS="aaron_mixed" ./run_all.sh`, then `python3 score.py aaron_mixed`.
