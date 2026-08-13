#!/usr/bin/env bash
# Regression test for incident #2 in ../README.md ("a contaminated resume producing
# duplicate contradictory rows"): H1's run_h1_full.sh restarted from a crash and re-appended
# a result row mislabeled with the first checkpoint in its array, because its outer loop had
# no gate of its own and the "measure" phase had no per-checkpoint skip. Three runs:
#
#   1. Baseline (fixed mode, no crash) -- proves the test infrastructure itself is sound.
#   2. Fail-first (buggy mode, kill -9 + restart) -- proves this test CAN fail: the buggy
#      resume logic must produce duplicate/contradictory rows, or this test is worthless by
#      the harness's own governing rule (a fail-first that cannot fail voids everything
#      downstream, see ../../README.md).
#   3. The real assertion (fixed mode, kill -9 + restart) -- the actual resume logic
#      (matching h1-rss-list/run_h1_full.sh's fixed pattern) must produce exactly one row per
#      checkpoint, and the restart must have skipped already-complete checkpoints rather than
#      redone them.
#
# This exercises the RESUME PATTERN (extracted into fixtures/fake_driver.sh, see its header),
# not the real run_h1_full.sh -- that needs live Garage/MinIO containers, unavailable in CI.
# See ../README.md "What this does and does not prove".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/fixtures/fake_driver.sh"
FAIL=0

# Poll status.json until it reports the driver has reached (started measuring) a specific
# checkpoint, then return -- used instead of a fixed sleep so the kill point is deterministic
# regardless of host speed.
wait_for_checkpoint() {
  local workdir="$1" checkpoint="$2" phase="$3" timeout_s="${4:-10}"
  local deadline=$((SECONDS + timeout_s))
  while [ $SECONDS -lt $deadline ]; do
    if [ -f "$workdir/status.json" ]; then
      local cp phase_now
      cp=$(jq -r '.checkpoint // empty' "$workdir/status.json" 2>/dev/null)
      phase_now=$(jq -r '.phase // empty' "$workdir/status.json" 2>/dev/null)
      if [ "$cp" = "$checkpoint" ] && [ "$phase_now" = "$phase" ]; then
        return 0
      fi
    fi
    sleep 0.02
  done
  return 1
}

run_to_completion() {
  local workdir="$1" mode="${2:-}"
  timeout 15 "$DRIVER" "$workdir" "$mode"
}

run_with_crash_and_restart() {
  # Runs the driver, kills it -9 once it has completed checkpoint 10 and is measuring
  # checkpoint 20, then restarts it (same invocation) to completion.
  local workdir="$1" mode="${2:-}"
  "$DRIVER" "$workdir" "$mode" &
  local pid=$!
  if ! wait_for_checkpoint "$workdir" 20 measuring 10; then
    kill -9 "$pid" 2>/dev/null || true
    echo "FAIL: driver never reached checkpoint 20 measuring phase (test infra broken, not a real result)" >&2
    return 2
  fi
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  # Restart from the same (now-partial) state.
  timeout 15 "$DRIVER" "$workdir" "$mode"
}

assert_no_duplicate_checkpoints() {
  local file="$1" label="$2"
  local dupes
  dupes=$(jq -r '.checkpoint' "$file" | sort | uniq -d)
  if [ -n "$dupes" ]; then
    echo "  duplicate checkpoint rows in $label: $dupes"
    return 1
  fi
  return 0
}

assert_all_checkpoints_present() {
  local file="$1" label="$2"
  local got
  got=$(jq -r '.checkpoint' "$file" | sort -n | tr '\n' ' ')
  if [ "$got" != "10 20 30 40 " ]; then
    echo "  $label has wrong checkpoint set: got [$got], want [10 20 30 40 ]"
    return 1
  fi
  return 0
}

echo "=== Test 1/3: baseline, fixed mode, no crash (proves the harness itself works) ==="
W1=$(mktemp -d)
run_to_completion "$W1"
if assert_no_duplicate_checkpoints "$W1/extra-results.jsonl" "baseline extra-results.jsonl" \
   && assert_all_checkpoints_present "$W1/extra-results.jsonl" "baseline extra-results.jsonl"; then
  echo "PASS: baseline run produced exactly one row per checkpoint, no crash involved"
else
  echo "SUMMARY test=checkpoint-resume-baseline verdict=DETECTOR-BROKEN"
  echo "FAIL: baseline (no-crash) run is not even self-consistent -- fix the test harness before trusting anything else here"
  FAIL=1
fi
rm -rf "$W1"

echo
echo "=== Test 2/3: fail-first -- buggy resume logic MUST produce duplicates after a crash+restart ==="
W2=$(mktemp -d)
run_with_crash_and_restart "$W2" --buggy
if assert_no_duplicate_checkpoints "$W2/extra-results.jsonl" "buggy extra-results.jsonl" 2>/dev/null; then
  echo "SUMMARY test=checkpoint-resume-failfirst verdict=DETECTOR-BROKEN"
  echo "FAIL: buggy resume logic did NOT produce duplicate rows -- this test cannot distinguish"
  echo "      fixed from broken resume logic, so its 'PASS' on the real assertion below proves"
  echo "      nothing (per this harness's own governing rule: a fail-first that cannot fail"
  echo "      voids everything downstream)."
  FAIL=1
else
  echo "SUMMARY test=checkpoint-resume-failfirst verdict=DETECTOR-OK"
  echo "PASS: buggy resume logic reproduces the real incident -- duplicate/contradictory rows"
  echo "      after crash+restart, exactly as documented in RESULTS-H1-completion.md. This is"
  echo "      what proves Test 3's PASS below is actually meaningful."
fi
rm -rf "$W2"

echo
echo "=== Test 3/3: the real assertion -- fixed resume logic must NOT produce duplicates ==="
W3=$(mktemp -d)
run_with_crash_and_restart "$W3" ""
ok=1
assert_no_duplicate_checkpoints "$W3/extra-results.jsonl" "fixed extra-results.jsonl" || ok=0
assert_all_checkpoints_present "$W3/extra-results.jsonl" "fixed extra-results.jsonl" || ok=0
if ! grep -q "resume_from_idx=1" "$W3/driver.log"; then
  echo "  restart did not resume past checkpoint 10 (resume_from_idx should be 1, not 0) -- it re-walked from the start"
  ok=0
fi
if [ "$ok" = "1" ]; then
  echo "SUMMARY test=checkpoint-resume-real verdict=PASS"
  echo "PASS: crash after checkpoint 10 + restart produced exactly one row per checkpoint, and"
  echo "      the restart correctly resumed from checkpoint 20 rather than re-measuring checkpoint 10."
else
  echo "SUMMARY test=checkpoint-resume-real verdict=FAIL"
  echo "FAIL: the fixed resume logic (matching h1-rss-list/run_h1_full.sh's pattern) did not"
  echo "      hold up under crash+restart -- see output above."
  FAIL=1
fi
rm -rf "$W3"

echo
if [ "$FAIL" = "0" ]; then
  echo "OVERALL: PASS -- all three checks (baseline, fail-first, real assertion) succeeded"
else
  echo "OVERALL: FAIL"
fi
exit "$FAIL"
