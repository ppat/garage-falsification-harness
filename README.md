# Garage falsification harness

This harness tried to break the decision to replace MinIO with Garage
(`dxflrs/garage:v2.3.0`) for a homelab estate's object storage, before that decision was
committed to. It is not a demo of Garage working — it is a set of tests whose job was to
produce a **no**, run against the real measured production baseline:

- 13.58 GB live across **3,439,460 objects**, 95.4% under 1 KB, mean 3.9 KB
- ~2.17 ops/sec total, **LIST is 86%** of it (`listobjectsv2` 1.858/s, `deleteobject` 0.191/s,
  `putobject` 0.073/s, `getobject` 0.043/s)
- MinIO's measured cost: 52–59m CPU, ~12,344 MiB RSS, and **~44 GB on disk against 13.58 GB
  live (3.2× amplification)** — versioning is on, only plain `Expiration` rules exist, so
  deletes leave delete markers and noncurrent versions are never reclaimed

The engine decision this harness informed has been made — Garage. What endures past that
decision is the **method**: pre-registered kill criteria, fail-first detectors proven able to
fail, control arms, and adjudication of results that looked decisive and weren't. That's why
this lives in its own repository rather than staying folded into the GitOps repo it was
originally built inside.

## Provenance

This harness was built inside `ppat/homelab-ops-kubernetes-apps`, at
`ci/experiments/garage-falsification/`, because that's where the MinIO→Garage migration work
was happening (tracking issue:
[`ppat/homelab-ops-kubernetes-apps#3611`](https://github.com/ppat/homelab-ops-kubernetes-apps/issues/3611)).
It moved here once the engine decision it informed was made, because it was never deployable
GitOps config — it's experiment code, and the apps repo's CI, lint gates, release-please
config, and module conventions all treated it as an awkward exception.

**What this repo's history does not show**: this move reconciles two branches of that repo
that diverged from the same commit and never merged. `experiment/garage-falsification`
(commit `6453becb`) added the original harness. From there, `fix/garage-falsification-corrections`
(PR [#3626](https://github.com/ppat/homelab-ops-kubernetes-apps/pull/3626), commit `a6f11e67`)
corrected `RESULTS.md` after an independent adjudication found two fired kill criteria were
test defects, not Garage defects (see "What broke and what it means" below) — but that branch
was never merged, so it never saw H4-D. Separately, `experiment/garage-falsification` kept
going past `6453becb` with H1's full completion run and H4-D (commit `6372f640`), but never
picked up the corrections from `a6f11e67` — so its own `RESULTS.md`, right up to its last
commit, still carried the two since-refuted verdicts. **Neither branch alone was the accurate
state of this harness.** This repo's initial content is a merge of both (verified conflict-free
via `git merge-tree`) — PR #3626's corrections carried forward in full, on top of H4-D and H1's
completion. `ppat/homelab-ops-kubernetes-apps#3626` has been marked superseded by this move.

**What else changed in the move**: the production module this harness targets has changed
shape since parts of it were written. The `garage-operator` (CRD-based: `GarageCluster`/
`GarageBucket`/`GarageKey`) was dropped — its ClusterRole granted cluster-wide Secret read
access to manage at most one instance per cluster, a bad trade for a single-instance workload.
The replacement is a plain Deployment/Service/PVC/ConfigMap, and the module itself moved from
a proposed standalone `storage-object-core` into the existing `storage-core`
(`infrastructure/subsystems/storage-core/garage/` in the apps repo). None of this harness's
*test logic* depended on the operator — every H-test that deploys its own throwaway Garage
instance (H1, H5) already used a plain Deployment, not the CRD, so nothing needed retiring on
that account. What did need fixing were comments that named the old module path
(`storage-object-core`, `garagecluster.yaml`) as a config-parity reference; those are now
updated to point at the current module and are called out inline where they occur, rather than
silently rewritten.

**What was retired, not carried forward**: nothing. Every H-test here (H1–H6, H4-D) still
targets a live, current question — see the per-test descriptions below. The one thing actually
deleted in the move's own history, not by this repo, was `UPSTREAM_ISSUE_DRAFT.md` (PR #3626):
a drafted Garage bug report that adjudication found was reporting AWS-conformant behavior as a
defect. Deleting a groundless bug report before filing it is the correct outcome of the
falsification discipline working, not something to preserve for its own sake.

## Layout

Each `hN-*/` directory is a self-contained test (scripts, fail-first, and any
supporting manifests), numbered to match the pre-registered plan below and every
cross-reference in `RESULTS.md`, `RESULTS-H1-completion.md`, and `H4-INLINE-RECLAMATION.md` —
kept as numbers rather than renamed to descriptive slugs specifically so those existing
citations don't need to change. `lib/` holds generators shared across tests (currently just
the synthetic Loki-shaped keyspace generator, used by H1). `results/` holds the raw,
timestamped evidence (JSONL/JSON) every verdict in `RESULTS.md` is drawn from — this is kept
flat at the repo root, alongside the tests, rather than nested under each `hN-*/` directory,
because several results files (e.g. H1's) are written to across multiple runs spanning more
than one test session and are easier to audit as a single directory than scattered per-test.
`resume-restart/` is new in this repo (see below) — it doesn't correspond to any of the
numbered H-tests; it tests the harness's own operational reliability, not Garage.

This is a flat, root-level layout rather than nesting everything back under a
`ci/experiments/garage-falsification/`-shaped path: that nesting existed because the harness
was one experiment among many things in a large monorepo. In a repository whose entire purpose
is this harness, the extra path segment added nothing and only made every internal
cross-reference longer.

## The standing rule this harness is built around

**A test that passes before the thing under test is applied proves nothing.** Every check
here has a fail-first run: a state deliberately constructed so the detector MUST report a
failure, run and observed to actually report it, before any real result from that detector is
trusted. A fail-first run that comes back clean means the detector is broken and every
downstream result from it is **void**, not "probably fine" — this happened three times during
this harness's life (see "What broke and what it means" below), and every time changed the
test (or, in H4's case, forced a full retest) before any real result was trusted.

Pattern followed throughout: a warm-up/fail-first gate that proves the detector works,
positive and negative controls alongside the real check, explicit `SKIP` kept distinct from
"checked, no violation found", and a single greppable `SUMMARY ... verdict=` line per test.

## Where results live

- `results/` — raw output (JSONL per-iteration records, JSON summaries) from every test run,
  including fail-first runs.
- `RESULTS.md` — the verdict per test against the pre-registered kill criteria below, with
  fail-first and real results reported side by side.
- `RESULTS-H1-completion.md` — H1's full completion run in detail (checkpoint table, the
  re-cut criteria, incidents hit and fixed along the way).
- `H4-INLINE-RECLAMATION.md` — H4-D's pre-registered design and landed result (verdict FAIL,
  landed 2026-08-14T16:54:43Z).

`results/h2-hardreset.jsonl` has three Garage access-key IDs (`GK...` strings, from
ephemeral `tmpfs-loop` test cells — that substrate is destroyed by design on every hard reset,
which is exactly the mechanic under test, so these were already dead the moment they were
recorded) replaced with `GK-REDACTED-EPHEMERAL-TEST-KEY-*` placeholders during this repo's
move, to avoid publishing token-shaped strings regardless of whether they still granted access
to anything. No other content in that file changed — verdicts, iteration IDs, and error
classifications are exactly as recorded.

## Environment this ran on (read before comparing numbers to anything else)

- **Docker VM** (`docker-vm.sandbox-docker.svc.cluster.local`, H1/H2/H3/H4/H6): 4 vCPU, 15 GiB
  RAM, root disk (`/dev/vda`, ext4) only ~19 GiB — too small for this harness's data — but
  `/var/lib/docker` and all container data volumes live on a separate 200 GiB volume
  (`/dev/vdb`, mounted at `/opt/build-scratch`), which is what actually made the H1/H2 data
  volumes fit. Rebuilt weekly; disposable by design — see "Where results live" above for why
  every result that matters is committed here rather than left on that VM (H1's own final
  checkpoint was recovered from that VM just ahead of a rebuild during this move; see
  `RESULTS-H1-completion.md`'s provenance note).
- **sandbox-talos** (H4-D, H5): single-node Talos v1.13.8 Kubernetes cluster, ~8 GiB memory /
  ~40 GiB ephemeral storage allocatable. Also rebuilt weekly.
- The 12,344 MiB MinIO RSS baseline figure came from **different hardware** (the real
  production cluster) **under different page-cache pressure**, so it is not a valid absolute
  comparator against numbers measured here — H1 runs MinIO and Garage side by side on the
  *same* host specifically so the Garage-vs-MinIO comparison is apples-to-apples even though
  neither number is directly comparable to the 12,344 MiB figure in isolation.

## Environment constraints and honest deviations (read before trusting any result)

- **No read-only credentials to the live production bucket.** The production kubectl contexts
  require interactive OIDC login, unavailable in the non-interactive sessions that built this
  harness. H1's keyspace is therefore **synthetic**, not sampled from live data — see
  `lib/keygen.py`'s module docstring for the exact scheme used to reproduce the documented
  Loki prefix-clustering shape (two key families: `fake/<fp>/...` chunk keys, 95.4% of
  objects, small; `index_<period>/...` index keys, 4.6%, large) and the size distribution
  (blended mean ≈ 3.9 KB, matching the baseline).
- **No second physical host for iSCSI/NFS.** H2's `ext4-iscsi` and `nfsv4.1` substrates are
  real protocol stacks (LIO/`targetcli` kernel target + `iscsiadm` initiator; real
  `nfs-kernel-server` + NFSv4.1 client) but loopback on the same VM. This still exercises the
  real SCSI/NFS command path (`SYNCHRONIZE_CACHE`/FUA on `fsync`, real `COMMIT` semantics on
  NFS) — what it does NOT exercise is network-partition/latency behavior a second host would
  add.
- **H2 iteration count**: pre-registered at 25 per cell per mechanic. See `RESULTS.md` for
  what was actually completed — recorded exactly, not rounded up.
- **H1's stated limitations, which must travel with any citation of its numbers**: closed-loop
  load generator, so coordinated omission under-reports the tail; n=200 per checkpoint, so p99
  is an estimate with wide error bars; the constrained-memory regime was never exercised, so
  the latency results hold only under generous RAM. See `RESULTS-H1-completion.md`'s "Verdict
  against the three pre-registered kill criteria" for the full statement and where the re-cut
  criteria themselves were pre-registered.

## What broke and what it means (the most valuable part of this exercise)

Three things overturned an assumption made in this harness's own design. Two were caught by
the fail-first-first discipline during the harness's own development. The third slipped past
that same discipline and was only caught later, by an independent adjudication reviewing the
harness's results — and that gap is itself the most important lesson here, see #3. Full detail
in `RESULTS.md`; summary:

1. **The H2 fail-first mechanic ("dd the last 4KiB off data.mdb") does not reliably corrupt
   LMDB on a small/near-empty database.** LMDB's meta pages live at the START of the file; on
   a freshly-bootstrapped test cell the tail is unused/free space. 11 of 12 cells' fail-first
   runs came back CLEAN with that literal instruction — not because Garage is more durable
   than expected, but because the corruption never touched anything LMDB reads. Fixed by
   corrupting both head and tail; re-verified all 12 cells then correctly report CORRUPT. See
   `h2-durability/corrupt_cell.sh`'s header comment.
2. **"Restart the container to trigger Garage's lifecycle worker" does not work on a second
   restart the same day.** Garage persists a `last_completed: <date>` marker in
   `<meta>/lifecycle_worker_state` and skips re-running once it's already run today. First
   assumption ("every restart re-triggers it," from watching one cold start) was wrong; caught
   because the harness's own `du`/list/count snapshots came back completely unchanged after
   the "trigger," which shouldn't happen for a working trigger. Fixed by clearing that state
   file before restart. See `h4-lifecycle-expiration/lifecycle_check.py`'s comment.
3. **H4's own fail-first was not a real fail-first, and this harness's own discipline did not
   catch it at the time.** It asserted `du_bytes > 0` before the Expiration rule was applied —
   true by construction, since nothing had been deleted yet — and never demonstrated the `du`
   probe could observe a *decrease*. It also PUT one random body 200 times, which Garage's
   content-addressing collapsed into a single ~1 MiB block, so the `du` figure it did record
   was tracking one block's lifecycle, not 200 objects' worth. Both defects passed this
   harness's own fail-first-first discipline as originally applied, because that discipline
   only asked "does the detector see the pre-condition" (yes, trivially), never "can the
   detector see the post-condition change at all" — the harder, load-bearing question. It was
   caught only by an independent adjudication reviewing the run afterward (the result: H4's
   original NOT-RECLAIMED/KILLED verdict was **void**, not negative — see `RESULTS.md`), not
   by anything internal to this harness at the time, and H3's original "Garage is worse than
   MinIO" finding was separately found to be a test-construction artifact, reversed on
   correction. **This is the standing lesson of the whole exercise: a fail-first that cannot
   fail makes everything downstream void, not negative — and a fail-first can look rigorous
   (it runs, it asserts something, it comes back green) while still being the wrong shape to
   ever register a failure.**

Also caught and fixed pre-real-run: the (b) "repair reports no errors" check originally did
a substring search for the word "error" across raw container logs, which false-matched
Garage's own benign shutdown message "S3 API server exited **without error**." Fixed to match
the tracing level field specifically (`ERROR`/`PANIC`) after stripping ANSI color codes.

## Resume-and-restart correctness

This harness's own operational history includes losing or corrupting data three separate
times, by three separate mechanisms, all during H1's completion run — a bare SSH-backgrounded
process dying with its session, a contaminated resume producing duplicate contradictory
result rows, and two independent sessions concurrently driving the same benchmark. Each is a
real incident with its own postmortem in `RESULTS-H1-completion.md`. `resume-restart/` is a
dedicated, CI-run regression suite built during this repo's move to catch each one — see
`resume-restart/README.md` for the three tests, what each proves, and an honest accounting of
what is and is not actually exercisable without the real infrastructure these incidents
happened on.

## Re-running this harness

Each `hN-*/` directory is self-contained with its own `run.sh` (or documented multi-step
runbook for H2's hard-reset mechanic, which cannot be one unattended script because the host
being rebooted cannot supervise its own reboot). See each directory's own script comments —
they carry the "why", not just the "what". `lib/keygen.py` is shared between H1 and any test
that needs the same synthetic Loki-shaped keyspace.

`h4-lifecycle-expiration/h4b_run.sh` and `h3-listobjectsv2-barman/h3b_run.sh` are independent
adjudication retests, not replacements for `run.sh` in either directory — see `RESULTS.md`'s
H3 and H4 sections for why each original result needed one. `h4-lifecycle-expiration/h4c_inline.sh`
is the exploratory probe that motivated H4-D (`h4-lifecycle-expiration/h4d_inline_steady_state.py`,
see `H4-INLINE-RECLAMATION.md`).

Everything here targets the Docker VM (`docker-vm.sandbox-docker.svc.cluster.local`, SSH key
`~/.ssh/sandbox_docker_vm`) or `sandbox-talos` (`kubectl --context sandbox-talos`), both
described above. Nothing here writes to production clusters.

## CI

`.github/workflows/test-resume-restart.yaml` runs `resume-restart/`'s regression suite on
every PR that touches it — those tests are small, fast, and self-contained (no real
Garage/MinIO/Kubernetes needed), so they're genuinely CI-worthy.

**The H-tests themselves (`h1-*/` through `h6-*/`, H4-D) are deliberately not CI'd.** Every
one of them depends on infrastructure a hosted GitHub Actions runner doesn't have: a
purpose-built Docker VM with a 200 GiB data volume, or a real Kubernetes cluster
(`sandbox-talos`) with specific storage classes and node extensions already present. Standing
up equivalents in CI for tests that each run for minutes-to-hours (H1's full run took most of a
day; H2's hard-reset mechanic requires physically rebooting the host mid-test; H4-D's full
cycle is a ~50-hour run) would be disproportionate to what they're for: a one-time,
pre-adoption decision, not a regression suite that needs to stay green. Their value is
captured in `RESULTS.md` and the raw evidence in `results/`, not in a CI job. `pre-commit` (via
`.pre-commit-config.yaml`) still lints every script here for syntax and shellcheck issues on
every PR, independent of whether the script can actually run in CI.

## The tests and their pre-registered kill criteria

### H1 — RSS and LIST latency at 3.44M sub-1KB objects

**Claim**: Garage holds this object count under LIST-dominated access at materially lower
anonymous RSS than MinIO, without a latency wall. **Re-cut criteria** (see
`RESULTS-H1-completion.md`; the original "RSS > 6 GiB at 3.44M objects" criterion was re-cut
*before* the 2M/3.44M checkpoints existed, because MinIO's RSS is ~88% anonymous/OOM-relevant
while Garage's is ~98% reclaimable page cache — judging both on total RSS would have failed
Garage for using memory that was available, not memory it needed): **C1** anonymous RSS
≤512 MiB and ≤ MinIO's; **C2** LIST p99 ≤1000 ms at 1.86/s and ≤2× MinIO's; **C3** LIST p99
growth 1M→3.44M sub-linear. **Fail-first**: loader against a 512 MiB tmpfs `metadata_dir` must
ENOSPC/OOM. **Result: PASSED all three.**

### H2 — unclean-shutdown metadata durability (the most important test here)

**Claim under test (corrected during design)**: LMDB corruption after unclean shutdown is a
property of the *engine and its defaults* (`metadata_fsync` defaults to `false`), not of the
filesystem underneath — so swapping NFS for iSCSI does not help unless the engine actually
calls `fsync`. Matrix: 4 substrates (ext4-local, ext4-iscsi, nfsv4.1, tmpfs-loop) × 3 engine
configs (`lmdb`+`fsync=false`, `lmdb`+`fsync=true`, `sqlite`+`fsync=true`), pre-registered 25
iterations/cell, two kill mechanics (`kill -9` mid-PUT-stream — does not lose page cache; a
real hard reset via `echo b > /proc/sysrq-trigger` — does).
**Per-iteration verdict**: (a) process starts, (b) `garage repair --yes tables` reports no
errors, (c) every acknowledged PUT is readable, (d) no object returns wrong bytes. **CORRUPT**
= (a) or (b) or (d) fails. **DATA-LOSS** (distinct from CORRUPT) = only (c) fails — the engine
is healthy but silently dropped acknowledged writes, exactly what `fsync=false` predicts.
**Fail-first**: every cell's iteration 0 runs against a deliberately damaged metadata store
(see "What broke" above for why this needed head+tail corruption, not tail-only).

### H3 — `ListObjectsV2` and the Barman trailing-slash prefix

Reproduce `ListObjectsV2(Prefix="db//")` failing against MinIO first (proves the detector can
catch the bug at all), then the same call against Garage. **Result: reversed on correction** —
the original probe paired single-slash writes with a double-slash list, for which Garage's
HTTP-200-empty is correct S3 behavior, not a defect; on the pairing that matches barman-cloud's
real doubled-write-then-list behavior, Garage is self-consistent and MinIO write-rejects
instead.

### H4 — plain `Expiration` on a non-versioned bucket actually reclaims space

Three assertions in ascending strength: (1) LIST no longer returns the objects, (2) Garage's
own object-count metric drops, (3) **`du` on `data_dir` drops**. (1)+(2) without (3) is
precisely the MinIO delete-marker bug wearing different clothes. **Fail-first**: all three
must report NOT-RECLAIMED before the rule is applied. **Result: original run's fail-first was
found void (asserted a precondition true by construction, never proved the probe could see a
drop); corrected retest REFUTES the original NOT-RECLAIMED finding — reclaims at ~602–632s,
for the block-storage path.** Does not cover the sub-3KB inline path — see H4-D.

### H4-D — the sub-3072B inline path: does it reclaim, or does it just never grow visibly?

Both H4 runs used 1 MiB objects and only ever proved reclamation for Garage's block-storage
path. 95.4% of production objects are sub-1KB and stored inline in LMDB with no block at all —
`du` on `data_dir` is structurally blind to that majority even when reclamation works
correctly. Two-cycle steady-state design: write, expire, wait past `TABLE_GC_DELAY` (24h),
write again without expiring, wait again, compare `metadata_dir` growth and LMDB `last_pgno`
between cycles. **Pre-registered thresholds** (fixed on
[`ppat/homelab-ops-kubernetes-apps#3611`](https://github.com/ppat/homelab-ops-kubernetes-apps/issues/3611)
before any deciding data existed): PASS if cycle-2 growth ≤1.25× cycle-1; ≥1.75× is the
explicit never-reclaimed failure mode. **Fail-first (the control arm itself)**: proven, ratio
1.967 against a theoretical 2.0 for two never-reclaimable populations. **Status: LANDED —
FAIL.** Treatment ratio 2.437 on both `du` and `last_pgno` — above the ≥1.75× fail line and
above the no-expiry control's own 1.967. A confirmatory third write cycle settles the shape
of that failure: `Δ3 = 0` pages/bytes exactly, against pre-registered predictions of `≈0`
(bounded high-water mark) vs. `≈8,000` (unbounded per-cycle growth) — bounded, not unbounded,
and the FAIL verdict is unchanged. Specific to the inline path (1 MiB objects on the block
path reclaim correctly, see H4); not a production projection — see `RESULTS.md`'s H4-D
section and `H4-INLINE-RECLAMATION.md` for the full result and its limits.

### H5 — Longhorn backup restore round-trip

979 `Backup` CRs in production; this is the DR path for every PVC. Garage enforces exact
`s3_region` match (unlike MinIO's leniency). **The assertion is the restore, not the
backup.** **Falsifier**: any restore mismatch, or any restore requiring a manual step.
**Result: SKIPPED** — the test cluster's node image lacked a required Talos extension, and
fixing it would have meant an unannounced reboot of a cluster shared with other tenants.

### H6 — Terraform 1.6.6 S3 backend against Garage

Four workspaces' state must move before MinIO can be decommissioned. `terraform init
-migrate-state` against a Garage bucket with `force_path_style` + the usual `skip_*` flags,
then `plan` must show no diff. Throwaway workspace, dummy resources only.
**Falsifier**: any state operation failing, or a plan differing from the baseline.
**Result: PASSED**, full pre-registered flow, clean.
