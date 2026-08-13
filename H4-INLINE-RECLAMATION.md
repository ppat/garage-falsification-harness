# H4-D — does the sub-3072B inline path actually reclaim, or just never grow visibly?

**Status: PENDING.** The treatment arm's verdict was due ~2026-08-14T16:00Z and had not
landed as of this repo's move from `ppat/homelab-ops-kubernetes-apps`. **When the verdict
lands, update this file's "Interim status" section in place (add a dated entry, most-recent-
first, per that section's own convention) and update the H4-D row in `RESULTS.md`'s verdict
summary and its "H4-D" section.** Do not move the pre-registered thresholds below to fit
whatever the result turns out to be — they were fixed before any data existed specifically so
they couldn't be.

This was a follow-up to H4, not a revision of it — a new, self-contained sub-experiment
closing the specific gap the corrected H4 left open. (Historical note: at the time this file
was originally written, `RESULTS.md`'s corrections from PR #3626 were still in flight on a
separate branch and explicitly out of scope for this file to touch — see this repo's
top-level README "Provenance" for how that PR and this file's own branch were later
reconciled into one history during the move to this repo. That reconciliation is done; this
note is kept only so the "do not edit RESULTS.md here" instruction that used to open this file
isn't rediscovered as if it still applied.)

## The gap this closes

H4 (original) and its retest (H4-B, see `RESULTS.md`) both used 200×1MiB objects and
concluded "plain `Expiration` reclaims space" for the **block-storage path**. But Garage
stores any object under `INLINE_THRESHOLD` (3072 B) directly in the LMDB metadata store — no
`Version`, no `BlockRef`, no block written to `data_dir` at all. Measured directly during
H4's adjudication (`h4-lifecycle-expiration/h4c_inline.sh`): 20,000×512B objects grew
`data_dir` by **exactly 0 bytes**. Production is 95.4% sub-1KB objects, mean 3.9KB — almost
entirely inline. Neither H4 run says anything about whether *that* path reclaims.

`du` on `data_dir` (H4's instrument) is structurally blind to the inline path even when
reclamation is working correctly: inline objects live in `metadata_dir`'s LMDB file, and LMDB
never returns freed pages to the filesystem via `ftruncate` — so `metadata_dir`'s file size
can never shrink either, success or failure. The only way to tell "freed and reused
internally" from "never freed" is whether a **second population's worth of new writes forces
the file to grow further**, or reuses the space the first population's tombstoned entries
left behind. That's what this test measures.

## Claim under test

For sub-3072-byte objects on a non-versioned Garage bucket, a plain `Expiration` lifecycle
rule causes LMDB metadata pages to be genuinely freed **and reused by subsequent writes** —
so across repeated write/expire cycles, metadata footprint reaches a steady state instead of
growing by one population's worth every cycle (which would be the MinIO delete-marker bug
in different clothes: space consumed by data that is logically gone).

## Pre-registered design (written before any data was collected — see timestamp below)

**Registered**: 2026-08-12T14:42:01Z, before the control or treatment arm ran.

- **N = 20,000 objects per batch, 512 bytes each, distinct `os.urandom` body per object**
  (content-addressing means a repeated body dedups to one block/inline-entry and silently
  invalidates the measurement — this is documented as an actual defect that voided the
  original H4 run; see `RESULTS.md`). 512 B leaves ample headroom under `INLINE_THRESHOLD`
  (3072 B) so no object accidentally crosses into the block path. 20,000 matches the scale
  already shown (`h4c_inline.sh`) to move `metadata_dir` by a measurable ~30+ MB, and is
  "tens of thousands, not millions" per the brief — large enough to sit well above LMDB's
  fixed per-environment overhead, small enough that writing one batch takes low-single-digit
  minutes over the S3 API.
- **Two arms, same Garage instance, same config, separate buckets**, so both arms share
  identical engine/host noise:
  - **Control (`ctrl-bucket`)**: write N, measure; write N more, never expire anything,
    measure. This is the fail-first proof, not a separate step — see below.
  - **Treatment (`treat-bucket`)**: write N (cycle 1), measure, apply
    `Expiration.Date=<yesterday>` (age-based `expirationDays` cannot expire a fresh object),
    force an immediate lifecycle-worker pass (see "Forcing the worker" below), wait past
    `TABLE_GC_DELAY` (86400s, `src/table/gc.rs`) with a safety margin, confirm bucket object
    count is 0, write N more distinct objects (cycle 2, never expired), wait the same margin
    again for any residual maintenance to settle, measure final state.
- **Metrics recorded at every snapshot**: `metadata_dir` size (`du -sb`), `data_dir` size
  (`du -sb`, expected to stay ~flat throughout — a sanity check that these objects are in
  fact taking the inline path and not the block path), and LMDB internals read directly from
  the `metadata_dir` LMDB environment: `last_pgno` (highest page number ever allocated — this
  is the number that must NOT grow on cycle 2 if freed pages are being reused; it is a better
  instrument than file size because file size only grows in lockstep with `last_pgno` and
  never shrinks either way) and per-named-database entry counts via a short-lived read
  transaction (opened, read, closed immediately — see "Why snapshots must be short-lived"
  below).
- **Threshold (pass/fail, fixed before seeing data)**:
  Let `Δ1 = metadata_size(after cycle-1 write) − metadata_size(baseline, empty bucket)`
  and `Δ2 = metadata_size(after cycle-2 write+wait) − metadata_size(baseline)`, computed
  identically for both `du`-based file size and `last_pgno`.
  - **PASS** if `Δ2 ≤ 1.25 × Δ1` on **both** metrics.
  - **FAIL** if either metric's `Δ2 > 1.25 × Δ1`; explicitly called out as the MinIO-shaped
    failure mode (space consumed by logically-gone data) if `Δ2 ≥ 1.75 × Δ1` on either metric
    — i.e. close enough to the no-reuse-at-all prediction (`Δ2 ≈ 2 × Δ1`) that it isn't
    measurement noise.
  - **Justification for 1.25×**: full internal reuse predicts `Δ2 ≈ Δ1` (one live
    population's worth, regardless of how many cycles ran); zero reuse predicts `Δ2 ≈ 2×Δ1`
    (every cycle's dead weight stays resident, on top of the next cycle's live weight). 1.25×
    sits a quarter of the way from "fully reused" toward "not reused at all" — enough
    headroom to absorb genuine LMDB overhead (B-tree rebalancing, page splits, the free-list's
    own bookkeeping pages) without accepting a result that's most of the way to doubling.
  - Both `du` and `last_pgno` must agree for a PASS, because either alone can mislead: `du`
    is coarse (page-size-rounded, and OS-level slack); `last_pgno` alone wouldn't catch a
    fragmentation pathology where pages are "reused" in a way that still balloons the file.

## The governing rule this test is built around, and why it isn't repeated here

The brief's framing is explicit: "Every probe must be observed to fail before the thing under
test is applied." H4's original fail-first asserted `du_bytes > 0` before the rule ran — true
by construction, so it could never have failed, which is exactly why that result was voided
(see `RESULTS.md`).

**This test's fail-first is the control arm itself, not a separate throwaway check**: write
N, measure, write N more with nothing ever expired, measure again. If the metadata-size probe
is working, `Δ2_control ≈ 2 × Δ1_control` — two live, never-reclaimable populations really do
cost twice as much, and there is no reuse possible even in principle because nothing was ever
deleted. If the control comes back flat (`Δ2_control ≈ Δ1_control` with nothing deleted),
that means the probe cannot see genuine growth at all, and the treatment arm's result would be
void by the same rule that voided the original H4. The control arm is reported and observed
to fail (i.e., to correctly show growth) **before** the treatment arm's cycle-2 result is
trusted.

## Forcing the worker (established technique, not a new one)

Garage's lifecycle worker runs once per calendar day and persists `last_completed: <date>` in
`<meta>/lifecycle_worker_state`; a same-day restart alone does not re-trigger it (see
`RESULTS.md` H4 and this repo's `lifecycle_check.py`). This test clears that file and
restarts the `garage` container immediately after applying the lifecycle rule, to force a
prompt worker pass rather than depend on natural daily cadence — this keeps cycle-1's wait
close to the true ~25h floor (`TABLE_GC_DELAY` + margin) instead of up to ~48h if the natural
cadence is unlucky. Cycle 2 does not need this: nothing is expired in cycle 2, so there is no
worker pass to force — the cycle-2 wait exists only to let any residual maintenance from
cycle 1 fully settle before the final measurement.

## Why snapshots must be short-lived reads

A long-held LMDB read transaction pins the pages visible to it and prevents the writer from
reclaiming them for reuse — opening one and leaving it open across the wait would directly
suppress the exact behavior this test is trying to observe, silently biasing the result
toward FAIL. Every measurement opens the environment, reads `stat()`/`info()` in one
short-lived read transaction, and closes it immediately.

## Environment

Deployed on **`sandbox-talos`** (not the Docker VM — the brief reserves that host for an
unrelated, in-progress H1 load test) in a **dedicated namespace, `h4d-inline-gc`**, created
fresh for this run. `garage`/`garage-operator-system` do not exist as separate namespaces on
this cluster; the real module's chainsaw test currently occupies `object-store` — not
touched. `local-path`/`standard` StorageClasses (`rancher.io/local-path`) were already present
from other agents' work and are reused, not reinstalled. Garage config matches production
(`infrastructure/subsystems/storage-core/garage/conf.d/garage.toml` in
`ppat/homelab-ops-kubernetes-apps` — a plain Deployment; the operator-managed `GarageCluster`
CRD this was originally written against was dropped, see this repo's top-level README
"Provenance"): image `dxflrs/garage:v2.3.0`, `db_engine = "lmdb"`,
`metadata_fsync = true`, `replication_factor = 1` (single node, matching the sandbox).

## Where results land

- `ci/experiments/garage-falsification/h4-lifecycle-expiration/h4d_inline_steady_state.py` —
  the driver script, runs as a container alongside `garage` in the `garage` Deployment's pod
  (`h4d-inline-gc` namespace), so it survives this session ending.
- Results are written continuously (after every snapshot and every wait-loop heartbeat) to
  `/results/h4d-results.json` on a dedicated PVC mounted only in the driver container. Read
  at any time, from any machine with access to the `sandbox-talos` context, with:

  ```bash
  kubectl --context sandbox-talos exec -n h4d-inline-gc deploy/garage -c driver -- cat /results/h4d-results.json
  ```

  The file is valid JSON at every point in the run (written atomically via a temp-file
  rename) and includes a `phase` field (`control-arm`, `treatment-cycle1-write`,
  `treatment-cycle1-waiting`, `treatment-cycle2-write`, `treatment-cycle2-waiting`, `done`)
  and a `last_updated` timestamp, so a partial read always shows real progress, not a stale
  snapshot. Container logs (`kubectl ... logs -n h4d-inline-gc deploy/garage -c driver -f`)
  carry the same `SNAPSHOT[...]`/`SUMMARY ...verdict=` lines used throughout this harness.

## Interim status (updated as the run progresses — most recent entry first)

### 2026-08-12T14:54Z — control arm (fail-first) complete; treatment cycle 1 running, ~25h wait in progress

**Fail-first / control arm result — the probe is proven to register growth**:

| snapshot | list keys | `metadata_dir` du | `du` Δ from baseline | `last_pgno` | pgno Δ from baseline |
| --- | --- | --- | --- | --- | --- |
| baseline (empty) | 0 | 224,594 B | — | 21 | — |
| control cycle 1 (+20,000) | 20,000 | 33,693,010 B | 33,468,416 B | 8,192 | 8,171 |
| control cycle 2 (+20,000 more, nothing ever expired) | 40,000 | 66,071,890 B | 65,847,296 B | 16,097 | 16,076 |

`ratio_du = 1.967`, `ratio_pgno = 1.967` — both within 2% of the theoretical 2.0 (two live,
non-reclaimable populations really do cost ~2×). `data_dir` stayed at 64 B throughout both
cycles, confirming these 512 B objects take the inline path, not the block path,
exactly as `h4c_inline.sh` found during H4's adjudication.
**`SUMMARY test=h4d-control verdict=DETECTOR-OK`** — the probe can see real growth. Per this
test's design (see "The governing rule" above), the treatment arm's eventual result is
trustworthy only because this came back positive, not void-by-construction like the original
H4's fail-first.

**Treatment arm, cycle 1, so far**:

| snapshot | list keys (`expire-me/`) | `metadata_dir` du | `last_pgno` |
| --- | --- | --- | --- |
| baseline | 0 | 66,071,890 B | 16,097 |
| cycle 1 write (+20,000) | 20,000 | 99,511,634 B | 24,261 |

`Expiration.Date=2026-08-11T00:00:00.000Z` (yesterday relative to the run) applied at
`14:53:06.852Z`. The lifecycle worker was force-triggered (state file cleared via a
short-lived read-write pod, `garage`+`driver` pod restarted) rather than left to natural daily
cadence — see "Forcing the worker" above. **One real hazard hit and resolved during this
restart, recorded here rather than smoothed over**: deleting the pod without waiting for the
old container to fully terminate produced a burst of `DB error: LMDB: Resource temporarily
unavailable (os error 11)` across essentially every Garage background worker for about 8
seconds (`14:53:34`–`14:53:4x`), consistent with the old and new `garage` processes briefly
holding the same LMDB environment concurrently on the same node-local `local-path` volume (K8s
does not itself serialize this the way a real ReadWriteOnce block-storage attach/detach would).
It self-resolved once the old container fully exited: `garage status` succeeded immediately
after, zero further ERROR lines in the following 30s+, and — checked directly, not assumed —
`garage bucket info` confirmed both buckets' object counts intact (`ctrl-bucket`: 40,000,
`treat-bucket`: 20,000) after the restart. `metadata_fsync=true` is exactly the setting that
predicts this recoverability; noted here as a real, observed data point for that config choice
generally, independent of this test's own result. The driver container resumed cleanly from
its checkpoint file (`phase=treatment-cycle1-waiting`, wait deadline preserved), validating the
resumability design was worth building.

**Now waiting**: cycle-1 wait deadline **2026-08-13T15:53:06Z** (`TABLE_GC_DELAY` 86400s + 3600s
margin from when the rule was applied). At that point the driver will confirm `treat-bucket`'s
`expire-me/`-prefixed object count is 0, write cycle 2's 20,000 objects, wait again to
**~2026-08-14T16:53Z** (exact time depends on how long cycle-2's write takes), and report the
final verdict. Read current state at any time with:

```bash
kubectl --context sandbox-talos exec -n h4d-inline-gc deploy/garage -c driver -- cat /results/h4d-results.json
kubectl --context sandbox-talos logs -n h4d-inline-gc deploy/garage -c driver --tail=50
```

No further manual action is needed for the rest of this run — cycle 2 does not apply a new
expiration rule (nothing to force-trigger), so the remainder is unattended waiting and
snapshotting on the driver's own schedule.
