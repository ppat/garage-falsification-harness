#!/usr/bin/env bash
# Regression test for incident #1 in ../README.md: H1's first run was launched as a bare
# background process over an interactive SSH session and died when that session ended --
# silently, with nothing left running and nothing to resume from (verified directly: "zero
# containers, zero loader processes, zero result files", RESULTS-H1-completion.md "Why this
# is a restart (second one)").
#
# Two checks, deliberately split because they test different things:
#
#   1. Dynamic (test_survives_sighup below): the actual mechanism nohup/setsid/systemd all
#      rely on -- a process's disposition to SIGHUP. A bare backgrounded job has the default
#      SIGHUP disposition (terminate); this is the necessary and sufficient condition for
#      "dies when its session ends" -- see ../README.md "What this does and does not prove"
#      for why this is a faithful test of the mechanism and NOT a full SSH-disconnect
#      simulation (no pty/sshd involved).
#   2. Static (test_unit_file_lint below): a linter for the exact documented incident where a
#      systemd directive silently no-ops from the wrong section
#      (RESULTS-H1-completion.md's "StartLimitIntervalSec=0 was silently not taking effect...
#      placed in [Service]"). Includes its own fail-first: the linter must correctly flag a
#      known-buggy fixture before its PASS on the known-good one means anything.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0

echo "=== Check 1/2: does the process survive a SIGHUP? ==="
echo "--- 1a. fail-first: a bare backgrounded job has NO protection and must die ---"
bash -c 'sleep 20' &
BARE_PID=$!
disown "$BARE_PID" 2>/dev/null || true
sleep 0.2
kill -HUP "$BARE_PID" 2>/dev/null
sleep 0.3
if kill -0 "$BARE_PID" 2>/dev/null; then
  echo "SUMMARY test=process-survival-failfirst verdict=DETECTOR-BROKEN"
  echo "FAIL: a bare 'command &' with no HUP protection survived SIGHUP -- this shell/host's"
  echo "      default SIGHUP disposition is not what this check assumes; its PASS below on"
  echo "      the protected case would prove nothing"
  kill -9 "$BARE_PID" 2>/dev/null
  FAIL=1
else
  echo "SUMMARY test=process-survival-failfirst verdict=DETECTOR-OK"
  echo "PASS: unprotected background job died on SIGHUP, as a bare SSH-backgrounded process"
  echo "      would when its session hangs up -- this is the real, documented H1 failure mode"
fi

echo
echo "--- 1b. real assertion: nohup-protected (the minimum bar; setsid/systemd also qualify) survives ---"
nohup bash -c 'sleep 20' >/dev/null 2>&1 &
PROT_PID=$!
disown "$PROT_PID" 2>/dev/null || true
sleep 0.2
kill -HUP "$PROT_PID" 2>/dev/null
sleep 0.3
if kill -0 "$PROT_PID" 2>/dev/null; then
  echo "SUMMARY test=process-survival-real verdict=PASS"
  echo "PASS: nohup-protected process survived SIGHUP -- this is the mechanism nohup, setsid,"
  echo "      and 'systemd unit, supervised by PID 1' (the design actually used for H1's"
  echo "      completion run, see RESULTS-H1-completion.md) all rely on"
  kill -9 "$PROT_PID" 2>/dev/null
else
  echo "SUMMARY test=process-survival-real verdict=FAIL"
  echo "FAIL: nohup-protected process died on SIGHUP -- nohup itself is not working as expected"
  FAIL=1
fi

echo
echo "=== Check 2/2: static lint -- StartLimitIntervalSec must be in [Unit], not [Service] ==="
# A directive is read from whichever section it's textually under; this reads that section
# the crude-but-correct way (state machine over lines), matching how systemd itself parses
# ini-style unit files section-by-section.
section_for_key() {
  local file="$1" key="$2" section=""
  while IFS= read -r line; do
    case "$line" in
      '['*']') section="${line}" ;;
      "$key"=*) [ -n "$section" ] && { echo "$section"; return 0; } ;;
    esac
  done < "$file"
  return 1
}

echo "--- 2a. fail-first: the linter must flag the known-buggy fixture ---"
got=$(section_for_key "$HERE/fixtures/reference-driver-buggy.service" "StartLimitIntervalSec")
if [ "$got" = "[Unit]" ]; then
  echo "SUMMARY test=unit-lint-failfirst verdict=DETECTOR-BROKEN"
  echo "FAIL: the buggy fixture (StartLimitIntervalSec under [Service]) was read as [Unit] --"
  echo "      the linter cannot tell the sections apart, so its PASS below proves nothing"
  FAIL=1
elif [ "$got" = "[Service]" ]; then
  echo "SUMMARY test=unit-lint-failfirst verdict=DETECTOR-OK"
  echo "PASS: linter correctly identified the buggy fixture's misplaced directive as [Service]"
  echo "      -- exactly reproducing the real incident (systemd silently ignores it there)"
else
  echo "SUMMARY test=unit-lint-failfirst verdict=DETECTOR-BROKEN"
  echo "FAIL: linter found StartLimitIntervalSec in neither section (got: '$got')"
  FAIL=1
fi

echo
echo "--- 2b. real assertion: the reference (fixed) unit has it under [Unit] ---"
got=$(section_for_key "$HERE/fixtures/reference-driver.service" "StartLimitIntervalSec")
if [ "$got" = "[Unit]" ]; then
  echo "SUMMARY test=unit-lint-real verdict=PASS"
  echo "PASS: reference-driver.service has StartLimitIntervalSec under [Unit], where systemd"
  echo "      actually reads it"
else
  echo "SUMMARY test=unit-lint-real verdict=FAIL"
  echo "FAIL: reference-driver.service has StartLimitIntervalSec under '$got', not [Unit] --"
  echo "      systemd would silently ignore it (log 'Unknown key... ignoring') and fall back"
  echo "      to the compiled default (10s / 5 restarts), exactly the documented incident"
  FAIL=1
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "OVERALL: PASS"
else
  echo "OVERALL: FAIL"
fi
exit "$FAIL"
