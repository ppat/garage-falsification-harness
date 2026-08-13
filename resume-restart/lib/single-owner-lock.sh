#!/usr/bin/env bash
# Regression fix for incident #3 in ../README.md: two agents independently drove H1's
# systemd unit at the same time, each reading the other's `systemctl stop`/`start` and
# `docker version` calls as an external actor -- one escalated toward a privileged container
# before being denied. Neither agent had any way to know the other existed.
#
# This is a mechanical, best-effort partial fix: a liveness-checked lockfile any long-running
# driver can acquire before starting, so a second concurrent instance gets a clear "already
# running, owned by X since Y" refusal instead of silently racing. It cannot make two humans
# or agents coordinate -- see ../README.md "What this does and cannot do" for what it
# actually covers.
#
# Usage (source this file, then):
#   acquire_lock "$LOCKFILE" || exit 1   # refuses and prints the current owner if held
#   trap 'release_lock "$LOCKFILE"' EXIT
set -uo pipefail

# Acquires $1 as an exclusive, liveness-checked lock for the current process. Prints an error
# and returns 1 if another live process already holds it. A lockfile whose recorded PID is no
# longer running (e.g. the prior owner crashed without cleaning up) is treated as stale and
# reclaimed -- this matters because a driver crash (kill -9, VM hard-reset) is exactly the
# scenario this whole harness has hit repeatedly, and a lock that can never be recovered from
# a crash is worse than no lock.
acquire_lock() {
  local lockfile="$1"
  local host pid started

  if [ -f "$lockfile" ]; then
    host=$(jq -r '.host // empty' "$lockfile" 2>/dev/null)
    pid=$(jq -r '.pid // empty' "$lockfile" 2>/dev/null)
    started=$(jq -r '.started // empty' "$lockfile" 2>/dev/null)

    if [ -n "$pid" ] && [ "$host" = "$(hostname)" ] && kill -0 "$pid" 2>/dev/null; then
      echo "acquire_lock: already held by PID $pid on $host since $started ($lockfile)" >&2
      return 1
    fi
    if [ -n "$pid" ] && [ "$host" = "$(hostname)" ]; then
      echo "acquire_lock: stale lock (PID $pid on $host no longer running, started $started) -- reclaiming" >&2
      # ln below requires the target to not exist -- a stale lockfile left on disk by a
      # crashed holder must be cleared before the atomic claim, not just judged stale. This
      # still leaves a narrow TOCTOU window (another process could win the race immediately
      # after this rm and before this process's own ln) -- acceptable here because that race
      # is exactly what the ln-based atomic claim below is for: the loser gets a clear
      # "lost the race" error instead of silently corrupting shared state.
      rm -f "$lockfile"
    elif [ -n "$host" ] && [ "$host" != "$(hostname)" ]; then
      # Different host: cannot check liveness locally. Refuse rather than guess -- an
      # operator can remove the lockfile by hand if they've confirmed the other host is
      # really gone, but this library will not do that silently.
      echo "acquire_lock: lock recorded on a different host ($host, PID $pid, since $started)" \
           " -- refusing; remove $lockfile by hand only after confirming that host is not running this driver" >&2
      return 1
    fi
  fi

  # Atomic claim: write to a temp file then hardlink (fails if the target now exists,
  # closing the race between the check above and this claim -- two processes reaching this
  # point at the same instant cannot both win).
  # BASHPID, not $$: inside a `( ... ) &` subshell, bash keeps $$ pointed at the top-level
  # shell's PID (a long-standing bash quirk), so a lock acquired from a subshell would record
  # an owner PID that stays alive long after the subshell -- and thus the actual lock holder
  # -- has exited or been killed, permanently wedging the lock. Caught by this library's own
  # test 3 (stale-lock reclaim) failing during development; see ../test_single_owner_lock.sh.
  local tmp
  tmp="$(mktemp "${lockfile}.XXXXXX")"
  printf '{"host": "%s", "pid": %s, "started": "%s"}\n' "$(hostname)" "${BASHPID:-$$}" "$(date -Is)" > "$tmp"
  if ln "$tmp" "$lockfile" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  echo "acquire_lock: lost the race to claim $lockfile (another process claimed it first)" >&2
  return 1
}

release_lock() {
  local lockfile="$1"
  local pid
  pid=$(jq -r '.pid // empty' "$lockfile" 2>/dev/null)
  # Only remove a lock this process actually owns -- never blindly rm someone else's. See
  # acquire_lock's comment on BASHPID vs $$.
  if [ "$pid" = "${BASHPID:-$$}" ]; then
    rm -f "$lockfile"
  fi
}
