# H4-D — does the sub-3072B inline path actually reclaim, or just never grow visibly?

**Status: LANDED — FAIL.** The treatment arm's verdict was due at `cycle2_wait_deadline`
(**2026-08-14T16:54:40Z**, not the ~16:00Z originally estimated in this file and in
`RESULTS.md` before the exact deadline was known) and landed with `ratio_du = 2.437`,
`ratio_pgno = 2.437` — above the pre-registered **FAIL** threshold (`≥1.75×`) and above the
control arm's own 1.967 (the cost of retaining everything with no expiry at all). See
"Interim status" below for the full numbers and "The governing rule" section — unchanged by
this landing — for why the control arm's `DETECTOR-OK` result is what makes this trustworthy.
**A confirmatory third write cycle (Cycle 3, run 2026-08-14T22:34–22:36Z) settles the one
question the original two cycles left open — whether the failure is bounded or compounds
per-cycle — without changing the verdict**: `Δ3 = 0` pages, `0` bytes, exactly, falsifying
unbounded per-cycle growth cleanly. See the dated entry below.

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

### 2026-08-14T22:35:44Z — Cycle 3: bounded-vs-unbounded question settled, verdict unchanged

**Why this run happened**: the FAIL verdict below was already conclusive against the
pre-registered threshold — nothing here revises it. What the two-cycle result could not
distinguish was *shape*. Cycle 1's dead population sat in `object:gc_todo_v2` for a full
`TABLE_GC_DELAY`, then drained sometime in the ~25h settle window, during which
`metadata_dir` grew by only `+24` pages / `+98,304` bytes. That is small enough to be
consistent with two different stories: (a) the freed pages were reused almost completely and
that tiny residual is ordinary LMDB bookkeeping overhead, or (b) a slow staircase where a
small amount of dead weight accumulates every cycle and would compound over many more
cycles. One cycle's data point could not tell those apart. A third cycle can.

**Preconditions, verified live, matched the documented end-of-run state to the byte before
any write was issued** (the run script aborts with no writes on any mismatch — it did not
abort): `object:table = 60,000`, `object:gc_todo_v2 = 0`, `version:gc_todo_v2 = 0`,
`last_pgno = 35,991`, `metadata_du_bytes = 147,557,714`.

**Method, identical to cycles 1–2 by construction**: the driver's own `lmdb_snapshot()`,
`du_bytes()`, and `put_distinct()` functions (same `lmdb.open(..., readonly=True, lock=False,
max_dbs=64, subdir=True)` → `env.info()["last_pgno"]`; same `du -sb`; same
`boto3.put_object` with `os.urandom(512)` bodies) were copied verbatim into a standalone
script, run from a short-lived helper pod mounting the same `garage-storage` PVC — RWO on a
single node permits a second reader/writer pod as long as it doesn't run concurrently with
the driver's own writes, which it didn't. Same `python:3.12-slim` image. 20,000 more distinct
512 B objects were written to `treat-bucket`, prefix `cycle3/` (a new prefix, so this
population is disjoint from cycles 1–2's `expire-me/`-prefixed keys and nothing here was
expired).

**Two predictions, fixed before the write**: **bounded high-water mark → `Δ3 ≈ 0`**
(everything a fresh 20,000×512B population needs fits inside pages already freed by cycle
1's drained tombstones); **per-cycle growth → `Δ3 ≈ 8,000`** pages (matching `Δ1`'s magnitude
— the cost of one fresh, unreused population, since `Δ1 = 8,164` pages for the same
20,000×512B write against an empty baseline).

**Result: `Δ3 = 0` pages, `0` bytes — exactly.** `last_pgno`: 35,991 → 35,991.
`metadata_du_bytes`: 147,557,714 → 147,557,714, unchanged to the byte. The two predictions
were ~8,000 pages apart; the observed value lands exactly on the bounded prediction, not
partway between the two. This is a clean falsification of the per-cycle-growth prediction —
no threshold judgement call is needed, unlike the `Δ2` verdict above.

