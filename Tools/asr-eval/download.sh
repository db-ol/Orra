#!/bin/bash
# Downloads the tools, models and public test sets into ORRA_EVAL_DIR. About 2.4 GB.
set -ex
mkdir -p "${ORRA_EVAL_DIR:-$HOME/projects/orra-project/eval}"/{tools,models,datasets}
cd "${ORRA_EVAL_DIR:-$HOME/projects/orra-project/eval}"
brew install speech
R=https://github.com/k2-fsa/sherpa-onnx/releases/download
curl -sSL -o tools/sherpa.tar.bz2 $R/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts.tar.bz2 && tar xjf tools/sherpa.tar.bz2 -C tools && rm tools/sherpa.tar.bz2
for m in sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03 sherpa-onnx-funasr-nano-int8-2025-12-30 sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17; do
  curl -sSL -o models/$m.tar.bz2 $R/asr-models/$m.tar.bz2 && tar xjf models/$m.tar.bz2 -C models && rm models/$m.tar.bz2
done
H=https://huggingface.co/datasets
mkdir -p datasets/fleurs_zh datasets/fleurs_en datasets/ascend
curl -sSL -o datasets/fleurs_zh/test.tsv $H/google/fleurs/resolve/main/data/cmn_hans_cn/test.tsv
curl -sSL -o datasets/fleurs_zh/test.tar.gz $H/google/fleurs/resolve/main/data/cmn_hans_cn/audio/test.tar.gz
curl -sSL -o datasets/fleurs_en/test.tsv $H/google/fleurs/resolve/main/data/en_us/test.tsv
curl -sSL -o datasets/fleurs_en/test.tar.gz $H/google/fleurs/resolve/main/data/en_us/audio/test.tar.gz
curl -sSL -o datasets/ascend/test.parquet $H/CAiRE/ASCEND/resolve/main/main/test-00000-of-00001.parquet
echo DONE
du -sh tools models datasets
