#!/bin/bash
# Runs every engine on every subset, one after another so timings do not compete.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${ORRA_EVAL_DIR:-$HOME/projects/orra-project/eval}"
# Override with SETS="my_mixed" ./run_all.sh to run only your own folder under sets/.
SETS=${SETS:-"fleurs_zh fleurs_en ascend_mixed"}
T=tools/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts/bin/sherpa-onnx-offline

qwen() { # name model hint
  local name=$1 model=$2 hint=$3
  for s in $SETS; do
    [ "$4" != "" ] && [[ " $4 " != *" $s "* ]] && continue
    local args=(transcribe-batch sets/$s --model "$model" --jsonl)
    [ -n "$hint" ] && args+=(--language "$hint")
    echo "== $name $s $(date +%T)"
    /usr/bin/time -l speech "${args[@]}" > results/$name.$s.jsonl 2> results/$name.$s.err
    grep "peak memory footprint" results/$name.$s.err | head -1
  done
}

sherpa() { # name args...
  local name=$1; shift
  for s in $SETS; do
    echo "== $name $s $(date +%T)"
    /usr/bin/time -l $T "$@" sets/$s/*.wav > results/$name.$s.out 2> results/$name.$s.err
    grep "peak memory footprint" results/$name.$s.err | head -1
  done
}

qwen q06_auto 0.6B ""
qwen q06_zh 0.6B Chinese
qwen q06_8bit_auto 0.6B-8bit ""
qwen q17_auto 1.7B ""
qwen q17_zh 1.7B Chinese "fleurs_zh ascend_mixed"

X=models/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03
sherpa xasr --encoder=$X/encoder-epoch-99-avg-1.int8.onnx --decoder=$X/decoder-epoch-99-avg-1.onnx --joiner=$X/joiner-epoch-99-avg-1.int8.onnx --tokens=$X/tokens.txt --num-threads=2

S=models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17
sherpa sensevoice --sense-voice-model=$S/model.int8.onnx --tokens=$S/tokens.txt --sense-voice-use-itn=1 --num-threads=2

F=models/sherpa-onnx-funasr-nano-int8-2025-12-30
sherpa funasr_nano --funasr-nano-encoder-adaptor=$F/encoder_adaptor.int8.onnx --funasr-nano-llm=$F/llm.int8.onnx --funasr-nano-embedding=$F/embedding.int8.onnx --funasr-nano-tokenizer=$F/Qwen3-0.6B --num-threads=2

# Apple SpeechAnalyzer baseline, macOS 26 and later. Installs the zh_CN asset on first use.
mkdir -p apple
[ -x apple/apple_asr ] || swiftc -O -parse-as-library -swift-version 5 -o apple/apple_asr "$SCRIPT_DIR/apple_asr.swift"
for s in $SETS; do
  loc=zh_CN
  [[ "$s" == *_en ]] && loc=en_US
  echo "== apple $s $(date +%T)"
  /usr/bin/time -l apple/apple_asr "$loc" "sets/$s" "results/apple.$s.jsonl" 2> "results/apple.$s.err"
done

echo "ALL DONE $(date +%T)"
