#!/usr/bin/env bash
# Minimal, fast model of h1-rss-list/run_h1_full.sh's checkpoint-resume idiom, used to
# regression-test that idiom without needing real Garage/MinIO containers (which the actual
# script needs, and which CI does not have). See ../README.md for exactly what this does and
# does not prove about the real script.
#
# Two phases per checkpoint, matching the real script's shape:
#   - "write": idempotent, gated on its own per-checkpoint record in $LOADER_FILE (models
#     loader.py's next_index-based skip, which was always correct).
#   - "measure": in FIXED mode, the whole checkpoint (both phases) is skipped once
#     $EXTRA_FILE already has a row for it -- $EXTRA_FILE is written last, so its presence
#     proves the whole cycle finished (this is the actual fix, see run_h1_full.sh's own
#     comment). In --buggy mode, that outer gate is removed: the loop always starts from
#     CHECKPOINTS[0], and since "measure" has no per-checkpoint skip of its own, a restart
#     re-runs and re-appends a "measure" row for whichever checkpoint the loop is currently
#     at -- this is the exact defect documented in RESULTS-H1-completion.md's
#     "run_h1_full.sh's actual bug, and the fix".
#
# status.json is polled by the test harness to synchronize a kill -9 against a specific point
# in the run, instead of a timing-based sleep.
set -uo pipefail

WORKDIR="${1:?usage: fake_driver.sh WORKDIR [--buggy]}"
MODE="${2:-}"
cd "$WORKDIR" || exit 1

CHECKPOINTS=(10 20 30 40)
LOADER_FILE=loader-results.jsonl
EXTRA_FILE=extra-results.jsonl
touch "$LOADER_FILE" "$EXTRA_FILE"

status() {
  printf '{"checkpoint": %s, "phase": "%s"}\n' "$1" "$2" > status.json.tmp
  mv status.json.tmp status.json
}

extra_has() {
  jq -e --argjson cp "$1" 'select(.checkpoint == $cp)' "$EXTRA_FILE" >/dev/null 2>&1
}
loader_has() {
  jq -e --argjson cp "$1" 'select(.checkpoint == $cp)' "$LOADER_FILE" >/dev/null 2>&1
}

RESUME_FROM=0
if [ "$MODE" != "--buggy" ]; then
  for idx in "${!CHECKPOINTS[@]}"; do
    c="${CHECKPOINTS[$idx]}"
    if extra_has "$c"; then
      RESUME_FROM=$((idx + 1))
    else
      break
    fi
  done
fi

echo "$(date -Is) starting, mode=${MODE:-fixed} resume_from_idx=$RESUME_FROM" >> driver.log

for c in "${CHECKPOINTS[@]:$RESUME_FROM}"; do
  status "$c" starting
  if ! loader_has "$c"; then
    sleep 0.15
    echo "{\"checkpoint\": $c, \"ts\": $(date +%s.%N)}" >> "$LOADER_FILE"
  fi
  status "$c" measuring
  sleep 0.15
  echo "{\"checkpoint\": $c, \"ts\": $(date +%s.%N)}" >> "$EXTRA_FILE"
  echo "$(date -Is) checkpoint $c complete" >> driver.log
  status "$c" complete
done

echo "$(date -Is) all-done" >> driver.log
status "${CHECKPOINTS[-1]}" all-done