**Corroboration that this is real reuse, not a silent no-op**: over the same write,
`object:table` rose 60,000 → 80,000 and `object:merkle_tree` rose 71,232 → 96,985 — the
20,000 PUTs demonstrably landed as real LMDB rows (confirmed directly from the same
per-named-database entry counts used throughout this file, not inferred from the S3 API
returning success). So a full population's worth of new writes was absorbed with zero net
`last_pgno` growth, by **a separate transaction that had never touched cycle 1's freed pages
before** — a materially stronger result than the `+24`-page residual after the drain window
already suggested, which only showed reuse *within* whatever transaction(s) performed that
maintenance.

**This settles the question the two-cycle result left open, rather than adding to it**:
freed LMDB pages are reused by later, independent write transactions, not just within the
transaction that frees them. The pattern this run establishes is a **bounded step to a new,
larger high-water mark that then holds** — not an unbounded staircase that climbs every
cycle. The FAIL verdict stands exactly as landed: expiry still does not shrink `metadata_dir`,
`Δ2` is still real and still breaches the pre-registered `≥1.75×` line. What changes is that
this is now known to be bounded bad news, not compounding bad news.

**What this does not touch**: Garage's own documented upstream issue on LMDB *snapshot*
bloat — `git.deuxfleurs.fr/Deuxfleurs/garage#1006` ("On LMDB compaction"): a real,
independently-reported case of a 146 GB LMDB metadata *snapshot* file holding ~4 GB of live
data (~37×), compacted down to 3.9 GB with `mdb_copy -c`. That issue's own account attributes
the bloat to Garage's periodic snapshot mechanism producing uncompacted copies over time — a
different mechanism from anything cycles 1–3 exercised here, since no snapshot operation was
triggered in this test at any point. Cycle 3 shows freed pages in the *live* database are
reused by later transactions; it says nothing about whether a *snapshot* copy of that
database compacts as it accumulates writes. That remains a separate, open risk, unaddressed
by this result.

**Raw artifacts**: `h4d-cycle3.log`, `h4d-cycle3-results.json`, and
`h4d_cycle3_script_used.py` (the standalone script described above). The original
`h4d_inline_steady_state.py` driver and its `/results/h4d-results.json` were not modified —
this was a separate, read-preconditions-then-write run against the same live Garage
instance, not a resumption of the original driver.

---

### 2026-08-14T16:54:43Z — treatment arm complete, verdict FAIL

**Final snapshot (`treat_cycle2_final`) taken 2026-08-14T16:54:43.618Z, ~3s after
`cycle2_wait_deadline` (2026-08-14T16:54:40.126Z) elapsed.** The driver container's ongoing
crash loop is now fully explained and confirmed benign, not just presumed so: it resumes from
`/results/h4d-results.json` with `phase=done`; every phase gate it checks on resume is already
satisfied, so it re-executes no work; it re-prints the same `PHASE -> ...` transition log and
`SUMMARY ...` line (with the *current* wall-clock time stamped on each line, not the original
event time) and then **exits 0**; `restartPolicy: Always` restarts it, and the cycle repeats.
Confirmed by pulling the container's logs directly at two different points after this
verdict landed — identical content both times, differing only in the replayed timestamps. So
a "`phase -> done`" line's own timestamp is never a reliable completion time; the
`results.json` snapshot timestamps and `cycle2_wait_deadline` above are the trustworthy
anchors for when the run actually finished, and the crash loop itself mutates nothing.

**Full treatment-arm snapshot series**:

