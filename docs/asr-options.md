# Local ASR options for Orra

Superseded on 2026-10-04 by docs/local-asr-models.md, written after the maintainer
chose a small model that runs entirely on the Mac. One correction to this note:
Qwen3-ASR does not need a Python server. It runs in process from Swift through
speech-swift, mlx-audio-swift or sherpa-onnx. The rest is kept for the record.

Research note, no code. Compares four ways to turn Orra's recorded audio into text:
FluidAudio with Parakeet, WhisperKit, Apple's SpeechAnalyzer, and Qwen3-ASR served
through an SGLang-Omni compatible endpoint. Written on 2026-10-02 against the versions
linked in the sources. Every factual claim carries a source number. Anything I could
not confirm is marked "unverified". Nothing was installed and no model was downloaded.

Context that applies to all options: Orra's deployment target is macOS 15.6 and the
build is Apple Silicon first (see project settings and AGENTS.md). Adding any Swift
package needs the maintainer's approval.

## Summary table

| | FluidAudio with Parakeet | WhisperKit | Apple SpeechAnalyzer | Qwen3-ASR via SGLang-Omni |
|---|---|---|---|---|
| Mandarin | Not with Parakeet. FluidAudio ships SenseVoice and Paraformer for Mandarin [1][3] | Yes, Whisper lists Chinese and Cantonese [8] | Yes, zh_CN, zh_HK, zh_TW and yue_CN measured on this Mac [12] | Yes, Chinese, Cantonese and 22 Chinese dialects [14][15] |
| Mixed Chinese and English in one utterance | Unverified for SenseVoice. Parakeet cannot | Weak. A 2025 study reports Whisper Large-V2 with the highest error rates among tested models and occasional translation instead of transcription [9][10] | Unverified | Unverified. No statement found in the card, README or paper [14][15][16] |
| Minimum macOS | 14 for the package, 15 for some models [2][1] | README says 14, manifest says 13 [5][6] | 26 [11] | Orra side: any. Server on Apple Silicon: 14 or newer [18] |
| Model size | 0.6B parameters. Redux download about 220 MB. v3 download size unverified [4][1] | CoreML variants from about 216 MB (small) to 947 MB (large v3), 626 MB for the recommended large v3 turbo build [7] | Unverified. Managed by the system, not bundled [13] | 0.6B weights 1.88 GB, 1.7B weights 4.7 GB [14][15] |
| Runs in process | Yes, CoreML, Swift package [1] | Yes, CoreML, Swift package [5] | Yes, system framework [11] | No. HTTP to a separate Python server [17] |
| License | Package Apache 2.0. Parakeet CC BY 4.0. SenseVoice weights under a FunASR model license [2][4][3] | Package MIT. Whisper weights MIT [5][8] | Part of macOS, Apple SDK terms | Weights Apache 2.0. Server Apache 2.0 [14][17] |

## FluidAudio with Parakeet

- What it is: a Swift package that runs CoreML conversions of several ASR models on
  the Apple Neural Engine. Installed through Swift Package Manager from
  `https://github.com/FluidInference/FluidAudio.git`. [1]
- Minimum macOS: the package manifest declares macOS 14 and iOS 17. [2] Parakeet
  Redux and Phonon-2 need iOS 18 or macOS 15. [1]
- Languages: the README says Parakeet TDT v3 (0.6b) and related models cover "25
  European languages and Japanese, plus SenseVoice and Paraformer for Mandarin
  Chinese". [1] The model list shows Japanese as a separate Parakeet TDT Japanese
  model, and lists Parakeet TDT v3 as "25 European languages (0.6B params). Default
  ASR model." [3] NVIDIA's model card for parakeet-tdt-0.6b-v3 lists the 25 languages.
  Chinese is not among them. [4]
