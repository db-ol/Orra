# Public ASR baseline

Run on 2026-10-04 on an Apple M5 Pro with 48 GB of memory, macOS 26.6.2, with the scripts
in Tools/asr-eval. It compares the candidates from docs/local-asr-models.md on public
test sets before the maintainer records their own voice. The sections What was run,
Accuracy, Speed and memory, Findings and Limits come from this run. Inside Orra was
measured on 2026-10-05 with Orra's own tests and a scratch benchmark.

## What was run

Test sets, 200 clips each:

| Set | Source | License | Audio | Kind |
|---|---|---|---|---|
| FLEURS Chinese | `google/fleurs`, cmn_hans_cn test, first 200 files by name | CC BY 4.0 | 2313 s | Read sentences |
| FLEURS English | `google/fleurs`, en_us test, first 200 files by name | CC BY 4.0 | 1917 s | Read sentences |
| ASCEND mixed | `CAiRE/ASCEND` test, rows labeled mixed, first 200 by id | CC BY-SA 4.0 | 825 s | Conversational Mandarin and English code switching |

Engines: Qwen3-ASR through the Homebrew `speech` 0.0.28 tool (speech-swift on MLX),
X-ASR, SenseVoice and Fun-ASR-Nano through sherpa-onnx 1.13.8 on 2 CPU threads, and
Apple SpeechAnalyzer with SpeechTranscriber (zh_CN for Chinese and mixed, en_US for
English). Qwen3-ASR ran with no language hint ("auto") and with the hint "Chinese".
The scoring rules are in Tools/asr-eval/README.md.

## Accuracy

Capped error in percent, lower is better. "Failures" counts whole mixed clips that went
wrong: Chinese turned into English, English dropped, a loop, or empty output.

| Engine | Chinese | Chinese, clean refs | English | Mixed | English words kept in mixed | Failures in mixed |
|---|---|---|---|---|---|---|
| Qwen3-ASR 1.7B, auto | 3.7 | 1.7 | 3.6 | 9.5 | 84.7% | 3 |
| Qwen3-ASR 1.7B, Chinese hint | 3.7 | 1.8 | not run | 9.5 | 83.7% | 4 |
| Qwen3-ASR 0.6B 8 bit, auto | 4.5 | 2.1 | 5.1 | 11.7 | 79.2% | 8 |
| Qwen3-ASR 0.6B 4 bit, auto | 5.4 | 2.6 | 6.0 | 12.7 | 76.9% | 10 |
| Qwen3-ASR 0.6B 4 bit, Chinese hint | 4.9 | 2.3 | 13.9 | 13.6 | 70.4% | 15 |
| Fun-ASR-Nano | 5.0 | 2.2 | 5.5 | 11.8 | 76.9% | 7 |
| X-ASR | 6.3 | 3.1 | 9.0 | 11.3 | 79.9% | 9 |
| SenseVoice | 5.2 | 3.9 | 7.8 | 14.2 | 63.5% | 6 |
| Apple SpeechAnalyzer | 6.3 | 4.6 | 7.4 | 18.6 | 35.8% | 3 |

## Speed and memory

One dictation per process on 30 clips, 15 Chinese clips of 8 to 12 s and 15 mixed clips of
2 to 6 s. Times exclude loading. Apple runs the model in a system process, so it is not in
this table.

| Engine | 8 to 12 s, median | 8 to 12 s, worst | 2 to 6 s, median | 2 to 6 s, worst | Load | Peak memory |
|---|---|---|---|---|---|---|
| Qwen3-ASR 0.6B 4 bit | 0.08 s | 0.14 s | 0.04 s | 0.20 s | 0.89 s | 2.31 GB |
| Qwen3-ASR 0.6B 8 bit | 0.11 s | 0.17 s | 0.05 s | 0.09 s | 0.96 s | 2.61 GB |
| Qwen3-ASR 1.7B 8 bit | 0.22 s | 0.37 s | 0.12 s | 0.19 s | 1.05 s | 4.45 GB |
| X-ASR | 0.11 s | 0.13 s | 0.04 s | 0.06 s | 0.92 s | 0.70 GB |
| SenseVoice | 0.16 s | 0.19 s | 0.05 s | 0.08 s | 0.28 s | 0.58 GB |
| Fun-ASR-Nano | 0.61 s | 1.02 s | 0.22 s | 0.37 s | 1.17 s | 2.49 GB |

## Inside Orra

