#!/usr/bin/env bash
# Regression test for lib/single-owner-lock.sh (incident #3, see ../README.md). Four checks:
#
#   1. Fail-first: two concurrent writers with NO lock protection at all corrupt a shared
#      counter (lost updates) -- proves the danger this library exists to prevent is real,
#      not hypothetical, before trusting that the library's rejection actually matters.
#   2. The real assertion: with the lock in place, a second concurrent acquire on the same
#      host is rejected while the first holder is still alive.
#   3. Stale-lock reclaim: a lock left behind by a killed (crashed) process is NOT permanently
#      stuck -- a subsequent acquire succeeds. This matters because every incident this
#      library responds to involved a crash, not a clean shutdown.
#   4. Cross-host safety: a lock recorded under a different hostname is never silently
#      overwritten (this library cannot check liveness on a host it isn't running on).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/single-owner-lock.sh
source "$HERE/lib/single-owner-lock.sh"
FAIL=0
W=$(mktemp -d)

echo "=== Test 1/4: fail-first -- unprotected concurrent writers corrupt shared state ==="
COUNTER="$W/counter"
echo 0 > "$COUNTER"
racer() {
  local n
  n=$(cat "$COUNTER")
  sleep 0.05
  echo $((n + 1)) > "$COUNTER"
}
racer & racer & racer & racer & racer &
wait
final=$(cat "$COUNTER")
if [ "$final" -eq 5 ]; then
  echo "SUMMARY test=lock-failfirst verdict=DETECTOR-BROKEN"
  echo "FAIL: 5 unprotected concurrent writers landed on the correct answer (5) -- the race"
  echo "      didn't actually race on this host/timing, so Test 2 below proves nothing about"
  echo "      whether the lock is doing real work. (Non-deterministic by nature; re-run if seen.)"
  FAIL=1
else
  echo "SUMMARY test=lock-failfirst verdict=DETECTOR-OK"
  echo "PASS: unprotected writers lost updates (final=$final, expected 5 if race-free) --"
  echo "      confirms concurrent access without protection really does corrupt shared state."
fi

echo
echo "=== Test 2/4: real assertion -- second concurrent acquire is rejected while first lives ==="
LOCK="$W/driver.lock"
(
  acquire_lock "$LOCK" || exit 1
  sleep 2
) &
HOLDER_PID=$!
# Wait for the holder to actually claim the lock before racing the second acquire against it.
for _ in $(seq 1 100); do
  [ -f "$LOCK" ] && break
  sleep 0.02
done
if acquire_lock "$LOCK" 2>/tmp/second-acquire.err; then
  echo "FAIL: second acquire_lock succeeded while the first holder was still alive"
  release_lock "$LOCK"
  FAIL=1
else
  echo "PASS: second acquire_lock correctly refused: $(cat /tmp/second-acquire.err)"
fi
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null
rm -f "$LOCK" /tmp/second-acquire.err

echo
echo "=== Test 3/4: stale-lock reclaim -- a crashed holder's lock is recoverable ==="
LOCK2="$W/crashed.lock"
(
  acquire_lock "$LOCK2" || exit 1
  sleep 30
) &
CRASH_PID=$!
for _ in $(seq 1 100); do
  [ -f "$LOCK2" ] && break
  sleep 0.02
done
kill -9 "$CRASH_PID" 2>/dev/null || true
wait "$CRASH_PID" 2>/dev/null
# The lockfile is still on disk (crash left no chance to clean up) but its PID is dead.
if acquire_lock "$LOCK2"; then
  echo "PASS: acquire_lock reclaimed a lock left behind by a killed (crashed) holder"
  release_lock "$LOCK2"
else
  echo "FAIL: acquire_lock refused to reclaim a stale lock from a dead PID -- a real crash"
  echo "      would permanently wedge this lock, which is worse than no lock at all"
  FAIL=1
fi

echo
echo "=== Test 4/4: cross-host safety -- a lock recorded on a different host is never silently taken ==="
LOCK3="$W/otherhost.lock"
printf '{"host": "some-other-host-not-this-one", "pid": 999999, "started": "2020-01-01T00:00:00Z"}\n' > "$LOCK3"
if acquire_lock "$LOCK3" 2>/tmp/crosshost.err; then
  echo "FAIL: acquire_lock silently took over a lock recorded on a different host"
  FAIL=1
else
  echo "PASS: acquire_lock correctly refused a different host's lock: $(cat /tmp/crosshost.err)"
fi
rm -f "$LOCK3" /tmp/crosshost.err

rm -rf "$W"
echo
if [ "$FAIL" = "0" ]; then
  echo "OVERALL: PASS"
else
  echo "OVERALL: FAIL"
fi
exit "$FAIL"
