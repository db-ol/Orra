#!/bin/zsh
# The release gate: builds Release once, runs the opt in evaluations one after another,
# writes one JSON file per suite and compares them with a baseline. docs/release-gate.md
# describes the suites, the rules and the variables below.
#
#   Tools/release-gate/run.sh [--baseline DIR] [--only corpus,context,cleanup,latency,sets,projects,retrieval,pairs,wrong-pairs] [--pairs zh,ja,es] [--out DIR] [--skip-build]
#
# Without --only it runs every suite but the two of the dictation pairs, the projects and
# retrieval suites too, which need the variables of docs/release-gate.md. pairs and
# wrong-pairs run the pairs of --pairs, every pair Orra has unless it names some. Exit
# status: 0 when every suite ran and nothing got worse, 1 when a rule failed or, with or
# without a baseline, the projects bar, 2 when the build or a suite failed to run.
set -u

repo=${0:A:h:h:h}
bench=${ORRA_BENCH:-$HOME/projects/orra-project/bench}
corpus=${GATE_CORPUS_DIR:-$bench/speech-corpus}
sets=${GATE_SETS_DIR:-$bench/gate-sets}
latency_clips=${GATE_LATENCY_CLIPS:-$sets/latency-say/clips}
derived=${GATE_DERIVED_DATA:-$repo/build/DerivedDataRelease}
lock=${GATE_LOCK:-}
context_count=${GATE_CONTEXT_COUNT:-100}
projects_set=${GATE_PROJECTS_SET:-$bench/projects-testset}
all_suites=(corpus context cleanup latency sets projects retrieval)
default_suites=($all_suites)

baseline=""
only=${(j:,:)default_suites}
out=""
build=1
pairs_arg=""
while (( $# )); do
  case $1 in
    --baseline) baseline=${2:A}; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --out) out=${2:A}; shift 2 ;;
    --skip-build) build=0; shift ;;
    --pairs) pairs_arg=$2; shift 2 ;;
    -h|--help) sed -n '2,12p' $0; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
