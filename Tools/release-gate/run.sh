#!/bin/zsh
# The release gate: builds Release once, runs the opt in evaluations one after another,
# writes one JSON file per suite and compares them with a baseline. docs/release-gate.md
# describes the suites, the rules and the variables below.
#
#   Tools/release-gate/run.sh [--baseline DIR] [--only corpus,context,cleanup,latency,sets,projects,retrieval,pairs] [--pairs ja,es] [--out DIR] [--skip-build]
#
# Without --only it runs every suite but pairs, the projects and retrieval suites too, which
# need the variables of docs/release-gate.md. pairs runs the context and latency suites
# again with each pair of --pairs chosen, Japanese and Spanish unless it names some. Exit
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
pairs_arg=""
out=""
build=1
while (( $# )); do
  case $1 in
    --baseline) baseline=${2:A}; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --pairs) pairs_arg=$2; shift 2 ;;
    --out) out=${2:A}; shift 2 ;;
    --skip-build) build=0; shift ;;
    -h|--help) sed -n '2,12p' $0; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
suites=(${(s:,:)only})
# The suites of the dictation pairs run after the others, in their own blocks below.
pair_suites_known=(pairs)
pair_suites=(${suites:*pair_suites_known})
suites=(${suites:|pair_suites_known})
if [[ -n $pairs_arg ]] && (( ! ${#pair_suites} )); then
  echo "--pairs needs pairs in --only" >&2
  exit 2
fi
for suite in $suites; do
  (( ${all_suites[(Ie)$suite]} )) || { echo "unknown suite $suite" >&2; exit 2 }
done

# Dictation pairs, context and latency: with pairs in --only, the context and latency
# suites run again for each pair of --pairs but Chinese, whose runs are those two suites,
# with the pair chosen. Korean joins when Orra has the pair.
typeset -A pair_languages=(ja Japanese es Spanish)
pair_sets=${GATE_PAIR_SETS_DIR:-$sets/pairs}
suite_pairs=()
if (( ${pair_suites[(Ie)pairs]} )); then
  suite_pairs=(${(s:,:)${pairs_arg:-ja,es}})
  # A pair named twice runs once.
  suite_pairs=(${(u)suite_pairs:#zh})
  for pair in $suite_pairs; do
    [[ -n ${pair_languages[$pair]:-} ]] || { echo "no dictation pair $pair: the pairs are zh, ja and es" >&2; exit 2 }
  done
fi
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

# Dictation pairs, context and latency, runs: each pair's results go to
# $out/pair-suites/<pair>, a results folder of its own, the latency suite with the pair's
# say clips and the English clips of the corpus.
for pair in $suite_pairs; do
  pair_out=$out/pair-suites/$pair
  mkdir -p $pair_out/raw
  for suite in context latency; do
    label=pairs-$pair-$suite
    env=(TEST_RUNNER_ORRA_GATE_OUT=$pair_out/raw TEST_RUNNER_ORRA_DICTATION_LANGUAGE=${pair_languages[$pair]})
    if [[ $suite == context ]]; then
      env+=(TEST_RUNNER_ORRA_CONTEXT_EVAL=1 TEST_RUNNER_ORRA_CONTEXT_COUNT=$context_count)
      test_id=OrraTests/RealModelTests/ContextEvaluationTests
    else
      env+=(TEST_RUNNER_ORRA_LATENCY=1 TEST_RUNNER_ORRA_LATENCY_CLIPS=$pair_sets/$pair-latency/clips
        TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$corpus TEST_RUNNER_ORRA_LATENCY_REPORT=$out/logs/$label-report.txt)
      test_id="OrraTests/LatencyMeasurementTests/dictations()"
    fi
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
    if [[ ! -s $pair_out/raw/$suite.json ]]; then
      echo "$label: no results (xcodebuild exit $code), see $out/logs/$label.log" >&2
      failed_to_run+=($label)
    else
      echo "$label: done $(date +%H:%M:%S), xcodebuild exit $code"
    fi
  done
done

python3 $repo/Tools/release-gate/gate.py summarize $out --sets $sets --projects-set $projects_set || exit 2
for pair in $suite_pairs; do
  python3 $repo/Tools/release-gate/gate.py summarize $out/pair-suites/$pair || exit 2
done

result=0
# The suites above, unless only the suites of the dictation pairs ran.
if [[ -n $baseline ]] && (( ${#suites} )); then
  python3 $repo/Tools/release-gate/gate.py compare $baseline $out --only ${(j:,:)suites} > $out/compare.txt
  result=$?
  cat $out/compare.txt
elif (( ${#suites} )); then
  # Exits 1 when the projects bar fails, which holds without a baseline.
  python3 $repo/Tools/release-gate/gate.py show $out | tee $out/summary.txt
  result=${pipestatus[1]}
fi
# Dictation pairs, context and latency, rules: each pair against the same pair of the
# baseline, by the rules of the two suites, and its numbers without a baseline.
for pair in $suite_pairs; do
  pair_out=$out/pair-suites/$pair
  echo "pair $pair, context and latency:"
  if [[ -n $baseline ]]; then
    python3 $repo/Tools/release-gate/gate.py compare $baseline/pair-suites/$pair $pair_out --only context,latency > $pair_out/compare.txt || result=1
    cat $pair_out/compare.txt
  else
    python3 $repo/Tools/release-gate/gate.py show $pair_out | tee $pair_out/summary.txt
  fi
done
if (( ${#failed_to_run} )); then
  echo "suites that did not run: ${failed_to_run[*]}" >&2
  exit 2
fi
exit $result