Measured on 2026-10-05 by OrraTests/Qwen3EngineTests, which runs Orra's own engine
(speech-swift 1f54e56, mlx-swift 0.31.6) in a Debug build on the same Mac. Four runs, each
with the same 10 clips and then 10 more fleurs_zh clips. Each run attaches its numbers to
the test result as qwen3-measurements.txt. The tests score with TranscriptScoring in
OrraTests/TestSupport.swift, which does not join letters spelled one by one the way
score.py does, so the baseline reads 3.73% (fleurs_en) and 9.97% (ascend_mixed) there,
against 3.6 and 9.5 in the table above.

- Accuracy: 14 errors in 214 tokens (6.5%) in every run, against 25 (11.7%) for the
  baseline on the same 10 clips. 12 of the baseline's errors come from one fleurs_zh clip
  where it wrote the five numbers as Chinese numerals (十五, 二零一一 and so on) while the
  reference uses digits, as Orra did. Without that clip the two differ by one error, 14
  against 13. The test now gates on Orra's own 14, not on the baseline.
- Speed: clips of 8 to 15 s took 0.26 to 0.64 s, median 0.35 s over the 35 dictations
  whose clip length was logged, and clips of 1 to 4 s took 0.10 to 0.18 s, median 0.12 s
  over 20. Of the 70 dictations whose times were logged, these ranges leave out three
  stalls: 3.45 s for a clip that usually took 0.18 s, 1.04 s for one that usually took
  0.10 s, and 1.03 s for one that usually took 0.63 s. The 8 to 15 s figures are slower
  than the release build of the command line tool above, 0.22 s median for 8 to 12 s. A
  Debug build compiles the MLX core without optimization.
- Load: 0.43 to 1.49 s, and memory right after loading was 115 to 128 MB, because MLX
  reads the weights on first use. The first dictation brought it to 3.2 to 3.3 GB. Since
  commit 1c2b22f Orra transcribes one second of silence right after loading, so memory is
  about 3 GB from the start. Loading with the warm up took 0.52 and 0.60 s in test runs,
  measured after other real model tests in the same process, not at a cold launch. In a
  scratch benchmark, the first launch of a program with a freshly compiled MLX Metal
  library took 2.14 and 1.97 s for its first transcription, and a second launch of the
  same program 0.28 and 0.54 s. That is probably Metal compiling GPU programs on first
  use, inferred and not measured. An Orra rebuild that did not recompile the Metal library
  did not show it. The warm up moves any such cost to the launch.
- Memory: 3.5 to 3.9 GB after 20 dictations. The speech-swift author measured 3.86 GiB
  (4.1 GB) for this model after 30 requests with the cache fix.

OrraTests/DictationQualityTests added these checks on the same day, also in a Debug build
unless the line says otherwise:

- All 600 clips through the engine and the same cleanup the app applies before pasting
  (the loop guard and the traditional to simplified conversion): fleurs_zh 3.08% against
  3.73% for the baseline, fleurs_en 3.63% against 3.73%, ascend_mixed 9.71% against 9.97%,
  all scored by TranscriptScoring. Every difference is under 1 point, which is within noise
  for 200 clips, so Orra with its cleanup matches the baseline. This check runs only when
  asked for, see the test file.
- Holds without speech: silence of 0.4 to 10 s, white noise at -60 to -35 dBFS RMS and a
  50 Hz hum at -30 dBFS RMS give no text. With 3 s of silence or of -45 dBFS RMS noise
  before or after the speech, the result changed by one token at most on the 4 clips
  checked. On one clip compared by hand, 3 s of silence before or after and 3 s of quieter
  noise (-50 dBFS RMS) after the speech gave identical text. The evaluation clips
  themselves range from -69.5 dBFS RMS (fleurs_en) to a median of -20 dBFS RMS
  (ascend_mixed), so a loudness gate would drop real speech, and Orra has none.
- Audio at 48 kHz through the whole controller, with the microphone and the paste faked:
  the same errors as feeding the model 16 kHz directly, and at most one token different.
  From release to the text being handed over took 0.26 to 0.37 s for 8 to 11 s of speech
  and 0.12 to 0.19 s for 1 to 4 s, without the 150 ms tail that real recording adds.
- Long dictation: 57 s of Chinese in 1.96 s (1.41 s in a Release build) with 1.1% error,
  against 1.7% for the same clips one by one. 28 s of mixed speech in 1.04 s (0.73 s) with
  17.4%, against 22.1%.
