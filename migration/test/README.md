# Falsifiability tests

These prove the mechanism's checks can actually fail, per this project's own standard
(apps#3611's H4 episode: a fail-first that could never fail voided an entire experiment).
None of these run in CI on every commit — they need a real MinIO and a real Garage,
which is what a throwaway namespace on a cluster like `sandbox-talos` is for. Run them
by hand before trusting the mechanism against real bucket contents, and again after any
change to `../bin/migrate-bucket.sh` or `../bin/verify-bucket.sh`.

## What each test proves, and its independent oracle

| test | proves | independent oracle |
| --- | --- | --- |
| `test_version_exclusion.py` | current-versions-only copying actually drops delete markers and noncurrent versions (not true by construction) | `ListObjectVersions` filtered to `IsLatest && !DeleteMarker` — a different API call than the one the tool under test uses |
| `test-corruption-detection.sh` | tier2 verification catches real, same-size content corruption, and isn't just an always-fail check | the corrupted bytes this test itself wrote, compared against the original |
| `test-resume-after-kill.sh` | a SIGKILLed copy resumes to the same final state as an uninterrupted one, with zero truncated objects | a separate uninterrupted baseline copy, full hash comparison |
| `test-etag-check-cost.sh` | tier2's cost is directionally object-count-scaled, not bucket-byte-scaled, for this object shape (supporting evidence, not the primary basis — see `../README.md`) | wall-clock timing across buckets of different size/count ratios |

## Running against a fresh sandbox

1. Stand up MinIO and Garage in your own namespace (matching images:
   `quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z`,
   `dxflrs/garage:v2.3.0` — the exact builds this estate runs).
2. Generate synthetic fixture data with `generate_fixture.py` — defaults match the real
   `homelab-loki-chunks` shape (95.4% under 1KB, prefix-clustered keys, a versioned
   source bucket with a deliberate fraction of overwrites/deletes). Override
   `TOTAL_OBJECTS`, `NUM_PREFIXES`, `OVERWRITE_FRACTION`, `DELETE_FRACTION` via env vars.
   Content is deterministic (derived from `sha256(key + salt)`), so expected bytes for
   any object are recomputable without a side manifest.
3. Render `rclone.conf` (`../bin/render-rclone-conf.sh`) with real `MINIO_*`/`GARAGE_*`
   env vars for your sandbox.
4. Run `../bin/preflight-canary.sh <bucket>` against every destination bucket first.
5. Run the falsifiability tests.

## What was proven on sandbox vs. what remains assumption

Proven, live, against real MinIO/Garage builds on `sandbox-talos` (2026-08-13):

- Current-versions-only exclusion of delete markers and noncurrent versions: RED (naive
  copy, 1,500 objects) vs. GREEN (correct copy, 1,425 objects, matching an independent
  ground truth of 1,425).
- tier2 catches injected same-size corruption (confirmed via rclone's `md5 differ` log
  line — genuinely hash-based, not size-only) and clears again after repair.
- A SIGKILLed copy (killed at 582/1,425 objects) resumes to an identical final state
  (full hash comparison) with zero truncated objects.
- The full four-bucket sequence (ruler first, then chunks, then the two tiny buckets)
  runs end to end against synthetic data at realistic per-object shape: 28,502 current
  objects (150,000 attempted — see note below), 108.5MB, converged in 2 passes
  (343s + 19s).
- The rollback drill: a real Loki instance cut over MinIO→Garage→MinIO→Garage, querying
  correctly at every step, including data this tool migrated.

Assumption, not proven here (scope, not oversight):

- **Object count.** Prototyped at ~28,500–30,000 objects per run, not 3.44M. The
  project's own H1 falsification harness (apps#3611) already exhaustively measured both
  engines' behavior up to 3.44M objects (RSS, LIST p99, disk usage) — re-deriving that
  here would duplicate work already done more rigorously than this tool needs. What
  needed proving here instead is the *copy mechanism's* correctness (exclusion,
  resumability, verification), which object count does not change the shape of. An
  initial attempt at a 150,000-object fixture was abandoned mid-run after repeated
  interruptions from sharing a resource-constrained node with other concurrent
  workloads (not a defect in the mechanism — the interruptions themselves are exactly
  what `test-resume-after-kill.sh` exists to make safe); the reported numbers are from
  the smaller runs that completed cleanly.
- **Real bucket contents.** Synthetic data matches the stated shape (size distribution,
  prefix clustering, versioning) but is not the real `homelab-loki-chunks` data —
  production is read-only to this project.
- **The 3.44M-object convergence timeline** (how many delta passes a real migration
  needs, how long the final gap is) is not measured at real scale here — the mechanism
  (bounded-by-write-volume convergence) is proven at small scale; the specific pass
  count/duration at 3.44M is not.
- **Production Loki's rollback cost.** The drill used a minimal single-binary Loki with
  no caches and one replica; production Loki's restart cost (with
  `loki-chunks-cache`/`loki-results-cache` sidecars, possibly more replicas) will differ
  from the measured 2–38s, though the *mechanism* (one Secret-reference patch, one
  rollout) does not change.
