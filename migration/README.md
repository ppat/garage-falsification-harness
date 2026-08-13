# MinIO → Garage bucket migration

The copy mechanism and rollback drill for moving `homelab`'s four MinIO buckets into
Garage — the actual point of the MinIO→Garage project
([apps#3611](https://github.com/ppat/homelab-ops-kubernetes-apps/issues/3611)), which the
falsification harness at the repo root didn't build. Production is read-only; nothing
here has run against real bucket contents. Everything below is either designed from
verified facts about the target systems, or proven on a synthetic fixture at realistic
per-object shape against real MinIO/Garage builds on `sandbox-talos`. The "what was
proven vs. assumed" split is in `test/README.md`.

**Repo choice.** This lives here rather than in `homelab-ops-kubernetes-apps` because
it's a one-shot operational tool run by hand against a live cluster, not a Kustomize
module (nothing here is Flux-reconciled) and not a pre-adoption experiment (the engine
decision is already made — this is what happens after it). It follows this repo's own
precedent: falsification/validation tooling for this migration lives here, decoupled
from the apps repo's release-please/module conventions.

## Scope: what's being moved, and what isn't

| bucket | objects | treatment |
| --- | --- | --- |
| `homelab-loki-ruler` | 0 | single `copy` pass, run **first**. Zero data risk — exercises credentials, endpoint, TLS, path-style addressing, and Loki's S3 client with nothing to lose. |
| `homelab-loki-chunks` | 3,439,460 | full converge → cutover → catch-up sequence (this doc) |
| `homelab-authentik-media` | 5 | single `copy` pass, single full verify. Written only on avatar upload — no delta problem. |
| `homelab-terraform-state` | 7 | single `copy` pass, single full verify. Written only by `terraform apply`; run during a window nobody is applying against `homelab`. **This does not migrate Terraform's backend config** — six workspaces' `backend "s3"` blocks moving to point at Garage is separate, deliberate follow-on work (apps#3611), not attempted here. Copying the *object* doesn't switch which bucket Terraform reads from next, and `homelab-terraform-state` holds the state of the MinIO workspaces themselves — a chicken-and-egg this tool does not need to, and does not, solve. |

The two five/seven-object buckets get the **same tool**, run once, by hand — not a
separate code path, not a shrunk-down version of the convergence/verification machinery.
Building resumability and sampled verification for 5 objects would be solving a problem
those buckets don't have (Munger's razor: some things don't need the machinery).
Proven on sandbox: both tiny-bucket copies completed and fully verified in under one
second each.

## The mechanism: `rclone copy`, current-versions-only

`bin/migrate-bucket.sh` wraps `rclone copy src:<bucket> dst:<bucket>`. Two choices carry
the whole design:

- **`copy`, never `sync`.** One-way, additive. It must never delete anything, on either
  side — see "why no destination delete-propagation" below.
- **No `--s3-versions`/`--s3-version-at`.** rclone's default S3 listing
  (`ListObjectsV2`) returns only each key's current version. On a versioned MinIO bucket
  this means noncurrent versions and delete markers are never enumerated, never copied —
  which is the entire "the migration performs the garbage collection" property this
  project is counting on (~44 GB of MinIO delete-marker/noncurrent-version bloat becomes
  ~13.5 GB of current-version data on Garage, which has no versioning at all to bloat).

That second bullet is a default, not a guarantee stated in a README — it is proven,
not assumed, by `test/test_version_exclusion.py` (see below). This project has direct
history with a check that could not have failed (apps#3611's H4 episode voided an entire
experiment over exactly this), so nothing here is trusted on the strength of a docstring.

### Why copy, not sync — and why no delete propagation

Once Loki is pointed at Garage, Garage's own compactor (unversioned bucket, plain
`Expiration`, proven by H4 to actually reclaim disk) ages out chunks by the timestamp
embedded in the chunk itself, not by when the object arrived in that store. An object
that's already past retention on MinIO at copy time, or that expires on MinIO between
the last delta pass and cutover, does not need an explicit delete propagated to Garage —
Garage's compactor independently reaps it once it crosses the same age threshold, at
most ~30 days later than it would have on MinIO. That's a bounded, self-healing,
one-time cost of the migration window, not a permanent leak, and it's why this tool
never needs a delete-propagation path at all: it is purely additive.

## The moving delta: copy → converge → cutover → catch-up

Loki writes to `homelab-loki-chunks` continuously, so a single pass is stale before it
finishes. Three options, and why the other two were rejected:

1. **Copy, converge, then flip the store Loki writes to (chosen).** Loki reads/writes
   exactly one object store at all times. Cutover is the one-line `postBuild.substitute`
   diff [apps#3618](https://github.com/ppat/homelab-ops-kubernetes-apps/pull/3618) built
   for exactly this — parameterized secret-store *key names*, not values, so pointing
   Loki at a different store is a git-tracked diff in the clusters repo, not an untracked
   Bitwarden edit.
2. **Flip writes to Garage first, backfill history behind it — rejected.** Loki's
   compactor is bound to one object store per schema period; a live split between "new
   chunks land in Garage" and "history still being backfilled from MinIO" means either
   the compactor can't see the full picture, or queries need to consult both stores
   mid-backfill. That's exactly the "two-datasource" approach apps#3611 already flagged
   as *unverified at this chart version* ("Loki multi-backend support ... is unverified.
   The two-datasource approach ... deliberately routes around needing an answer") and
   chose the full-copy path specifically to avoid. Choosing this option quietly
   reintroduces the dual-read problem the project's own plan routed around.
3. **Exploit 30-day retention, let MinIO-resident data age out, migrate nothing —
   rejected.** This was the *original* scope
   ("The 3.44M Loki objects are not being migrated... Retention is 30d and the trial is
   30d") and was explicitly superseded once the owner asked for a real migration. Same
   dual-read objection as option 2 for the ~30-day overlap window.

Mechanically, option 1 means:

- **Pass 1**: full `rclone copy` of current-version objects. Long — measured 343s for
  28,502 objects (~83 objects/s) on a contended shared sandbox node; see "what was
  proven vs. assumed" for how this projects to 3.44M.
- **Pass 2..N (converge)**: repeat. Each pass only transfers what changed since the
  previous pass *started*, so each pass is bounded by that pass's write volume, not the
  whole bucket. Stop when a pass transfers under `MIN_DELTA_OBJECTS` (default 50) or
  completes in under `MIN_DELTA_SECONDS` (default 60s). Measured: pass 2 transferred 0
  objects in 19s and converged immediately, on real Loki-shaped churn (see rollback
  drill below — a live Loki instance was writing to the source bucket during this run).
- **Cutover**: flip `loki_s3_endpoint_key`/`loki_s3_accesskeyid_key`/
  `loki_s3_secretkey_key` (and confirm `loki_s3_region` already matches Garage's
  `s3_api.s3_region`, both `us-east-1` — see "facts verified" below) in the clusters
  repo. Loki restarts pointed at Garage. MinIO stops receiving writes.
- **Final catch-up pass**: run the copy once more, *after* cutover. This closes the gap
  between the last converge pass and the moment Loki actually stopped writing to MinIO
  (bounded by pod restart time, not ingestion rate). Proven necessary, not theoretical:
  the sandbox rollback drill hit exactly this gap — a tsdb index file Loki shipped to
  MinIO *after* the bulk copy snapshot wasn't on Garage until a catch-up pass ran, and
  Loki's post-cutover queries were empty until it did.
- **Verify** (tiers below) against the final state.

## Resumability

No custom checkpoint file. The destination bucket's own contents *are* the checkpoint:
`rclone copy` is idempotent — an object already present at the destination with a
matching checksum is skipped, never re-transferred, never deleted-then-recreated. Every
object in scope (95.4% under 1KB, none within two orders of magnitude of the 200MiB
multipart cutoff) is written with a single atomic S3 PUT, so there is no partial-object
state to resume into: at the moment of interruption, each object is either fully present
or entirely absent, never truncated.

This is deliberately not a home-rolled progress file. This project has already lost or
corrupted experiment data three times to interrupted long-running processes with exactly
that failure shape — a checkpoint that itself gets corrupted, or that claims "done" for
something that wasn't. Making the object store itself the single source of truth for
what's done removes that failure class instead of working around it.

Kubernetes-level: the migration Job (`k8s/job-migrate-bucket.yaml.template`) uses
`restartPolicy: OnFailure`. A killed pod, an evicted pod, a node restart — all just mean
the same idempotent `rclone copy` command runs again.

**Proven, not just argued** (`test/test-resume-after-kill.sh`): a live copy was
SIGKILLed at 582/1,425 objects transferred, resumed with the identical command, and the
final destination state was byte-identical (full hash comparison) to an uninterrupted
baseline copy, with zero truncated or corrupt objects.

## Verification: three tiers, three different claims

Cheapest/weakest first. Each is a **separate claim** — a cheaper tier passing does not
imply a more expensive one would.

| tier | cost | catches | does not catch |
| --- | --- | --- | --- |
| **tier0** (count + bytes) | LIST-only | wrong bucket/creds, aborted run, gross over/under-copy (e.g. a naive tool that also copied noncurrent versions) | any single wrong/corrupt object, as long as count and total bytes coincidentally still match |
| **tier1** (stratified sample, full hash) | ~5,000 objects × ~4KB mean ≈ single-digit MB read per side | silent corruption, truncation, wrong-object-at-key — for anything landing in the sample | a defect confined to objects outside the sample (bounded false-negative probability, not zero) |
| **tier2** (full hash, every current-version object) | LIST/HEAD-cost, not data-read-cost — see below | everything tier1 catches, with certainty | anything upstream/downstream of the object store itself (Loki's own chunk-boundary/query correctness is out of this tool's scope) |

**Why tier2 is not "read 13.5GB twice."** S3 sets the ETag to the content MD5 for any
non-multipart PUT. Every object in scope qualifies (95.4% under 1KB, none near the
multipart threshold). `rclone check` compares the ETag both backends already return from
`ListObjectsV2`/`HEAD`, without downloading bodies. Measured on sandbox: a full tier2
check of 28,502 objects (108.5MB) completed in 109s; the corruption-detection test's
`ERROR : ...: md5 differ` log line confirms the comparison is genuinely hash-based, not
size-only (a corrupted object of the *same size* as the original was still caught).
`test/test-etag-check-cost.sh` gives directional timing evidence (object-count-scaled,
not byte-scaled) but the primary basis for this claim is rclone's documented S3 ETag
comparison behavior, not a from-scratch empirical derivation — stated honestly rather
than over-claimed from a thin data point.

**Sample-size honesty for tier1.** At the real bucket's 3.44M objects, a defect confined
to a single object has roughly `n/N` ≈ 5,000/3,439,460 ≈ **0.15%** detection probability
in one tier1 sample. tier1 is a defense against a *systematic* defect (a whole prefix, a
whole size class), not a needle-in-a-haystack single corruption — that's what tier2 is
for, and why tier2 is cheap enough to always run at cutover rather than being optional.

## Falsifiability: what could have been true by construction

Per this project's own standard (H4: a fail-first that could never fail voided an entire
experiment), every check here was proven capable of failing before being trusted to
pass — see `test/README.md` for the full write-up. Summary, all run against real MinIO
(`quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z`, the exact build in production) and
real Garage (`dxflrs/garage:v2.3.0`, same) on `sandbox-talos`:

- **Version exclusion** (`test_version_exclusion.py`): independent ground truth from
  `ListObjectVersions` (a *different* API than the tool's own listing) said 1,425 keys
  should exist current. A deliberately wrong naive copy (resurrects a deleted key's last
  real body) produced 1,500 — correctly flagged as wrong. The real `rclone copy`
  produced exactly 1,425.
- **Corruption detection** (`test-corruption-detection.sh`): tier2 passed pre-corruption,
  failed on an injected same-size random overwrite, passed again after repair.
- **Resumability** (`test-resume-after-kill.sh`): SIGKILLed mid-copy, resumed, final
  state byte-identical to an uninterrupted baseline.

## Rollback drill

The owner's requirement, verbatim in spirit: *cut over, roll back, confirm healthy, cut
over again — because a rollback that has never been executed is a paragraph, not a
rollback.* Drilled end-to-end on `sandbox-talos` against a real (throwaway, minimal)
`grafana/loki:3.7.6` instance reading real data this tool migrated — not simulated.

**The mechanism**: cutover and rollback are both "change which Kubernetes Secret name
the storage config reads from," never an edit to a Secret's contents. That's the literal
mechanical analog of what apps#3618 built (parameterized secret-store *key names*) so
this would be a one-line, git-tracked, revertable diff.

**Sequence and measured cost** (patch → rollout-ready, single-binary Loki, no caches):

| step | time | result |
| --- | --- | --- |
| Loki running against MinIO, push + query | — | log line pushed, queried back from the live ingester |
| **Cut over** to Garage | 38s | fresh pod, restart from zero local state, queried the pre-cutover log line back successfully — proving the migrated data is genuinely Loki-readable, not just "S3 objects that look right" |
| **Roll back** to MinIO | 2s | queried the same log line back successfully |
| **Cut over again** to Garage | 25s | queried the same log line back successfully |

Cost is dominated by pod restart time on a single-binary, single-replica instance with
no caches — production Loki (with `loki-chunks-cache`/`loki-results-cache` sidecars and
possibly more replicas) will differ, but the *mechanism's* cost (one Secret-reference
patch, one rollout) does not. Risk: brief unavailability during each restart, same as
any config change today; **no data-loss risk in either direction**, because the
migration tool never deletes from MinIO — MinIO stays a complete, valid fallback for as
long as it's kept around.

**What the drill caught that a "looks fine" check wouldn't have**: the first
post-cutover query came back empty. Not because Garage was missing data — because Loki
had shipped a new tsdb index file to MinIO *after* the bulk copy snapshot, and that file
hadn't been caught by a catch-up pass yet. This is exactly the moving-delta problem this
design document argues for above, caught in practice, not just in the abstract — running
one more `migrate-bucket.sh <bucket> once` picked it up and the query returned correctly
on the next fresh pod.

## Pre-flight: region canary

Garage enforces an exact match between the region a client signs with and its own
configured `s3_api.s3_region`. A mismatch is `AuthorizationHeaderMalformed` on **every**
request, with no client-side retry — already reproduced live
(`logging/loki-0` on `sandbox-talos`, 278+ restarts,
[apps#3611 comment 5282296514](https://github.com/ppat/homelab-ops-kubernetes-apps/issues/3611#issuecomment-5282296514)).
`bin/preflight-canary.sh` round-trips one throwaway object through the destination
before the bulk copy starts. Proven on sandbox: this fails in about a second, not 40
minutes into a multi-million-object pass — and a real region mismatch was never observed
in this run only because the destination region was verified before the first real copy,
not by luck.

## Facts verified before writing any of this (not taken on trust)

- [apps#3618](https://github.com/ppat/homelab-ops-kubernetes-apps/pull/3618)
  (parameterized Loki S3 secret-store key names) is **merged**.
- `infrastructure/subsystems/storage-core/garage/conf.d/garage.toml` on
  `feat/garage-drop-operator` ([apps#3639](https://github.com/ppat/homelab-ops-kubernetes-apps/pull/3639),
  unmerged, read-only — not touched) sets `s3_region = "${garage_s3_region}"`, a required
  postBuild variable with no default, and its own comment states the estate's chosen
  value is `us-east-1` — matching `loki_s3_region`
  ([clusters#909](https://github.com/ppat/homelab-ops-kubernetes-clusters/pull/909)).
  Checked directly rather than trusted: an earlier read of this same file (surfaced in
  [clusters#908](https://github.com/ppat/homelab-ops-kubernetes-clusters/pull/908)'s own
  body) found `s3_region` still hardcoded to the literal `"garage"` — the parameterization
  landed on the branch between that check and this one, which is exactly why this was
  re-verified against the file directly rather than assumed from either PR's prose.
- Terraform (`homelab-ops-terraform` PR #290) provisions Garage buckets/keys; this tool
  assumes they already exist and never creates them as a side effect (confirmed by
  design — `preflight-canary.sh` and `migrate-bucket.sh` only ever `PUT`/`GET`/`DELETE`
  objects, never call `CreateBucket`).

## Usage

```bash
# 0. One-time: load the mechanism scripts into the namespace as a ConfigMap
#    (this is the entire deployable artifact -- no image to build)
kubectl create configmap migration-scripts -n <namespace> \
  --from-file=bin/migrate-bucket.sh --from-file=bin/verify-bucket.sh \
  --from-file=bin/preflight-canary.sh --from-file=bin/render-rclone-conf.sh \
  --from-file=bin/entrypoint.sh --from-file=bin/rclone.conf.template

# 1. Preflight every destination bucket (region/credentials canary, ~1s each)
BUCKET=homelab-loki-ruler PHASE=preflight ... # see k8s/job-migrate-bucket.yaml.template

# 2. Ruler first (empty, zero risk), then chunks, then the two tiny buckets
BUCKET=homelab-loki-ruler PHASE=copy MODE=once ...
BUCKET=homelab-loki-chunks PHASE=copy MODE=converge ...   # repeat until it reports converged
BUCKET=homelab-authentik-media PHASE=copy MODE=once ...
BUCKET=homelab-terraform-state PHASE=copy MODE=once ...

# 3. Verify each (tier0 always; tier2 before trusting a cutover)
BUCKET=homelab-loki-chunks PHASE=verify MODE=tier2 ...

# 4. Cut over (clusters repo: flip loki_s3_*_key postBuild variables), then:
BUCKET=homelab-loki-chunks PHASE=copy MODE=once ...        # final catch-up pass
BUCKET=homelab-loki-chunks PHASE=verify MODE=tier2 ...      # final verify
```

See `k8s/job-migrate-bucket.yaml.template` for the exact env vars and how credentials
are sourced. See `test/README.md` for how to run the falsifiability tests against a
fresh sandbox.
