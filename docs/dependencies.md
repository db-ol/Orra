# Dependencies

## Approved

- soniqo/speech-swift (Apache-2.0), pinned to commit
  1f54e56cf137078ed681a03e0955e777f7314610, product Qwen3ASR only, linked to the Orra target
  only. Approved by the maintainer on 2026-10-04 to run Qwen3-ASR 1.7B, and added in Xcode by
  the maintainer on 2026-10-05.
- sparkle-project/Sparkle (MIT), exact version 2.10.0, product Sparkle only, linked to the
  Orra target only. Approved by the maintainer on 2026-10-10 for updates from inside the app,
  and added in Xcode by the maintainer the same day. It is a prebuilt, signed framework that
  Xcode embeds in Orra.app and signs again with the team's Developer ID on export. It reaches
  the network only for update checks the user allowed, see the README's privacy section.
- ml-explore/mlx-swift-lm (MIT), exact version 3.31.4, products MLXLLM and MLXLMCommon,
  linked to the Orra target only. Approved by the maintainer on 2026-10-10 to run a local
  text model for optional cleanup and translation, and added in Xcode by the maintainer the
  same day. speech-swift already resolved it and pins it with exact 3.31.4, so the version
  cannot move ahead of speech-swift. It adds no network use of its own: Orra downloads the
  text model itself, as it does the speech model.
- huggingface/swift-transformers (Apache-2.0), exact version 1.3.4, product Tokenizers
  only, linked to the Orra target only. Approved by the maintainer on 2026-10-11 for the
  cleanup model's tokenizer, in place of Orra's own port, and added in Xcode by the
  maintainer the same day. speech-swift already resolved it at 1.3.4 for its Hub product,
  so it adds no package to Package.resolved. Orra loads the tokenizer from the installed
  folder with `AutoTokenizer.from(modelFolder:)`, which reads local files and never
  downloads.

## What the build resolves

Xcode resolves 41 packages, listed in
Orra.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved. SwiftPM resolves
every package that speech-swift declares, but the build compiles only the 12 that the
Qwen3ASR, MLXLLM, MLXLMCommon and Tokenizers products need. The other 28 are fetched and never built
or linked. Versions come from Package.resolved and licenses from the GitHub API, both read
on 2026-10-05. The compiled list comes from the build log of 2026-10-10, which added
mlx-swift-lm and the MLXOptimizers target of mlx-swift and nothing else. Linking
Tokenizers on 2026-10-11 added its target of swift-transformers and no other package.

### Compiled for Orra

| Package | Version | License | Why it is built |
|---|---|---|---|
| soniqo/speech-swift | 1f54e56 | Apache-2.0 | Qwen3ASR and its targets AudioCommon, MLXCommon and SpeechVAD |
| ml-explore/mlx-swift | 0.31.6 | MIT | MLX, MLXNN, MLXFast, MLXFFT, MLXOptimizers and the Cmlx core with its 9 Metal shaders |
| ml-explore/mlx-swift-lm | 3.31.4 | MIT | MLXLLM and MLXLMCommon, which load and run the cleanup model |
| apple/swift-numerics | 1.1.1 | Apache-2.0 | Numerics, used by MLX |
| huggingface/swift-transformers | 1.3.4 | Apache-2.0 | Tokenizers, the cleanup model's tokenizer, and Hub, used by AudioCommon and Tokenizers |
| huggingface/swift-huggingface | 0.13.0 | Apache-2.0 | HuggingFace, used by Hub |
| mattt/eventsource | 1.5.1 | MIT | EventSource, used by HuggingFace |
| huggingface/swift-jinja | 2.5.1 | Apache-2.0 | Jinja, used by Hub and Tokenizers |
| apple/swift-collections | 1.7.1 | Apache-2.0 | OrderedCollections, used by Hub and Jinja |
| apple/swift-crypto | 4.5.2 | Apache-2.0 | Crypto, used by Hub and HuggingFace |
| ibireme/yyjson | 0.12.0 | MIT | yyjson, used by Hub |
| apple/swift-argument-parser | 1.8.2 | Apache-2.0 | only for encuda, the tool behind the CudaBuild build plugin of mlx-swift. Not linked into the app |
| sparkle-project/Sparkle | 2.10.0 | MIT | updates from inside the app. A binary framework, embedded rather than compiled |

Everything above except swift-argument-parser is linked statically into Orra. The app bundle
also carries three resource bundles: mlx-swift_Cmlx.bundle with the compiled Metal library,
swift-crypto_Crypto.bundle and swift-transformers_Hub.bundle.

### Resolved but not built

These are resolved only because other speech-swift products need them.