- Mandarin path: SenseVoiceSmall and Paraformer-large (zh). FluidAudio describes
  SenseVoiceSmall as "Non-autoregressive multilingual batch speech-to-text (50+
  languages)". [3] The SenseVoice project itself says SenseVoiceSmall supports
  "Mandarin, Cantonese, English, Japanese, and Korean". [3b] I could not reconcile
  the two language counts. Unverified: whether either model handles Chinese and
  English mixed in one utterance, and the download size of each Mandarin model.
- Model size: Parakeet TDT v3 has 600 million parameters. [4] Parakeet Redux is the
  "smallest download at ~220 MB". [1] The download size of the v3 CoreML bundle is not
  stated in the README or model list. Unverified.
- Integration with Orra: add the package, then roughly
  `AsrModels.downloadAndLoad(version:)`, `AsrManager(config: .default)` and
  `transcribe(samples)` on 16 kHz float samples. Streaming is available through
  `SlidingWindowAsrManager`. [1] Orra would record with AVAudioEngine, hand the
  buffer to the manager after release, and pick a Mandarin model when the user's
  language is Chinese. Models download from Hugging Face on first use, which is a
  network step the user must expect.
- License: the package is Apache 2.0. [2] Parakeet weights are CC BY 4.0. [4]
  SenseVoice code is MIT and the official SenseVoiceSmall weights follow the "FunASR
  Model Open Source License Agreement", which the project says permits commercial use
  when followed. [3b] Paraformer weight license: unverified.
- Note: the FluidAudio model list mentions Qwen3 ASR CoreML only as having "Low
  upstream adoption". [3]

## WhisperKit

- What it is: Argmax's Swift package that runs OpenAI Whisper models as CoreML on
  Apple devices. Models download automatically from the `argmaxinc/whisperkit-coreml`
  repository on Hugging Face. [5]
- Minimum macOS: the README states "macOS 14.0 or later" and "Xcode 16.0 or
  later" for WhisperKit. [5] The package manifest declares macOS 13 and iOS 16. [6]
  Treat 14 as the practical minimum.
- Languages: Whisper's tokenizer lists 100 languages, including `zh` (chinese) and
  `yue` (cantonese). [8] WhisperKit exposes a `language` option with automatic
  detection as the default. [5]
- Mixed Chinese and English: the CS-Dialogue paper (2025) tested Whisper Large-V2 on
  spontaneous Mandarin and English code switching and reports it "exhibits the
  highest error rates among the pre-trained models", with CER 10.7%, WER 31.11% and
  MER 15.29% on their test set. It also notes the model "occasionally produces
  translations of the input speech rather than accurate transcriptions". [9][10] A
  2023 study found that adapting Whisper with code switch data "uniformly improves
  its performance". [10b] So stock Whisper is usable for Mandarin but weak on mixed
  speech. Which Whisper version WhisperKit ships changes this, so it needs a test.
- Model size: the CoreML repository names carry sizes, for example
  `openai_whisper-small_216MB`, `openai_whisper-large-v3-v20240930_626MB` (the README's
  recommended build), `openai_whisper-large-v3-v20240930_turbo_632MB` and
  `openai_whisper-large-v3_947MB`. [7][5] Parameter counts from OpenAI: tiny 39M, base
  74M, small 244M, medium 769M, large 1550M, turbo 809M. [8]
- Integration with Orra: add the package, then `WhisperKit(WhisperKitConfig(model:))`
  and `transcribe(audioArray:)` on the recorded samples. [5] Same recording flow as
  above. First run downloads the model.
- License: WhisperKit is MIT. [5] Whisper's "code and model weights are released
  under the MIT License". [8]

## Apple SpeechAnalyzer

- What it is: the Speech framework API introduced with the 26 releases. A
  `SpeechAnalyzer` holds modules such as `SpeechTranscriber`, takes an asynchronous
  audio input sequence and returns results as an `AsyncSequence`. [11]
- Minimum macOS: 26.0. [11] Orra targets 15.6, so this path needs `#available(macOS
  26, *)` and either a fallback engine or no transcription on macOS 15.
