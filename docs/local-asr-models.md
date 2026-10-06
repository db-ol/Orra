# Local ASR models for Orra

On 2026-10-03 the maintainer decided that Orra should transcribe with a new, strong,
small model that runs entirely on the Mac, so dictation works with no network. This
note picks the model and the Swift runtime. It was researched on 2026-10-03 and
2026-10-04 and replaces the model comparison in docs/asr-options.md, which was written
before that decision. Nothing was installed or downloaded, and nothing was added to the
project.

How to read it: "measured" is a benchmark number from a paper, model card or test run,
"stated" is a direct statement from a source, and "inferred" is our own reasoning.
Vendor numbers for Chinese often do not reproduce in independent runs, so the choice
leans on same harness comparisons and on a test with the maintainer's own voice. The
figures come from a research run in which a separate agent checked every claim against
its source. The ones behind the recommendation were checked again on 2026-10-04.

## Requirements

- Runs inside the Swift app or a library it links, with no Python and no server.
- Mandarin, English, and both mixed in one sentence, with punctuation.
- A weights license that allows redistribution and commercial use.
- An M1 or later Mac with 8 to 16 GB of RAM, under about 1 second for a 10 second clip.

## Recommendation

**Default: Qwen3-ASR-0.6B** (Alibaba Qwen, released 2026-01-29) in the MLX 4 bit build
`aufklarer/Qwen3-ASR-0.6B-MLX-4bit` (712,779,703 bytes, Apache-2.0), run in process on
the GPU through MLX Swift with the `Qwen3ASR` library from `soniqo/speech-swift`
(Apache-2.0). Load it once with `offlineMode: true`, keep it warm, and transcribe off
the main actor after fn is released. [1][2][3]

Why:

- Best independent Mandarin result of any model that fits 8 GB. In transcribe.cpp's
  same harness run on FLEURS zh (945 utterances, Q8_0, catalog of 2026-10-03) it has
  CER 7.57, second of 18 after Qwen3-ASR-1.7B (7.14), ahead of whisper-large-v3-turbo
  (8.50), Fun-ASR-Nano (8.59) and SenseVoice (10.12). Measured. [4]
- Measured on real Mandarin and English code switching by a third party in one
  protocol: ASCEND MER 12.54 and CSZS 16.03, against 19.61 and 23.24 for
  Whisper-large-v3. [5]
- Punctuated, cased text in one pass, so no separate punctuation model. [1]
- Apache-2.0 for code and weights. [6]
- Fast on Apple Silicon. The package author's probe on an M5 Pro averaged 128 ms per
  request over 30 requests of mixed length, and the fix merged on 2026-10-03 cut the
  final memory footprint from 7.04 GiB to 1.75 GiB. Measured, by the package author.
  [3]
- The same package runs Qwen3-ASR-1.7B, so a more accurate tier needs no new
  dependency. [2]

Risks:

- Mixed speech can flip to one language. In issue 16 a clip that starts in Chinese and
  turns to English came out entirely in English with no language hint, and with the
  hint set to Chinese the English was translated into Chinese. In issue 163 users
  disagree on whether the Chinese hint or no hint works better. [7][8]
- Prompt words can leak into the transcript, reported in open issue 186. [9]
- Nobody has measured it on a real 8 GB M1 through Swift, so under 1 second there is not
  established.
- speech-swift is before version 1.0. The memory fix is only on main, merged as commit
  1f54e56, and not in the latest tag v0.0.28. Its manifest declares 11 packages,
  including the hummingbird web server, WhisperKit and an MCP SDK, although the
  Qwen3ASR target needs far fewer. [2][3]
- The Hugging Face weight repos carry only a license tag, so Orra must ship the
  Apache-2.0 text from the Qwen3-ASR GitHub repository. [6]

**Runner up: X-ASR-zh-en** (SJTU, SII, Fudan and HUST, May 2026), a 0.16B Zipformer
transducer built for Chinese and English mixed in one utterance. The int8 export with
punctuation is 136,396,739 bytes, Apache-2.0, and runs on the CPU through
`k2-fsa/sherpa-onnx` 1.13.8 and its Swift wrapper. [10][11][12]

- The sherpa-onnx change that added it decoded a 10.053 second clip in 0.121 seconds on
  2 CPU threads on a Mac whose chip is not named. Measured. [12]
- A transducer takes no language hint and no prompt, so the flip and leak failures of
  Qwen3-ASR do not apply in the same way. Inferred.
- In the authors' own table it is level with Qwen3-ASR-0.6B on Chinese (WenetSpeech
  net 5.83 and meeting 7.06, against 5.97 and 6.88). These are the authors' numbers
  only, with no independent run and no code switching metric. [11]
- sherpa-onnx pulls `csukuangfj/onnxruntime-libs`, whose repository has no license
  file. The ONNX Runtime terms need a check before shipping. [13]

