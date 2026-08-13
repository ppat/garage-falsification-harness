#!/usr/bin/env bash
# H1 completion run: reproduces the full checkpoint curve (100k/500k/1M/2M/3,439,460) in one
# continuous, uninterrupted pass on freshly-bootstrapped Garage and MinIO instances.
#
# Why fresh instead of resuming: the prior attempt's `h1-garage` container lost its bucket
# and access key entirely to an unrelated VM hard-reset used for H2 (see RESULTS.md's H1/H2
# sections) -- `garage bucket list`/`garage key list` came back empty even though the node
# identity and cluster layout survived, so there was nothing left to resume from on the
# Garage side. Rather than splice a fresh Garage curve onto a stale/partially-corrupted MinIO
# instance, both were wiped and reloaded from index 0 together so every checkpoint in this
# run comes from the same instance lifecycle on both sides (apples-to-apples, no restart
# discontinuity to caveat).
#
# Unlike loader.py's own multi-checkpoint invocations (comma-separated --checkpoints), this
# script invokes loader.py ONCE PER CHECKPOINT so there is a clean, non-racing window after
# both targets finish writing+measuring in which to run measure_extra.py (RSS anon/file
# split + du) against a stable object count, before starting the next checkpoint's writes.
#
# Requires GARAGE_ACCESS_KEY / GARAGE_SECRET_KEY in the environment (from `garage key info`
# after bootstrap -- see the "Rerun" section of RESULTS-H1-completion.md for the exact
# bootstrap sequence used).
set -euo pipefail
cd "$(dirname "$0")"

: "${GARAGE_ACCESS_KEY:?set GARAGE_ACCESS_KEY}"
: "${GARAGE_SECRET_KEY:?set GARAGE_SECRET_KEY}"

CHECKPOINTS=(100000 500000 1000000 2000000 3439460)
WORKERS="${WORKERS:-128}"

status() {
  # Single-command "is it still running / how far did it get" answer -- see
  # RESULTS-H1-completion.md's "How to check on this run" for how this is read.
  printf '{"checkpoint": %s, "phase": "%s", "ts": "%s"}\n' "$1" "$2" "$(date -Is)" > status.json
}

# --- resume logic -----------------------------------------------------------------------
# A checkpoint counts as fully complete only when h1-extra-results.jsonl has a row for it:
# that file is written LAST in a checkpoint's cycle (after loader.py's write+RSS+LIST phase
# for both targets), so its presence proves the whole cycle finished, not just that objects
# got written. Restarting this script used to always re-run the CHECKPOINTS array from index
# 0: loader.py's own per-target `next_index` check correctly skipped re-writing objects, but
# its measurement phase always re-runs regardless, so a restart re-measured an already-loaded
# store and re-appended a result row still labelled with the FIRST checkpoint in the array --
# e.g. a store already holding 2,000,000 objects producing rows labelled "checkpoint": 100000.
# That mislabelling is what actually happened here on 2026-08-12 (see
# RESULTS-H1-completion.md); the bad rows were moved to *-results-contaminated.jsonl.
extra_results_has() {
  local cp="$1"
  [ -s h1-extra-results.jsonl ] && jq -e --argjson cp "$cp" 'select(.checkpoint == $cp)' h1-extra-results.jsonl >/dev/null 2>&1
}

# Loader-phase (write+RSS+LIST) results already recorded for this checkpoint, independent of
# whether the extra measurement also completed -- lets a restart skip loader.py entirely
# (rather than re-invoking it just to have it skip the write and re-measure anyway) when only
# measure_extra.py's phase is what's missing, e.g. exactly the 2,000,000 case above.
loader_results_has() {
  local file="$1" cp="$2"
  [ -s "$file" ] && jq -e --argjson cp "$cp" 'select(.checkpoint == $cp)' "$file" >/dev/null 2>&1
}

RESUME_FROM=0
for idx in "${!CHECKPOINTS[@]}"; do
  c="${CHECKPOINTS[$idx]}"
  if extra_results_has "$c"; then
    RESUME_FROM=$((idx + 1))
  else
    break
  fi
done

if [ "$RESUME_FROM" -gt 0 ]; then
  echo "=== [$(date -Is)] resuming: checkpoints [${CHECKPOINTS[*]:0:$RESUME_FROM}] already complete per h1-extra-results.jsonl, skipping ===" | tee -a run_h1_full.log
fi
# --- end resume logic --------------------------------------------------------------------

status 0 starting

for c in "${CHECKPOINTS[@]:$RESUME_FROM}"; do
  if loader_results_has garage-results.jsonl "$c" && loader_results_has minio-results.jsonl "$c"; then
    echo "=== [$(date -Is)] checkpoint $c: write+measure already recorded for both targets, skipping loader.py, running only measure_extra.py ===" | tee -a run_h1_full.log
    status "$c" measuring
  else
    echo "=== [$(date -Is)] checkpoint $c: starting write+measure phase for both targets ===" | tee -a run_h1_full.log
    status "$c" writing

    python3 loader.py --name garage --endpoint http://127.0.0.1:13900 \
        --access-key "$GARAGE_ACCESS_KEY" --secret-key "$GARAGE_SECRET_KEY" \
        --bucket h1falsify --container h1-garage \
        --checkpoints "$c" --workers "$WORKERS" >> garage-loader.log 2>&1 &
    GPID=$!

    python3 loader.py --name minio --endpoint http://127.0.0.1:19000 \
        --access-key h1falsify --secret-key h1falsify-minio-password \
        --bucket h1falsify --container h1-minio \
        --checkpoints "$c" --workers "$WORKERS" >> minio-loader.log 2>&1 &
    MPID=$!

    set +e
    wait "$GPID"; GRC=$?
    wait "$MPID"; MRC=$?
    set -e
    if [ "$GRC" -ne 0 ] || [ "$MRC" -ne 0 ]; then
      echo "=== [$(date -Is)] checkpoint $c: LOADER FAILED garage_rc=$GRC minio_rc=$MRC -- see garage-loader.log/minio-loader.log ===" | tee -a run_h1_full.log
      exit 1
    fi

    echo "=== [$(date -Is)] checkpoint $c: both loaders done, running extra measurement ===" | tee -a run_h1_full.log
    status "$c" measuring
  fi

  python3 measure_extra.py --checkpoint "$c" | tee -a run_h1_full.log
  echo "=== [$(date -Is)] checkpoint $c: COMPLETE ===" | tee -a run_h1_full.log
  status "$c" complete
done

echo "=== [$(date -Is)] ALL CHECKPOINTS DONE ===" | tee -a run_h1_full.log
status "${CHECKPOINTS[-1]}" all-done