- Release against Debug, 200 dictations back to back per run, alternating: median 0.27 s
  against 0.34 to 0.39 s, about a quarter less time, and the fastest quarter at 0.21 s
  against 0.28 to 0.30 s. The tests use @testable import, so the Release runs were built
  with testability on: `TEST_RUNNER_ORRA_SOAK=1 xcodebuild -project Orra.xcodeproj
  -scheme Orra -configuration Release ENABLE_TESTABILITY=YES -destination
  'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test -only-testing:<test>`.
- Memory over 200 dictations moves between 3.1 and 4.9 GB with no upward trend. Single
  readings swing by more than 1 GB with the clip, so the tests compare medians.
- Stalls: in the four alternating runs, 6 to 15 of 200 dictations took over 1 s, the
  worst 2.1 to 6.3 s, and a later Debug run had a worst of 4.3 s. An earlier Debug run on
  its own had none over 1 s, the worst 0.88 s. A Release build probe outside the
  repository, with a 2 s pause before each dictation, had 5 and 4 of 60 over 1 s, the
  worst 9.8 and 16 s. The 16 s run had the user initiated activity of commit 3576211 on.
  The stalls were not tied to particular clips, since the same clip was fast in other
  rounds, and they came in clusters. Xcode was indexing the new packages through all of
  these runs at about 70% of a core, and swap held 4.5 GB.
- Removing the cache clearing did not remove the stalls. speech-swift clears MLX's buffer
  cache after every transcription (generateText in Qwen3ASR.swift), and the quiet run
  above cleared it too. A scratch benchmark built speech-swift with and without that call,
  Release, 60 dictations with 2 s pauses, two runs each, alternating. Not counting the
  first transcription of each new build, 5 of 118 dictations took over 1 s with the call
  and 1 of 118 without it, too few to say either way. The worst were 2.1 and 2.0 s with it
  and 2.4 s without it, while memory rose to 7.0 GB without it against 4.6 GB with it. The
  cause is still unknown. Daily use on a quiet Mac will show whether the stalls matter,
  see the timing check in docs/manual-testing.md.

## Findings

- Qwen3-ASR 1.7B is the most accurate on all three sets and the steadiest on mixed speech.
- Qwen3-ASR 0.6B 8 bit beats the 4 bit build on every set, for about 300 MB more download.
  The 4 bit build looped once on an English clip.
- A fixed Chinese hint hurts. With it, the 0.6B dropped English on 15 mixed clips, mostly
  by translating it into Chinese and once in a loop that repeated 非常 hundreds of times,
  and its English error rose from 6.0 to 13.9.
  With no hint it turned Chinese into English on 4 mixed clips instead. The 1.7B behaved
  much the same in both modes.
- X-ASR uses the least memory and does well on mixed speech, but it is the weakest small
  model on Chinese and English, turned 8 short mixed clips into English, and ended only
  75% of mixed outputs with a punctuation mark.
- Fun-ASR-Nano is accurate but the slowest, up to 1.02 s for a 10 s clip on this Mac, and
  wrote one mixed clip in traditional characters.
- SenseVoice and Apple SpeechAnalyzer handle one language well but lose many English words
  in mixed speech.
- Memory grows in a long running process with `speech` 0.0.28. One dictation with the 0.6B
  peaks at 2.3 to 2.6 GB, but 200 dictations in one process reached 14 to 15.6 GB. That is
  the unbounded MLX buffer cache fixed on speech-swift main on 2026-10-03, so Orra must use
  that fix or cap the MLX cache itself.
- On this M5 Pro every engine stays far under 1 s for a 10 s clip, except Fun-ASR-Nano at
  its worst.

## Limits

- Read speech and Hong Kong conversational speech, not the maintainer's voice, mic or
  developer jargon.
- Timed on an M5 Pro only. An 8 GB M1 is still unmeasured.
- With 200 clips per set, differences under about 1 point are within noise. Inferred.
- Number formatting is penalized: "2011" against "二零一一" counts as errors, which the
  clean refs column removes.
- Loading the model through speech-swift raises MLX's wired limit, so the model's buffers
  stay wired while Orra runs. Read from the source, not measured. On 48 GB this is no
  concern, but on an 8 or 16 GB Mac other apps would page instead of Orra.
- The sherpa-onnx batch runs load all 200 files at once, so their batch memory and speed
  figures are not meaningful. The speed table above runs one file per process instead.