**Optional tier: Qwen3-ASR-1.7B** in the MLX 8 bit build (2,467,857,518 bytes), for
Macs with 16 GB or more, and only if it clearly beats the 0.6B on the maintainer's
clips. It has the best measured code switching here, ASCEND 10.57 and CSZS 11.03 in
the same third party run, and FLEURS zh CER 7.14. [4][5] The package author measured
282 ms per request on an M5 Pro, so an M1 is likely over 1 second. Inferred from [3].

## Decision

On 2026-10-04 the maintainer chose to build with Qwen3-ASR 1.7B in the 8 bit MLX build
only for now. It was the most accurate on every set in docs/asr-baseline.md and fits the
maintainer's Mac easily. Qwen3-ASR 0.6B 8 bit stays the option for Macs with less memory
later. Orra runs it through speech-swift, see docs/dependencies.md.

## Update after the public baseline

docs/asr-baseline.md tested these engines on public Chinese, English and mixed speech on
2026-10-04. It changes three things, pending the maintainer's own recordings:

- The default candidate becomes Qwen3-ASR-0.6B in the 8 bit build (1,010,773,983 bytes).
  It beat the 4 bit build on every set and did not loop.
- Orra should not send a fixed language hint. The Chinese hint dropped or translated
  English on 15 of 200 mixed clips.
- Qwen3-ASR-1.7B was the most accurate everywhere and stayed under 0.4 s per 10 s clip on
  an M5 Pro, so it is a strong option for Macs with 16 GB or more.

## Ranking

| Model | Size | Download | Chinese, same harness | Mixed zh and en | Swift path | License | Verdict |
|---|---|---|---|---|---|---|---|
| Qwen3-ASR-0.6B | 0.94B | 713 MB, MLX 4 bit | FLEURS zh CER 7.57 [4] | ASCEND 12.54, CSZS 16.03 [5] | speech-swift, MLX on GPU | Apache-2.0 | Default |
| X-ASR-zh-en | 0.16B | 136 MB, int8 | not measured, authors only [11] | built for it, no metric | sherpa-onnx, CPU | Apache-2.0 | Runner up |
| Qwen3-ASR-1.7B | 2.35B | 2.47 GB, MLX 8 bit | FLEURS zh CER 7.14 [4] | ASCEND 10.57, CSZS 11.03 [5] | speech-swift, MLX on GPU | Apache-2.0 | Optional tier |
| Fun-ASR-Nano-2512 | 0.83B | 842 MB, int8 | FLEURS zh CER 8.59 [4] | best of four small models, CER 11.23 [14] | sherpa-onnx CPU, 1.4 to 1.9 s per 10 s [17] | Apache-2.0 on the current card, older files differ [16] | Reference only |
| SenseVoice-Small | 0.23B | 163 MB, int8 | FLEURS zh CER 10.12 [4] | weakest of four small models, CER 13.90 [14] | FluidAudio, Core ML | FunASR Model License, commercial use not confirmed [18] | Ruled out |
| Apple SpeechAnalyzer | not published | system asset | no published numbers | one locale per transcriber | Speech framework, macOS 26 only | system | Baseline only [15] |

Also checked and dropped: FireRedASR2-AED (strong self reported Mandarin, but over 1
second in every Mac measurement and no punctuation of its own) [19] and
GLM-ASR-Nano-2512 (larger, slower and weaker on Mandarin than Qwen3-ASR-0.6B) [14][20].
The reasons for the models below come from the research run and were not checked
again. Dropped earlier for lacking Chinese: NVIDIA Parakeet and Canary, Voxtral Mini 3B and IBM Granite Speech. For weak
Mandarin or translating mixed speech: the Whisper family including large-v3-turbo,
Cohere Transcribe and general audio LLMs such as Qwen3-Omni. For size: models over
about 3B such as Kimi-Audio, MiMo-Audio and FireRedASR2-LLM. For licenses: Audio8-ASR
and X-AuT (non commercial). Cloud only services were out of scope.

## Before choosing: a test with the maintainer's own voice

No benchmark matches developer dictation that mixes Chinese and English, so the choice
between Qwen3-ASR-0.6B and X-ASR should come from the maintainer's own recordings.

1. Record about 30 to 80 clips with the usual mic and room. Mostly mixed sentences such
   as "这个 PR 先 merge 一下，然后跑一下 test。", plus some Mandarin with numbers and
   names, some English, a few short clips of 1 to 3 seconds, a few long clips of 20 to
   30 seconds, and a few near silent clips that should give no text. Write each
   reference exactly as it should be typed.
