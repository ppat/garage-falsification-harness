# Resume-and-restart correctness

A harness whose results can be silently corrupted by a restart is not trustworthy. That
happened here three times, by three different mechanisms, all during H1's completion run (see
`../RESULTS-H1-completion.md` for the full, unvarnished account of each):

1. **A bare SSH-backgrounded process died when its session ended.** The first attempt at H1's
   completion run was launched as a plain background job over an interactive SSH session, with
   no supervision. When the session ended, the process died with it. Verified directly on
   resumption: zero containers, zero loader processes, zero result files — a clean slate, not a
   resumable one. Nothing was lost that a real result depended on, only because nothing had
   been produced yet.
2. **A contaminated resume produced duplicate, contradictory rows.** After moving to a
   `systemd`-supervised design, a crash mid-run triggered an automatic restart whose resume
   logic had a real bug: the outer checkpoint loop always started from index 0, and while the
   *write* phase correctly skipped already-written objects, the *measurement* phase had no such
   skip. Each restart re-measured a store that already held ~2,000,000 objects and appended a
   new result row still labelled `"checkpoint": 100000` — three contaminated rows landed in the
   real results file this way before being caught and quarantined.
3. **Two agents concurrently drove the same benchmark, each reading the other's actions as an
   external actor.** During recovery from incident #2, a second, independent session was
   working the same VM at the same time, issuing its own `systemctl stop`/`start` and
   `kill -9` calls. Neither session had any way to know the other existed; one escalated toward
   a privileged container (`--pid host` + a mounted Docker socket) before being denied by the
   platform's own safety classifier.

This directory is the response: a test for each mechanism, extracted into small, fast,
self-contained fixtures so they can run in CI without needing the real Docker VM or
Garage/MinIO containers the actual H-tests depend on. Every test here follows this harness's
own governing rule (see the top-level `README.md`): **a fail-first that cannot fail voids
everything downstream.** Each script below proves its own detector can fail — on a
deliberately-broken fixture — before trusting that its "PASS" on the fixed version means
anything. This was not a formality: `lib/single-owner-lock.sh`'s first draft had a real bug
(used `$$` instead of `${BASHPID:-$$}`, which breaks lock ownership tracking for any lock
acquired from inside a subshell) that its own stale-lock-reclaim fail-first caught during
development, before this ever reached the test suite you're reading now. See that file's
comment for the fix.

## The three tests

| Incident | Test | What it exercises |
| --- | --- | --- |
| #1 — session death | `test_process_survival.sh` | Dynamic: does a process survive `SIGHUP` — the actual mechanism `nohup`/`setsid`/systemd all rely on. Static: a linter for the exact `StartLimitIntervalSec`-in-the-wrong-section incident from H1's own unit file. |
| #2 — contaminated resume | `test_checkpoint_resume.sh` | A crash-and-restart against `fixtures/fake_driver.sh`, a distilled model of `../h1-rss-list/run_h1_full.sh`'s actual (fixed) resume idiom, run in both buggy and fixed mode. |
| #3 — concurrent drivers | `test_single_owner_lock.sh` | `lib/single-owner-lock.sh`, a liveness-checked lockfile any future long-running driver can adopt, exercised for correct rejection, stale-lock recovery, and cross-host safety. |

Run them all:

```bash
for t in test_*.sh; do bash "$t" || echo "FAILED: $t"; done
```

Each is also wired into this repo's CI (`.github/workflows/test-resume-restart.yaml`) — see
the top-level README's "CI" section for why these three are CI-worthy and the H-tests
themselves are not.

## What this does and does not prove

Be honest about the gap between "a mechanism is exercised" and "the real incident cannot
recur" — that gap is exactly where the false confidence in incidents #2 and #3 came from.

- **Incident #2 (contaminated resume) is the one this fully, faithfully exercises.** The bug
  was a pure logic defect in a bash script's resume-gating idiom, with no dependency on real
  infrastructure. `fixtures/fake_driver.sh` extracts that exact idiom (gate checkpoint
  completeness on the terminal artifact file, not on loop position) at a scale that runs in
  under two seconds, so the crash-and-restart cycle can run for real, deterministically
  (synchronized via a polled `status.json`, not a timing guess), in CI on every PR. This is not
  a simulation of the bug — running `fixtures/fake_driver.sh` in `--buggy` mode against a
  crash+restart reproduces the actual defect shape.
- **Incident #3 (concurrent drivers) is partially exercised.** `lib/single-owner-lock.sh` is
  mechanically tested — a second concurrent acquire is genuinely rejected, a crashed holder's
  lock is genuinely reclaimed, a different host's lock is genuinely left alone. What is **not**
  and **cannot** be tested here: whether a future agent or session actually calls
  `acquire_lock` before touching a shared long-running resource, or whether it respects a
  rejection instead of working around it (the real incident's escalation attempt — `--pid host`
  plus a mounted Docker socket — was exactly an attempt to route around a blocked action, not a
  failure of any lock). A lock is a mechanical guardrail; it cannot substitute for "never
  dispatch a second agent onto a resource an existing one still owns" as an operating
  discipline. Any future long-running driver built on this harness's pattern should call
  `acquire_lock` before starting — that adoption is a design decision for that driver, not
  something this test suite can force.
- **Incident #1 (session death) is exercised at the level of its actual mechanism, not as a
  full end-to-end simulation.** The real incident happened because a background job's
  controlling terminal went away when an SSH session closed. This test does not spin up a real
  `sshd`/pty pair and disconnect it — that would be a materially heavier, more environment-
  dependent test for a property that reduces to one thing: does the process survive receiving
  `SIGHUP`. That is the actual, necessary-and-sufficient mechanism `nohup`, `setsid`, and
  "systemd unit, supervised by PID 1" (the design H1's completion run actually used) all rely
  on, so testing it directly is faithful to the mechanism, not merely adjacent to it — but it
  is fair to call this "the mechanism, exercised in isolation" rather than "the incident,
  reproduced end-to-end." The static half (the `StartLimitIntervalSec` section-placement
  linter) is a narrow, literal regression test for one specific documented mistake, not a
  general systemd-unit correctness checker.

## Why a library here, not a retrofit of the real scripts

`lib/single-owner-lock.sh` is a new, freestanding utility, not a patch to
`h1-rss-list/run_h1_full.sh` or any other H-test driver — none of them call it. Retrofitting it
into H1's own script would mean carrying and testing a change to code whose real job is already
done (H1 is complete, see `../RESULTS-H1-completion.md`), for a benefit that only matters to
*future* long-running drivers. The adoption point is the next test built on this harness's
pattern (a future H-test, or a from-scratch driver elsewhere in this estate): source this file,
call `acquire_lock` before starting, `release_lock` on exit. H4-D
(`../h4-lifecycle-expiration/h4d_inline_steady_state.py`) already independently arrived at a
good instance of the same underlying property (checkpointed, atomic-write, resumable state,
proven by an actual pod restart mid-run resuming cleanly — see `../H4-INLINE-RECLAMATION.md`),
built before this move and without this library; it's a second real-world data point that the
underlying pattern is sound, from a different implementation.