| Package | Version | License |
|---|---|---|
| adam-fowler/compress-nio | 1.4.2 | Apache-2.0 |
| apple/swift-algorithms | 1.2.1 | Apache-2.0 |
| apple/swift-asn1 | 1.7.3 | Apache-2.0 |
| apple/swift-async-algorithms | 1.1.7 | Apache-2.0 |
| apple/swift-atomics | 1.3.1 | Apache-2.0 |
| apple/swift-certificates | 1.21.0 | Apache-2.0 |
| apple/swift-configuration | 1.2.2 | Apache-2.0 |
| apple/swift-distributed-tracing | 1.5.0 | Apache-2.0 |
| apple/swift-http-structured-headers | 1.7.0 | Apache-2.0 |
| apple/swift-http-types | 1.8.0 | Apache-2.0 |
| apple/swift-log | 1.15.1 | Apache-2.0 |
| apple/swift-metrics | 2.11.0 | Apache-2.0 |
| apple/swift-nio | 2.103.0 | Apache-2.0 |
| apple/swift-nio-extras | 1.35.1 | Apache-2.0 |
| apple/swift-nio-http2 | 1.46.0 | Apache-2.0 |
| apple/swift-nio-ssl | 2.37.5 | Apache-2.0 |
| apple/swift-nio-transport-services | 1.28.0 | Apache-2.0 |
| apple/swift-service-context | 1.3.0 | Apache-2.0 |
| apple/swift-system | 1.8.1 | Apache-2.0 |
| argmaxinc/WhisperKit | 1.1.0 | MIT |
| hummingbird-project/hummingbird | 2.16.0 | Apache-2.0 |
| hummingbird-project/hummingbird-websocket | 2.6.0 | Apache-2.0 |
| hummingbird-project/swift-websocket | 1.5.0 | Apache-2.0 |
| mlc-ai/xgrammar | 0.2.7 | Apache-2.0 |
| modelcontextprotocol/swift-sdk | 0.12.1 | MIT or Apache-2.0, see below |
| swift-server/async-http-client | 1.36.2 | Apache-2.0 |
| swift-server/swift-service-lifecycle | 2.12.1 | Apache-2.0 |
| swiftlang/swift-syntax | 603.0.2 | Apache-2.0 |

SwiftPM also downloads SpeechCore.xcframework from soniqo/speech-core v0.0.14, a prebuilt
binary target of speech-swift. Orra does not link it, and its license is not checked.

modelcontextprotocol/swift-sdk is moving from MIT to Apache-2.0. Its LICENSE file says each
contribution is under one or the other, so GitHub detects no single license.

## Build requirements that come with it

- The Metal Toolchain component of Xcode, because mlx-swift compiles Metal shaders at build
  time. Install it in Xcode > Settings > Components. Without it the build stops at
  CompileMetalFile with "missing Metal Toolchain". It belongs to one Xcode version, so an
  Xcode update may ask for it again.
- mlx-swift has a build tool plugin, CudaBuild. Xcode asks to Trust & Enable it, and
  afterwards the xcodebuild commands in README.md work without extra flags. The trust
  belongs to the resolved mlx-swift revision, so after a package update that moves
  mlx-swift, Xcode asks again and command line builds stop at plugin validation until it is
  trusted. On macOS the plugin adds no build commands.
- mlx-swift-lm has a macro, MLXHuggingFaceMacros, and Xcode may ask to enable it. Orra
  builds only MLXLLM and MLXLMCommon, not MLXHuggingFace, so the macro and swift-syntax
  are not built or needed. On the maintainer's Mac it was enabled on 2026-10-05, which
  changes nothing in the build.
- The build log has four warnings from Metal headers inside mlx-swift ("constexpr if is a
  C++17 extension"). They are third party code and do not affect Orra.

## Model download

Orra downloads the speech model itself. It uses URLSession for the download, CryptoKit for
the hashes and a Mutex from Synchronization in the session delegate, all from the macOS SDK,
and clonefile from the system library to reuse an older copy. No package was added for it.
speech-swift's own downloader is not used. speech-swift only loads the model, with
offlineMode: true, from the folder Orra installed. docs/model-download.md describes the
download.

## Cleanup model

Orra downloads the cleanup model with the same code as the speech model, see
docs/model-download.md. mlx-swift-lm loads it from that folder with
`LLMModelFactory.load(from:using:)`, which reads local files only. It leaves the tokenizer
to the app. Orra/CleanupTokenizer.swift hands it the tokenizer of swift-transformers, read
from tokenizer.json and tokenizer_config.json in the same folder. It is the bridge that
the #adaptHuggingFaceTokenizer macro of mlx-swift-lm writes, written out by hand, so the
MLXHuggingFace product and its macro stay out of the build. Orra writes the chat prompt
itself (RewritePrompt) and only encodes it.

The model is Qwen3.5 4B since 2026-10-11, in place of Qwen3 4B Instruct 2507. MLXLLM in
mlx-swift-lm 3.31.4 knows its model type, qwen3_5, and loads the language model alone,
dropping any vision weights. swift-transformers reads its tokenizer_config.json, whose
tokenizer class is TokenizersBackend, as a BPE tokenizer. No dependency changed for it.

It replaced Orra's own port of Qwen3's tokenizer (QwenTokenizer, removed on 2026-10-11).
Before the port was removed, a one off run compared the two on the files of Qwen3 4B
Instruct 2507: every
input and expected text of the 178 regular and 70 adversarial evaluation cases, as
written and after the filler and number rules, the 1,344 texts of numbers.jsonl, the
cases of RewriteTokenizerCases and the few shot examples, 2,131 texts in all. The IDs of
each text alone and of the whole cleanup prompt built around it were the same, both
decoded to the same text with and without special tokens, and each of the 151,669 token
IDs decoded alone to the same text. RewriteTokenizerTests checks CleanupTokenizer against
IDs that transformers in Python gave, now for Qwen3.5 4B. In a Debug build the port loaded in 0.41 s and
swift-transformers loads in 0.70 s, once when the model loads.

## Keeping speech-swift or carrying only Qwen3ASR

Still the maintainer's decision. Carrying only the Apache-2.0 sources of Qwen3ASR,
AudioCommon, MLXCommon and SpeechVAD in a local package would drop the 28 packages that are
never built. Orra would then depend on mlx-swift-lm directly, and its macro prompt would
stay. It would keep mlx-swift, mlx-swift-lm, swift-transformers and their dependencies,
and with them the Metal Toolchain requirement and the CudaBuild plugin.
