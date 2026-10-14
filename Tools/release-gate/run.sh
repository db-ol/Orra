#!/bin/zsh
# The release gate: builds Release once, runs the opt in evaluations one after another,
# writes one JSON file per suite and compares them with a baseline. docs/release-gate.md
# describes the suites, the rules and the variables below.
#
#   Tools/release-gate/run.sh [--baseline DIR] [--only corpus,context,cleanup,latency,sets] [--out DIR] [--skip-build]
#
# Exit status: 0 when every suite ran and nothing got worse, 1 when a rule failed,
# 2 when the build or a suite failed to run.
set -u

repo=${0:A:h:h:h}
bench=${ORRA_BENCH:-$HOME/projects/orra-project/bench}
corpus=${GATE_CORPUS_DIR:-$bench/speech-corpus}
sets=${GATE_SETS_DIR:-$bench/gate-sets}
latency_clips=${GATE_LATENCY_CLIPS:-$sets/latency-say/clips}
derived=${GATE_DERIVED_DATA:-$repo/build/DerivedDataRelease}
lock=${GATE_LOCK:-}
context_count=${GATE_CONTEXT_COUNT:-100}
all_suites=(corpus context cleanup latency sets)

baseline=""
only=${(j:,:)all_suites}
out=""
build=1
while (( $# )); do
  case $1 in
    --baseline) baseline=${2:A}; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --out) out=${2:A}; shift 2 ;;
    --skip-build) build=0; shift ;;
    -h|--help) sed -n '2,10p' $0; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
suites=(${(s:,:)only})
for suite in $suites; do
  (( ${all_suites[(Ie)$suite]} )) || { echo "unknown suite $suite" >&2; exit 2 }
done
sha=$(git -C $repo rev-parse --short HEAD)
[[ -n $out ]] || out=$bench/gate-runs/$sha-$(date +%Y%m%d-%H%M%S)
mkdir -p $out/raw $out/logs
echo "commit $sha, results in $out"
git -C $repo rev-parse HEAD > $out/commit.txt

xcode=(xcodebuild -project $repo/Orra.xcodeproj -scheme Orra -configuration Release
  -destination 'platform=macOS,arch=arm64' -derivedDataPath $derived
  -testLanguage en -testRegion US ENABLE_TESTABILITY=YES)

if (( build )); then
  echo "building Release for testing"
  if ! $xcode build-for-testing > $out/logs/build.log 2>&1; then
    echo "build failed, see $out/logs/build.log" >&2
    exit 2
  fi
fi

# The test host is an Orra app. It must not run beside an installed Orra, so wait while
# one runs from anywhere but a DerivedData folder.
wait_for_installed_orra() {
  local said=0
  while pgrep -fl "Orra.app/Contents/MacOS/Orra" | grep -v "/DerivedData" > /dev/null; do
    (( said )) || echo "waiting for the installed Orra to quit"
    said=1
    sleep 30
  done
}

holding=0
take_lock() {
  [[ -n $lock ]] || return 0
  until mkdir $lock 2> /dev/null; do sleep 15; done
  holding=1
}
release_lock() {
  (( holding )) && rmdir $lock 2> /dev/null
  holding=0
}
trap 'release_lock; exit 2' INT TERM

failed_to_run=()
for suite in $suites; do
  env=(TEST_RUNNER_ORRA_GATE_OUT=$out/raw)
  case $suite in
    corpus)
      env+=(TEST_RUNNER_ORRA_SPEECH_EVAL=1 TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$corpus
        TEST_RUNNER_ORRA_SPEECH_EVAL_OUT=$out/raw TEST_RUNNER_ORRA_SPEECH_EVAL_NAME=corpus)
      test_id=OrraTests/SpeechCorpusEvaluationTests ;;
    context)
      env+=(TEST_RUNNER_ORRA_CONTEXT_EVAL=1 TEST_RUNNER_ORRA_CONTEXT_COUNT=$context_count)
      test_id=OrraTests/RealModelTests/ContextEvaluationTests ;;
    cleanup)
      env+=(TEST_RUNNER_ORRA_CLEANUP_EVAL=1 TEST_RUNNER_ORRA_CLEANUP_REPORT=$out/logs/cleanup-report.txt)
      [[ -n ${GATE_CLEANUP_MODEL_DIR:-} ]] && env+=(TEST_RUNNER_ORRA_REWRITE_MODEL_DIR=$GATE_CLEANUP_MODEL_DIR)
      test_id="OrraTests/CleanupModelEvaluationTests/cleanupCases()" ;;
    latency)
      env+=(TEST_RUNNER_ORRA_LATENCY=1 TEST_RUNNER_ORRA_LATENCY_CLIPS=$latency_clips
        TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$corpus TEST_RUNNER_ORRA_LATENCY_REPORT=$out/logs/latency-report.txt)
      test_id="OrraTests/LatencyMeasurementTests/dictations()" ;;
    sets)
      env+=(TEST_RUNNER_ORRA_GATE_SETS=$sets)
      test_id=OrraTests/GateSetEvaluationTests ;;
  esac
  # Waits for the lock with no Orra running, so neither starts while the other waits.
  while true; do
    wait_for_installed_orra
    take_lock
    pgrep -fl "Orra.app/Contents/MacOS/Orra" | grep -v "/DerivedData" > /dev/null || break
    release_lock
  done
  echo "$suite: started $(date +%H:%M:%S)"
  env $env $xcode test-without-building -only-testing:$test_id > $out/logs/$suite.log 2>&1
  code=$?
  release_lock
  expected=$out/raw/$suite.json
  [[ $suite == sets ]] && expected=$out/raw/sets-raw.json
  if [[ ! -s $expected ]]; then
    echo "$suite: no results (xcodebuild exit $code), see $out/logs/$suite.log" >&2
    failed_to_run+=($suite)
  else
    echo "$suite: done $(date +%H:%M:%S), xcodebuild exit $code"
  fi
done

python3 $repo/Tools/release-gate/gate.py summarize $out --sets $sets || exit 2

result=0
if [[ -n $baseline ]]; then
  python3 $repo/Tools/release-gate/gate.py compare $baseline $out --only $only > $out/compare.txt
  result=$?
  cat $out/compare.txt
else
  python3 $repo/Tools/release-gate/gate.py show $out | tee $out/summary.txt
fi
if (( ${#failed_to_run} )); then
  echo "suites that did not run: ${failed_to_run[*]}" >&2
  exit 2
fi
exit $result