- On device: Apple's session says "The model operates entirely on-device" and
  "transcription is entirely on device but the models need to be fetched". [13]
- Languages: on this Mac (macOS 26.6.2, Xcode 27.0) `SpeechTranscriber.supportedLocales`
  returned 30 locales: de_AT, de_CH, de_DE, en_AU, en_CA, en_GB, en_IE, en_IN, en_NZ,
  en_SG, en_US, en_ZA, es_CL, es_ES, es_MX, es_US, fr_BE, fr_CA, fr_CH, fr_FR, it_CH,
  it_IT, ja_JP, ko_KR, pt_BR, pt_PT, yue_CN, zh_CN, zh_HK, zh_TW. Only the English
  locales were installed. [12] A July 2025 article listed 42 locales during the
  beta, so the set changes between releases. [12b] Apple's session only says
  "SpeechTranscriber can currently transcribe these languages, with more to come".
  [13]
- Mixed Chinese and English: unverified. The transcriber is configured per locale.
  Needs a test with real audio.
- Model size: not published. Assets are "machine-learning models downloaded from
  Apple's servers and managed by the system", shared between apps, with a limited
  number of locale reservations per app. [13b] Apple's session adds that the model
  "does not increase the download or storage size of your application". [13]
- Integration with Orra: no package. Create a `SpeechTranscriber`, request assets
  through `AssetInventory`, feed `AnalyzerInput` buffers from AVAudioEngine to a
  `SpeechAnalyzer`, and read the transcriber's results sequence. [11][13b] A Chinese
  user needs the zh assets downloaded once through the API.
- License: part of the operating system. No separate model license. Nothing to
  bundle.

## Qwen3-ASR via an SGLang-Omni compatible endpoint

- What it is: Alibaba's Qwen3-ASR-0.6B and Qwen3-ASR-1.7B, open weights released on
  2026-01-29, served by SGLang-Omni behind an OpenAI compatible
  `/v1/audio/transcriptions` endpoint. [14][16][17]
- Languages: the GitHub README and the technical report say "52 languages and
  dialects". [15][16] The model card phrases it as "30 languages and 22 Chinese
  dialects", and names Chinese, Cantonese and English. [14]
- Mixed Chinese and English: unverified. I found no statement about code switching
  in the model card, the README or the report abstract. [14][15][16]
- Minimum macOS: Orra only needs an HTTP client, so the app side is unchanged. The
  server is a separate matter. SGLang-Omni lists NVIDIA CUDA as supported and Apple
  Silicon as experimental: "Qwen3-ASR runs through native MLX or Torch MPS on macOS
  arm64". [17] Its Apple Silicon guide "requires macOS 14 or newer, Python 3.12,
  Homebrew, and SGLang's MLX runtime", a specific FFmpeg 7 formula, and a
  `DYLD_LIBRARY_PATH` setting when the server starts. The MLX path "supports one
  device (tp_size=1) and greedy decoding" and uses an MLX converted checkpoint such as
  `mlx-community/Qwen3-ASR-0.6B-4bit`. [18]
- Model size: safetensors on Hugging Face total 1.88 GB for 0.6B and 4.7 GB for
  1.7B. [14][14b] The 4 bit MLX checkpoint is smaller. Size unverified.
- Integration with Orra: after release, POST the recording as a multipart file to
  `http://localhost:8000/v1/audio/transcriptions` and read the text, as in the
  cookbook's curl example. The endpoint "accepts one uploaded audio file per request
  and returns text". The translations endpoint returns HTTP 400 for this model. [18]
  No Swift dependency. The user must install and run a Python server on the same Mac
  or on a machine on the LAN. That is not cloud transcription, which v0.1 rules out,
  but it is a second process and a Python toolchain that Orra cannot manage.
- License: weights Apache 2.0. [14][15] SGLang-Omni Apache 2.0. [17]

## Not verified, needs a real test