| snapshot | list keys (`expire-me/`) | `metadata_dir` du | `last_pgno` | timestamp |
| --- | --- | --- | --- | --- |
| baseline | 0 | 66,071,890 B | 16,097 | 2026-08-12T14:51:36Z |
| cycle 1 write (+20,000) | 20,000 | 99,511,634 B | 24,261 | 2026-08-12T14:53:06Z |
| cycle 1 after GC wait | **0** | 114,802,002 B | 27,994 | 2026-08-13T15:53:09Z |
| cycle 2 write (+20,000 more) | 20,000 | 147,459,410 B | 35,967 | 2026-08-13T15:54:40Z |
| cycle 2 final (after settle wait) | 20,000 | 147,557,714 B | 35,991 | 2026-08-14T16:54:43Z |

`Δ1 = 99,511,634 − 66,071,890 = 33,439,744 B` (`last_pgno` Δ1 = 24,261 − 16,097 = 8,164).
`Δ2 = 147,557,714 − 66,071,890 = 81,485,824 B` (`last_pgno` Δ2 = 35,991 − 16,097 = 19,894).

**`ratio_du = 2.437`, `ratio_pgno = 2.437`** (both metrics agree exactly, as designed).
Against the pre-registered thresholds (`PASS ≤1.25×`, `FAIL ≥1.75×`): **FAIL**, and not a
borderline one — 2.437 is *above* the control arm's own 1.967 (the cost of two live
populations with **zero** expiry ever attempted). Expiring the first population did not merely
fail to reclaim its space; the treatment arm ended up more expensive than the "never delete
anything" baseline.

**`cycle1_object_count_zero = true` is the load-bearing fact that rules out "expiry never
fired"**: `list keys` genuinely dropped from 20,000 to 0 after the cycle-1 wait — the objects
left the bucket listing. `object:gc_todo_v2` and `version:gc_todo_v2` (read directly from the
LMDB named databases at each snapshot) went from 0 (before the rule) to 20,000 each
immediately after the cycle-1 wait, confirming the metadata layer queued every one of them for
tombstone GC. So this is not a repeat of the original H4's void fail-first (`du_bytes > 0`
before anything ran) — the deletion pipeline demonstrably executed, and the metadata footprint
grew anyway.

**A further data point from the raw snapshots, not part of the pass/fail measurement**:
`object:gc_todo_v2` and `version:gc_todo_v2` were still sitting at 20,000 each at the
cycle-2-write snapshot (2026-08-13T15:54:40Z) — a full `TABLE_GC_DELAY` (86400s) had elapsed
since the rule was applied, but the queue had not yet drained. By the final snapshot
(2026-08-14T16:54:43Z, ~25h after cycle-2-write), both counters had reached 0 and
`object:table` had dropped back from 80,000 to 60,000 (cycle 1's rows were genuinely removed
from the table), while `metadata_dir` grew by only `+98,304` B and `last_pgno` by only `+24`
pages over that same ~25h. **Cycle 3 (see the dated entry above) settles what that small
residual delta meant**: freed pages are reused in full by later, independent write
transactions, not merely within whatever transaction performed the drain — a bounded step to
a new high-water mark, not an unbounded staircase. The pre-registered `Δ1`/`Δ2` verdict below
is unaffected either way; this is what closes the interpretation question, not what decides
the verdict.

**`data_dir` stayed at 64 B across every snapshot in both arms** (`data_dir_stayed_flat =
true`), confirming every object in this test took the inline path, never the block path — this
result says nothing about the block-storage path, which H4/H4-B already showed reclaims
correctly (~602–632s).

**What this does not license** (see `RESULTS.md`'s H4-D section and "Known blind spots" for
the full statement): this is a metadata growth-rate measurement under a synthetic two-cycle
workload at 20,000×512B objects, not a production projection. H4 tested and passed on the
block-storage path with 1 MiB objects — this result does not touch that finding. Whether this
growth pattern is survivable against a 16Gi `metadata_dir` at production's actual object-size
mix and write rate is a separate calculation this file does not perform.

**`SUMMARY test=h4d-inline-steady-state verdict=FAIL ratio_du=2.437 ratio_pgno=2.437
cycle1_count_zero=True threshold_pass<=1.25 threshold_fail>=1.75`**

---

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
