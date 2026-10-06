#!/bin/bash
# Times one dictation at a time: every clip runs in its own process, as one Fn release would.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${ORRA_EVAL_DIR:-$HOME/projects/orra-project/eval}"
mkdir -p bench/out
[ -f bench/clips.tsv ] || /usr/bin/python3 "$SCRIPT_DIR/bench_select.py"
T=tools/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts/bin/sherpa-onnx-offline
X=models/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03
S=models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17
F=models/sherpa-onnx-funasr-nano-int8-2025-12-30
CLIPS=$(cut -f1 bench/clips.tsv)
for m in 0.6B 0.6B-8bit 1.7B; do
  for c in $CLIPS; do
    /usr/bin/time -l speech transcribe-batch bench/clips/$c --model $m --jsonl > bench/out/q$m.$c.out 2> bench/out/q$m.$c.err
  done
  echo "qwen $m done $(date +%T)"
done
for c in $CLIPS; do
  /usr/bin/time -l $T --encoder=$X/encoder-epoch-99-avg-1.int8.onnx --decoder=$X/decoder-epoch-99-avg-1.onnx --joiner=$X/joiner-epoch-99-avg-1.int8.onnx --tokens=$X/tokens.txt --num-threads=2 bench/clips/$c/$c.wav > bench/out/xasr.$c.out 2> bench/out/xasr.$c.err
done; echo "xasr done $(date +%T)"
for c in $CLIPS; do
  /usr/bin/time -l $T --sense-voice-model=$S/model.int8.onnx --tokens=$S/tokens.txt --sense-voice-use-itn=1 --num-threads=2 bench/clips/$c/$c.wav > bench/out/sensevoice.$c.out 2> bench/out/sensevoice.$c.err
done; echo "sensevoice done $(date +%T)"
for c in $CLIPS; do
  /usr/bin/time -l $T --funasr-nano-encoder-adaptor=$F/encoder_adaptor.int8.onnx --funasr-nano-llm=$F/llm.int8.onnx --funasr-nano-embedding=$F/embedding.int8.onnx --funasr-nano-tokenizer=$F/Qwen3-0.6B --num-threads=2 bench/clips/$c/$c.wav > bench/out/funasr_nano.$c.out 2> bench/out/funasr_nano.$c.err
done; echo "funasr_nano done $(date +%T)"
echo BENCH DONE