suites=(${(s:,:)only})
# The suites of the dictation pairs run after the others, in their own block below.
pair_suites_known=(pairs wrong-pairs)
pair_suites=(${suites:*pair_suites_known})
suites=(${suites:|pair_suites_known})
if [[ -n $pairs_arg ]] && (( ! ${#pair_suites} )); then
  echo "--pairs needs pairs or wrong-pairs in --only" >&2
  exit 2
fi
for suite in $suites; do
  (( ${all_suites[(Ie)$suite]} )) || { echo "unknown suite $suite" >&2; exit 2 }
done
# The set owner's addresses and name, from the set's README, stay out of the repository.
if (( ${suites[(Ie)projects]} )) && [[ -z ${GATE_PROJECTS_OWN_ADDRESSES:-} || -z ${GATE_PROJECTS_OWN_NAME:-} || ! -s $projects_set/adversarial.jsonl ]]; then
  echo "the projects suite needs GATE_PROJECTS_OWN_ADDRESSES, GATE_PROJECTS_OWN_NAME and the set in $projects_set" >&2
  exit 2
fi
if (( ${suites[(Ie)retrieval]} )) && [[ -z ${GATE_PROJECTS_OWN_ADDRESSES:-} || -z ${GATE_PROJECTS_OWN_NAME:-} || ! -s $projects_set/retrieval/labels.jsonl ]]; then
  echo "the retrieval suite needs GATE_PROJECTS_OWN_ADDRESSES, GATE_PROJECTS_OWN_NAME and the retrieval supplement in $projects_set/retrieval" >&2
  exit 2
fi
sha=$(git -C $repo rev-parse --short HEAD)
[[ -n $out ]] || out=$bench/gate-runs/$sha-$(date +%Y%m%d-%H%M%S)
mkdir -p $out/raw $out/logs
echo "commit $sha, results in $out"
git -C $repo rev-parse HEAD > $out/commit.txt

# Dictation pairs, plan: gate.py names each test run of the pair suites and writes their
# clip lists into $out. A pair is a code, zh, ja or es.
pair_sets=${GATE_PAIR_SETS_DIR:-$sets/pairs}
fleurs_dirs=(${=GATE_FLEURS_DIRS:-$bench/fleurs-ja-es $bench/fleurs-ko})
pair_args=(--corpus $corpus --fleurs $fleurs_dirs --pair-sets $pair_sets --count ${GATE_WRONG_PAIR_CLIPS:-50})
[[ -n $pairs_arg ]] && pair_args+=(--pairs $pairs_arg)
pair_runs=()
for suite in $pair_suites; do
  plan=$(python3 $repo/Tools/release-gate/gate.py runs $suite $out $pair_args) || exit 2
  [[ -n $plan ]] && pair_runs+=("${(@f)plan}")
done

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
# Matches the executable path of each process, not its arguments, so a shell whose
# command line names Orra does not count.
installed_orra_runs() {
  ps -axo comm= | grep -E '/Orra\.app/Contents/MacOS/Orra$' | grep -v "/DerivedData" > /dev/null
}

wait_for_installed_orra() {
  local said=0
  while installed_orra_runs; do
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
    projects)
      env+=(TEST_RUNNER_ORRA_PROJECTS_GATE=$projects_set TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=$GATE_PROJECTS_OWN_ADDRESSES
        TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=$GATE_PROJECTS_OWN_NAME)
      [[ -n ${GATE_CLEANUP_MODEL_DIR:-} ]] && env+=(TEST_RUNNER_ORRA_REWRITE_MODEL_DIR=$GATE_CLEANUP_MODEL_DIR)
      # The choose mode, with the files of gate-choose.json chosen, see docs/release-gate.md.
      [[ -n ${GATE_PROJECTS_CHOOSE:-} ]] && env+=(TEST_RUNNER_ORRA_PROJECTS_GATE_CHOOSE=$GATE_PROJECTS_CHOOSE)
      test_id=OrraTests/ProjectsGateEvaluationTests ;;
    retrieval)
      env+=(TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL=$projects_set TEST_RUNNER_ORRA_PROJECTS_RETRIEVAL_OUT=$out/raw
        TEST_RUNNER_ORRA_PROJECTS_OWN_ADDRESSES=$GATE_PROJECTS_OWN_ADDRESSES TEST_RUNNER_ORRA_PROJECTS_OWN_NAME=$GATE_PROJECTS_OWN_NAME)
      [[ -n ${GATE_CLEANUP_MODEL_DIR:-} ]] && env+=(TEST_RUNNER_ORRA_REWRITE_MODEL_DIR=$GATE_CLEANUP_MODEL_DIR)
      test_id=OrraTests/RetrievalEvaluationTests ;;
  esac
  # Waits for the lock with no Orra running, so neither starts while the other waits.
  while true; do
    wait_for_installed_orra
    take_lock
    installed_orra_runs || break
    release_lock
  done
  echo "$suite: started $(date +%H:%M:%S)"
  env $env $xcode test-without-building -only-testing:$test_id > $out/logs/$suite.log 2>&1
  code=$?
  release_lock
  expected=$out/raw/$suite.json
  [[ $suite == sets ]] && expected=$out/raw/sets-raw.json
  [[ $suite == retrieval ]] && expected=$out/raw/retrieval.jsonl
  # The whole set in one part, see ProjectsGateEvaluationTests.
  [[ $suite == projects ]] && expected=($out/raw/projects-001-*.json(N[1]))
  if [[ ! -s $expected ]]; then
    echo "$suite: no results (xcodebuild exit $code), see $out/logs/$suite.log" >&2
    failed_to_run+=($suite)
  else
    echo "$suite: done $(date +%H:%M:%S), xcodebuild exit $code"
  fi
done

# Dictation pairs, runs: each test run of the plan, with its pair chosen, waiting for an
# installed Orra and for the lock as the suites above do. Then gate.py scores them. A run
# of the context or latency suite takes the variables of that suite above, the latency
# suite with the pair's say clips.
for line in $pair_runs; do
  fields=("${(@ps:\t:)line}")
  label=$fields[1] kind=$fields[2] language=$fields[3] name=$fields[4] folder=$fields[5] clips=$fields[6] raw=$fields[7]
  env=(TEST_RUNNER_ORRA_GATE_OUT=$raw TEST_RUNNER_ORRA_DICTATION_LANGUAGE=$language)
  case $kind in
    corpus)
      env+=(TEST_RUNNER_ORRA_SPEECH_EVAL=1 TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$folder
        TEST_RUNNER_ORRA_SPEECH_EVAL_OUT=$raw TEST_RUNNER_ORRA_SPEECH_EVAL_NAME=$name)
      [[ $clips != - ]] && env+=(TEST_RUNNER_ORRA_SPEECH_CORPUS_CLIPS=$clips)
      test_id=OrraTests/SpeechCorpusEvaluationTests ;;
    context)
      env+=(TEST_RUNNER_ORRA_CONTEXT_EVAL=1 TEST_RUNNER_ORRA_CONTEXT_COUNT=$context_count)
      test_id=OrraTests/RealModelTests/ContextEvaluationTests ;;
    latency)
      env+=(TEST_RUNNER_ORRA_LATENCY=1 TEST_RUNNER_ORRA_LATENCY_CLIPS=$folder
        TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$corpus TEST_RUNNER_ORRA_LATENCY_REPORT=$out/logs/$label-report.txt)
      test_id="OrraTests/LatencyMeasurementTests/dictations()" ;;
    sets)
      env+=(TEST_RUNNER_ORRA_GATE_SETS=$folder)
      test_id=OrraTests/GateSetEvaluationTests ;;
    *) echo "gate.py planned a run of an unknown kind: $line" >&2; exit 2 ;;
  esac
  mkdir -p $raw
  while true; do
    wait_for_installed_orra
    take_lock
    installed_orra_runs || break
    release_lock
  done
  echo "$label: started $(date +%H:%M:%S)"
  env $env $xcode test-without-building -only-testing:$test_id > $out/logs/$label.log 2>&1
  code=$?
  release_lock
  if [[ ! -s $raw/$name.json ]]; then
    echo "$label: no results (xcodebuild exit $code), see $out/logs/$label.log" >&2
    failed_to_run+=($label)
  else
    echo "$label: done $(date +%H:%M:%S), xcodebuild exit $code"
  fi
done
if (( ${#pair_runs} )); then
  python3 $repo/Tools/release-gate/gate.py summarize-pairs $out --pair-sets $pair_sets --corpora $corpus $fleurs_dirs || exit 2
fi

python3 $repo/Tools/release-gate/gate.py summarize $out --sets $sets --projects-set $projects_set || exit 2

result=0
if [[ -n $baseline ]]; then
  python3 $repo/Tools/release-gate/gate.py compare $baseline $out --only $only > $out/compare.txt
  result=$?
  cat $out/compare.txt
else
  # Exits 1 when the projects bar fails, which holds without a baseline.
  python3 $repo/Tools/release-gate/gate.py show $out | tee $out/summary.txt
  result=${pipestatus[1]}
fi
if (( ${#failed_to_run} )); then
  echo "suites that did not run: ${failed_to_run[*]}" >&2
  exit 2
fi
exit $result