2. Convert each clip to 16 kHz mono WAV with the built in `afconvert`.
3. Run Qwen3-ASR 0.6B (4 bit and 8 bit) and 1.7B through the `speech` command line tool
   from speech-swift, once with no language hint and once with Chinese. Run X-ASR,
   Fun-ASR-Nano and SenseVoice through the sherpa-onnx command line tool. Run Apple
   SpeechAnalyzer through a short Swift script as a baseline.
4. Score mixed error rate overall and on the mixed clips, how many English terms
   survive, whole clip failures (a language flip, a translation, a loop, or any text on
   a silent clip), punctuation, latency at p50 and p95, and peak memory footprint from
   `/usr/bin/time -l`.
5. Rerun one batch per engine with networking off, to confirm nothing reaches out.
6. If possible, time the top two on an 8 GB M1 running macOS 15.6.
7. Adopt the winner on a branch: add the package, load the model at launch off the main
   actor, transcribe after fn is released, and measure memory over ten dictations in a
   row.

## Approvals needed

For the test, with Orra untouched:

- Install the Homebrew formula `speech` 0.0.28 and download the sherpa-onnx 1.13.8
  command line tool for arm64 macOS (18,252,168 bytes).
- Download about 5.3 GB of model files, plus Apple's zh_CN speech asset of unknown size.

To ship the winner:

- Orra's first Swift package. For Qwen3-ASR the options are speech-swift itself (pinned
  to commit 1f54e56, with its large dependency graph), a small local package that
  carries only its Apache-2.0 Qwen3ASR sources on top of mlx-swift and
  swift-transformers, or `Blaizzy/mlx-audio-swift` (MIT). For X-ASR it is
  `k2-fsa/sherpa-onnx` 1.13.8.
- How the model reaches the Mac: a one time download from Hugging Face, or bundling it
  so Orra works offline from the first launch, which makes the app about 713 MB larger.

## Unknowns

- Speed and memory on a real 8 to 16 GB M1 or M2, including the first load.
- Accuracy on the maintainer's own mixed speech, and how often Qwen3-ASR flips language.
- X-ASR accuracy outside its authors' own tests.
- Apple SpeechAnalyzer accuracy for Chinese, its latency and its asset size.
- Whether the chosen package builds cleanly under Orra's Swift 6 settings with default
  main actor isolation.

## Sources

1. Qwen3-ASR-0.6B model card: https://huggingface.co/Qwen/Qwen3-ASR-0.6B
2. speech-swift repository, README and Package.swift (macOS 15.0, 11 package dependencies on main): https://github.com/soniqo/speech-swift
3. speech-swift pull request 498, "Bound Qwen3-ASR buffer cache and preserve shared limits", merged on 2026-10-03 as 1f54e56, with the M5 Pro probe: https://github.com/soniqo/speech-swift/pull/498
4. transcribe.cpp model catalog for Chinese, from one FLEURS zh run with the same harness: https://models.handy.computer/languages/zh and https://github.com/handy-computer/transcribe.cpp/releases/tag/v0.3.0
5. TEA-ASR-1.1 model card, MER table from one self measured protocol (ASCEND and CSZS): https://huggingface.co/JacobLinCool/TEA-ASR-1.1
6. Qwen3-ASR repository with LICENSE, and the technical report: https://github.com/QwenLM/Qwen3-ASR and https://arxiv.org/abs/2601.21337
7. Qwen3-ASR issue 16, mixed Chinese and English: https://github.com/QwenLM/Qwen3-ASR/issues/16
8. Qwen3-ASR issue 163, mixed speech recognized as English: https://github.com/QwenLM/Qwen3-ASR/issues/163
9. Qwen3-ASR issue 186, prompts and hotwords: https://github.com/QwenLM/Qwen3-ASR/issues/186
10. X-ASR-zh-en model card: https://huggingface.co/GilgameshWind/X-ASR-zh-en
11. X-ASR repository with the current benchmark table: https://github.com/Gilgamesh-J/X-ASR
12. sherpa-onnx pull request 3662, "Export X-ASR models to sherpa-onnx", merged on 2026-06-05: https://github.com/k2-fsa/sherpa-onnx/pull/3662
13. sherpa-onnx Package.swift at v1.13.8: https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/Package.swift
14. MOSS-Audio report, code switching comparison of small models: https://arxiv.org/abs/2606.01802
15. Apple SpeechAnalyzer documentation: https://developer.apple.com/documentation/speech/speechanalyzer
16. Fun-ASR-Nano-2512 model card: https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512
17. sherpa-onnx Fun-ASR-Nano page with Mac timing logs: https://k2-fsa.github.io/sherpa/onnx/funasr-nano/pretrained.html
18. SenseVoice issue 334 on commercial use of the weights: https://github.com/QwenAudio/SenseVoice/issues/334
19. FireRedASR2S repository: https://github.com/FireRedTeam/FireRedASR2S
20. GLM-ASR-Nano-2512 model card: https://huggingface.co/zai-org/GLM-ASR-Nano-2512