- Mixed Chinese and English for SenseVoice, SpeechAnalyzer and Qwen3-ASR.
- Download sizes of the FluidAudio v3 bundle and the Mandarin models, and of
  SpeechAnalyzer assets.
- Paraformer weight license.
- Latency on Apple Silicon for a five second utterance. None of the sources report
  it for this use case.
- Which SpeechTranscriber locales exist on macOS 26.0 rather than 26.6.2.

## Questions for the maintainer

1. Is macOS 26 only acceptable for transcription, with macOS 15 users left out, or
   must macOS 15.6 work? That decides whether SpeechAnalyzer can be the only engine.
2. Is an in process Swift package (FluidAudio or WhisperKit) acceptable as the first
   dependency?
3. Is a user run local server (SGLang-Omni) in scope for v0.1, or is that the kind of
   setup burden Orra should avoid?
4. How much does mixed Chinese and English matter for the first release? If it is
   central, every option needs a listening test before choosing.

## Sources

1. FluidAudio README: https://github.com/FluidInference/FluidAudio/blob/main/README.md
2. FluidAudio Package.swift (platforms) and LICENSE: https://github.com/FluidInference/FluidAudio/blob/main/Package.swift and https://github.com/FluidInference/FluidAudio/blob/main/LICENSE
3. FluidAudio model list: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md
3b. SenseVoice README (languages, licenses): https://github.com/FunAudioLLM/SenseVoice
4. NVIDIA parakeet-tdt-0.6b-v3 model card: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
5. WhisperKit README (requirements, usage, license): https://github.com/argmaxinc/WhisperKit
6. WhisperKit Package.swift (platforms): https://github.com/argmaxinc/WhisperKit/blob/main/Package.swift
7. WhisperKit CoreML model repository (directory names with sizes): https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main
8. OpenAI Whisper README (model table, license) and tokenizer (language list): https://github.com/openai/whisper and https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
9. CS-Dialogue paper abstract: https://arxiv.org/abs/2502.18913
10. CS-Dialogue paper full text (Table 8, Appendix E): https://arxiv.org/html/2502.18913
10b. Adapting OpenAI's Whisper for Speech Recognition on Code-Switch Mandarin-English SEAME and ASRU2019 Datasets: https://arxiv.org/abs/2311.17382
11. Apple, SpeechAnalyzer and SpeechTranscriber documentation (platform availability): https://developer.apple.com/documentation/speech/speechanalyzer and https://developer.apple.com/documentation/speech/speechtranscriber
12. Measured on this Mac on 2026-10-02 with a short Swift program calling `SpeechTranscriber.supportedLocales` and `installedLocales`, macOS 26.6.2, Xcode 27.0. Not downloaded, only listed.
12b. iOS 26 SpeechAnalyzer guide, July 2025 (beta locale list): https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide
13. Apple, WWDC25 session 277, Bring advanced speech-to-text to your app with SpeechAnalyzer: https://developer.apple.com/videos/play/wwdc2025/277/
13b. Apple, AssetInventory documentation: https://developer.apple.com/documentation/speech/assetinventory
14. Qwen3-ASR-1.7B model card (languages, license, release): https://huggingface.co/Qwen/Qwen3-ASR-1.7B
14b. Qwen3-ASR-0.6B model page (weight size): https://huggingface.co/Qwen/Qwen3-ASR-0.6B
15. Qwen3-ASR GitHub README and LICENSE: https://github.com/QwenLM/Qwen3-ASR
16. Qwen3-ASR Technical Report: https://arxiv.org/abs/2601.21337
17. SGLang-Omni README (models, endpoints, hardware table, license): https://github.com/sgl-project/sglang-omni
18. SGLang-Omni Qwen3-ASR cookbook (endpoint behaviour, Apple Silicon section, curl example): https://github.com/sgl-project/sglang-omni/blob/main/docs/cookbook/qwen3_asr.md
