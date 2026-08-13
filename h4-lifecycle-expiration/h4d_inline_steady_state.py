#!/usr/bin/env python3
"""H4-D: closes the gap H4 and its retest (H4-B) left open -- both used 1MiB objects and so
only tested Garage's block-storage GC path. 95.4% of the real production estate is sub-1KB,
which Garage stores INLINE in the LMDB metadata store (INLINE_THRESHOLD = 3072 B, no
Version/BlockRef/block written at all). `du` on data_dir, H4's instrument, is structurally
blind to that path even when reclamation works correctly, because LMDB never returns freed
pages to the filesystem -- metadata_dir's file size can't shrink on success OR failure.

The only way to distinguish "freed and reused" from "never freed" is whether a SECOND
population's worth of writes forces the file (and LMDB's internal last_pgno, the highest page
number ever allocated) to grow further, or reuses the space the first population's expired
entries left behind. That is what this script measures, across two full write/expire/wait
cycles. Full design and the pre-registered pass/fail threshold:
../H4-INLINE-RECLAMATION.md (written and committed before this script was ever run).

Two arms, run in this order:
  1. CONTROL (ctrl-bucket): write N, measure; write N more, NEVER expire anything, measure.
     This is this test's fail-first, not a separate throwaway check -- see
     H4-INLINE-RECLAMATION.md's "governing rule" section. If metadata growth cannot be
     observed here (nothing was ever deleted, so growth is the only possible correct
     reading), the probe is broken and the treatment arm's result would be void by the same
     rule that voided the original H4.
  2. TREATMENT (treat-bucket): write N (cycle 1), apply Expiration.Date=yesterday, force an
     immediate lifecycle-worker pass (clear lifecycle_worker_state + restart the garage
     container -- the same technique H4-B established; a same-day restart alone does NOT
     re-trigger the worker), wait past TABLE_GC_DELAY (86400s, src/table/gc.rs) with margin,
     confirm object count is 0, write N more distinct objects (cycle 2, never expired), wait
     the same margin again for residual maintenance to settle, take the final measurement.

Every object body is generated fresh per-object (os.urandom). Garage is content-addressed;
reusing one body across N PUTs was the defect that silently invalidated the original H4 run
(200 MiB of PUTs collapsed into a single ~1 MiB block) -- see RESULTS.md.

Every metadata snapshot opens the LMDB environment read-only, reads stat()/info() in ONE
short-lived transaction, and closes immediately. A long-held read transaction pins the pages
visible to it and prevents Garage's own writer from reclaiming them for reuse -- holding one
open across the ~25h wait would directly suppress the exact behavior under test and silently
bias the result toward FAIL.

Resumable by design: state is checkpointed to --results after every phase transition, and on
startup this script reads any existing results file and skips phases already marked done, so
a driver-container restart (crash, OOM, node hiccup) over a ~50h unattended run does not
require restarting the whole experiment.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time

import boto3
import lmdb
from botocore.config import Config

TABLE_GC_DELAY_S = 86400  # src/table/gc.rs -- 24h metadata-tombstone GC delay
GC_WAIT_MARGIN_S = 3600  # 1h safety margin on top of the floor above
GC_WAIT_S = TABLE_GC_DELAY_S + GC_WAIT_MARGIN_S  # ~25h per cycle
POLL_INTERVAL_S = 900  # 15 min heartbeats during the long wait
N_OBJECTS = 20000
OBJECT_SIZE_B = 512  # well under INLINE_THRESHOLD (3072 B)
PASS_RATIO = 1.25
FAIL_RATIO = 1.75  # explicit "this is basically the no-reuse prediction" flag


def log(msg):
    print(f"[{datetime.datetime.now(datetime.timezone.utc).isoformat()}] {msg}", flush=True)


def du_bytes(path):
    out = subprocess.run(["du", "-sb", path], capture_output=True, text=True, check=True)
    return int(out.stdout.split()[0])


def lmdb_snapshot(meta_dir):
    """Short-lived read-only open: report last_pgno (the key page-reuse signal), map_size,
    and per-named-db entry counts. Environment and transaction are both closed before
    returning -- see module docstring for why this must never be held open.

    Garage's actual LMDB environment lives in a `db.lmdb/` subdirectory of metadata_dir
    (alongside node_key, cluster_layout, lifecycle_worker_state, etc, which are plain files,
    not part of the LMDB env) -- confirmed by listing the mounted volume directly, not
    assumed."""
    env = lmdb.open(os.path.join(meta_dir, "db.lmdb"), readonly=True, lock=False, max_dbs=64, subdir=True)
    try:
        info = env.info()
        stat = env.stat()
        named = {}
        with env.begin() as txn:
            cursor = txn.cursor()
            for key, _ in cursor:
                try:
                    name = key.decode("utf-8", errors="strict")
                except UnicodeDecodeError:
                    continue
                try:
                    sub = env.open_db(key, txn=txn, create=False)
                    named[name] = txn.stat(sub)["entries"]
                except lmdb.Error:
                    continue
        return {
            "last_pgno": info["last_pgno"],
            "map_size": info["map_size"],
            "root_entries": stat["entries"],
            "named_db_entries": named,
        }
    finally:
        env.close()


def snapshot(client, bucket, meta_dir, data_dir, label, prefix=""):
    resp = client.list_objects_v2(Bucket=bucket, Prefix=prefix)
    count = resp.get("KeyCount", 0)
    token = resp.get("NextContinuationToken")
    while resp.get("IsTruncated"):
        resp = client.list_objects_v2(Bucket=bucket, Prefix=prefix, ContinuationToken=token)
        count += resp.get("KeyCount", 0)
        token = resp.get("NextContinuationToken")
    lm = lmdb_snapshot(meta_dir)
    s = {
        "label": label,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "list_key_count": count,
        "metadata_du_bytes": du_bytes(meta_dir),
        "data_du_bytes": du_bytes(data_dir),
        "lmdb_last_pgno": lm["last_pgno"],
        "lmdb_map_size": lm["map_size"],
        "lmdb_named_db_entries": lm["named_db_entries"],
    }
    log(f"SNAPSHOT[{label}]: list_keys={count} metadata_du={s['metadata_du_bytes']:,} "
        f"data_du={s['data_du_bytes']:,} last_pgno={s['lmdb_last_pgno']:,}")
    return s


def put_distinct(client, bucket, prefix, n, size, label):
    for i in range(n):
        client.put_object(Bucket=bucket, Key=f"{prefix}{i:06d}", Body=os.urandom(size))
        if (i + 1) % 2000 == 0:
            log(f"  {label}: {i + 1}/{n} PUT")


class ResultStore:
    """Atomic, resumable checkpoint file. Every write is a temp-file + rename so a reader
    never sees a partially-written file, and this script's own restart can pick up where it
    left off instead of re-running phases already completed."""

    def __init__(self, path):
        self.path = path
        if os.path.exists(path):
            with open(path) as f:
                self.data = json.load(f)
            log(f"resuming from existing results file, phase={self.data.get('phase')}")
        else:
            self.data = {"phase": "start", "snapshots": {}}
            self._flush()

    def _flush(self):
        self.data["last_updated"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, indent=2, default=str)
        os.replace(tmp, self.path)

    def set_phase(self, phase):
        self.data["phase"] = phase
        self._flush()
        log(f"PHASE -> {phase}")

    def save_snapshot(self, key, snap):
        self.data["snapshots"][key] = snap
        self._flush()

    def done(self, key):
        return key in self.data["snapshots"]

    def get(self, key):
        return self.data["snapshots"].get(key)

    def set(self, key, value):
        self.data[key] = value
        self._flush()


def wait_with_heartbeat(store, phase_key, seconds, note=""):
    """Poll/sleep loop that survives a driver restart: records a deadline once, resumes
    against it if this key already has one, and writes a heartbeat every POLL_INTERVAL_S so
    `cat`-ing the results file mid-wait always shows real elapsed/remaining time."""
    deadline_key = f"{phase_key}_deadline"
    if store.data.get(deadline_key) is None:
        store.set(deadline_key, time.time() + seconds)
    deadline = store.data[deadline_key]
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            log(f"wait[{phase_key}] complete ({note})")
            return
        sleep_for = min(POLL_INTERVAL_S, remaining)
        log(f"wait[{phase_key}]: {remaining / 3600:.2f}h remaining ({note})")
        time.sleep(sleep_for)


def force_lifecycle_worker(container_meta_dir_from_driver, lifecycle_state_file, restart_cmd_note):
    """Clear the persisted last_completed marker so the next garage startup re-runs the
    lifecycle worker immediately instead of waiting for natural daily cadence (established in
    H4-B, see RESULTS.md and README.md's 'What broke' section). This driver container has the
    volume mounted READ-ONLY (see manifests) so it cannot delete the file itself. Confirmed
    directly (kubectl exec -c garage -- ls fails with "executable file not found in $PATH")
    that the dxflrs/garage image has no shell/coreutils at all, so `kubectl exec -c garage --
    rm ...` is not an option either -- the working mechanism is a short-lived pod mounting the
    SAME PVC read-write (RWO permits multiple pods on the SAME node) with a normal image that
    has coreutils, e.g.:
      kubectl --context sandbox-talos run h4d-trigger --rm -i --restart=Never \
        --image=python:3.12-slim -n h4d-inline-gc --overrides='{"spec":{"containers":[{
        "name":"h4d-trigger","image":"python:3.12-slim","command":["rm","-f",
        "/meta/lifecycle_worker_state"],"volumeMounts":[{"name":"v","mountPath":"/meta",
        "subPath":"meta"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":
        "garage-storage"}}]}}'
    followed by `kubectl delete pod -n h4d-inline-gc -l app=garage --wait=false` to restart
    just the garage+driver pod (the Deployment recreates it; this script's own checkpointing
    in ResultStore means the driver resumes cleanly rather than restarting the experiment).
    This function only logs the instruction; the actual trigger is a one-time manual step
    performed from outside the pod shortly after this log line appears, well within this
    cycle's 1h safety margin.
    """
    log("ACTION NEEDED (one-time, outside this pod): clear lifecycle_worker_state and "
        f"restart the garage container now. {restart_cmd_note}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--access-key", required=True)
    ap.add_argument("--secret-key", required=True)
    ap.add_argument("--ctrl-bucket", required=True)
    ap.add_argument("--treat-bucket", required=True)
    ap.add_argument("--meta-dir", required=True)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--lifecycle-state-file", required=True)
    ap.add_argument("--results", required=True)
    args = ap.parse_args()

    client = boto3.client(
        "s3", endpoint_url=args.endpoint, aws_access_key_id=args.access_key,
        aws_secret_access_key=args.secret_key,
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 5}),
        region_name="garage",
    )

    store = ResultStore(args.results)
    store.set("design", {
        "n_objects": N_OBJECTS, "object_size_bytes": OBJECT_SIZE_B,
        "table_gc_delay_s": TABLE_GC_DELAY_S, "gc_wait_s": GC_WAIT_S,
        "pass_ratio": PASS_RATIO, "fail_ratio": FAIL_RATIO,
    })

    # ---------------- CONTROL ARM (also this test's fail-first) ----------------
    if not store.done("control_cycle2"):
        store.set_phase("control-arm")
        if not store.done("control_baseline"):
            store.save_snapshot("control_baseline",
                snapshot(client, args.ctrl_bucket, args.meta_dir, args.data_dir, "control_baseline"))
        if not store.done("control_cycle1"):
            put_distinct(client, args.ctrl_bucket, "c1/", N_OBJECTS, OBJECT_SIZE_B, "control cycle1")
            store.save_snapshot("control_cycle1",
                snapshot(client, args.ctrl_bucket, args.meta_dir, args.data_dir, "control_cycle1"))
        put_distinct(client, args.ctrl_bucket, "c2/", N_OBJECTS, OBJECT_SIZE_B, "control cycle2")
        store.save_snapshot("control_cycle2",
            snapshot(client, args.ctrl_bucket, args.meta_dir, args.data_dir, "control_cycle2"))

    base = store.get("control_baseline")
    c1 = store.get("control_cycle1")
    c2 = store.get("control_cycle2")
    ctrl_delta1_du = c1["metadata_du_bytes"] - base["metadata_du_bytes"]
    ctrl_delta2_du = c2["metadata_du_bytes"] - base["metadata_du_bytes"]
    ctrl_delta1_pgno = c1["lmdb_last_pgno"] - base["lmdb_last_pgno"]
    ctrl_delta2_pgno = c2["lmdb_last_pgno"] - base["lmdb_last_pgno"]
    ctrl_ratio_du = ctrl_delta2_du / ctrl_delta1_du if ctrl_delta1_du else float("nan")
    ctrl_ratio_pgno = ctrl_delta2_pgno / ctrl_delta1_pgno if ctrl_delta1_pgno else float("nan")
    control_registers_growth = ctrl_ratio_du >= 1.5 and ctrl_ratio_pgno >= 1.5
    store.set("control_result", {
        "delta1_du": ctrl_delta1_du, "delta2_du": ctrl_delta2_du, "ratio_du": ctrl_ratio_du,
        "delta1_pgno": ctrl_delta1_pgno, "delta2_pgno": ctrl_delta2_pgno, "ratio_pgno": ctrl_ratio_pgno,
        "detector_ok": control_registers_growth,
    })
    log(f"SUMMARY test=h4d-control verdict={'DETECTOR-OK' if control_registers_growth else 'DETECTOR-BROKEN'} "
        f"ratio_du={ctrl_ratio_du:.3f} ratio_pgno={ctrl_ratio_pgno:.3f} (expect ~2.0, nothing ever expired)")

    if not control_registers_growth:
        store.set_phase("void-control-detector-broken")
        log("SUMMARY test=h4d verdict=VOID reason=control-arm-did-not-show-growth-with-nothing-deleted "
            "-- the metadata-size probe cannot register growth at all, so the treatment arm result "
            "would be void by this harness's own governing rule. Stopping.")
        sys.exit(1)

    # ---------------- TREATMENT ARM ----------------
    if not store.done("treat_baseline"):
        store.set_phase("treatment-baseline")
        store.save_snapshot("treat_baseline",
            snapshot(client, args.treat_bucket, args.meta_dir, args.data_dir, "treat_baseline"))

    if not store.done("treat_cycle1_before_rule"):
        store.set_phase("treatment-cycle1-write")
        put_distinct(client, args.treat_bucket, "expire-me/", N_OBJECTS, OBJECT_SIZE_B, "treatment cycle1")
        store.save_snapshot("treat_cycle1_before_rule",
            snapshot(client, args.treat_bucket, args.meta_dir, args.data_dir, "treat_cycle1_before_rule",
                     prefix="expire-me/"))

    if not store.data.get("rule_applied"):
        yesterday = (datetime.datetime.now(datetime.timezone.utc)
                     - datetime.timedelta(days=1)).strftime("%Y-%m-%dT00:00:00.000Z")
        client.put_bucket_lifecycle_configuration(
            Bucket=args.treat_bucket,
            LifecycleConfiguration={"Rules": [{
                "ID": "expire-me-yesterday", "Status": "Enabled",
                "Filter": {"Prefix": "expire-me/"},
                "Expiration": {"Date": yesterday},
            }]},
        )
        log(f"lifecycle rule applied: Expiration.Date={yesterday}")
        force_lifecycle_worker(args.meta_dir, args.lifecycle_state_file,
            "kubectl --context sandbox-talos exec -n h4d-inline-gc deploy/garage -c garage -- "
            "rm -f /var/lib/garage/meta/lifecycle_worker_state && "
            "kubectl --context sandbox-talos delete pod -n h4d-inline-gc -l app=garage --wait=false "
            "  # NOTE: deletes the whole pod (driver+garage) on this single-replica Deployment -- "
            "see H4-INLINE-RECLAMATION.md; this script checkpoints so the driver resumes cleanly.")
        store.set("rule_applied", True)

    store.set_phase("treatment-cycle1-waiting")
    wait_with_heartbeat(store, "cycle1_wait", GC_WAIT_S, note="TABLE_GC_DELAY + margin after cycle-1 expiry")

    if not store.done("treat_cycle1_after_gc"):
        store.save_snapshot("treat_cycle1_after_gc",
            snapshot(client, args.treat_bucket, args.meta_dir, args.data_dir, "treat_cycle1_after_gc",
                     prefix="expire-me/"))
    c1_after_gc = store.get("treat_cycle1_after_gc")
    cycle1_object_count_zero = c1_after_gc["list_key_count"] == 0
    log(f"cycle-1 GC check: list_key_count={c1_after_gc['list_key_count']} "
        f"({'PASS' if cycle1_object_count_zero else 'OBJECTS STILL PRESENT -- GC not complete or stuck'})")

    if not store.done("treat_cycle2_write"):
        store.set_phase("treatment-cycle2-write")
        put_distinct(client, args.treat_bucket, "cycle2/", N_OBJECTS, OBJECT_SIZE_B, "treatment cycle2")
        store.save_snapshot("treat_cycle2_write",
            snapshot(client, args.treat_bucket, args.meta_dir, args.data_dir, "treat_cycle2_write"))

    store.set_phase("treatment-cycle2-waiting")
    wait_with_heartbeat(store, "cycle2_wait", GC_WAIT_S, note="settle wait after cycle-2 write, same margin")

    if not store.done("treat_cycle2_final"):
        store.save_snapshot("treat_cycle2_final",
            snapshot(client, args.treat_bucket, args.meta_dir, args.data_dir, "treat_cycle2_final"))

    tbase = store.get("treat_baseline")
    t1 = store.get("treat_cycle1_before_rule")
    t2 = store.get("treat_cycle2_final")
    delta1_du = t1["metadata_du_bytes"] - tbase["metadata_du_bytes"]
    delta2_du = t2["metadata_du_bytes"] - tbase["metadata_du_bytes"]
    delta1_pgno = t1["lmdb_last_pgno"] - tbase["lmdb_last_pgno"]
    delta2_pgno = t2["lmdb_last_pgno"] - tbase["lmdb_last_pgno"]
    ratio_du = delta2_du / delta1_du if delta1_du else float("nan")
    ratio_pgno = delta2_pgno / delta1_pgno if delta1_pgno else float("nan")

    passed = ratio_du <= PASS_RATIO and ratio_pgno <= PASS_RATIO
    clear_fail = ratio_du >= FAIL_RATIO or ratio_pgno >= FAIL_RATIO
    if passed:
        verdict = "PASS"
    elif clear_fail:
        verdict = "FAIL"
    else:
        verdict = "INCONCLUSIVE"

    result = {
        "delta1_metadata_du_bytes": delta1_du, "delta2_metadata_du_bytes": delta2_du,
        "ratio_du": ratio_du,
        "delta1_last_pgno": delta1_pgno, "delta2_last_pgno": delta2_pgno,
        "ratio_pgno": ratio_pgno,
        "cycle1_object_count_zero": cycle1_object_count_zero,
        "data_dir_stayed_flat": (t2["data_du_bytes"] - tbase["data_du_bytes"]) < (N_OBJECTS * OBJECT_SIZE_B * 0.1),
        "verdict": verdict,
        "pass_threshold": PASS_RATIO, "fail_threshold": FAIL_RATIO,
    }
    store.set("treatment_result", result)
    store.set_phase("done")
    log(f"SUMMARY test=h4d-inline-steady-state verdict={verdict} ratio_du={ratio_du:.3f} "
        f"ratio_pgno={ratio_pgno:.3f} cycle1_count_zero={cycle1_object_count_zero} "
        f"threshold_pass<= {PASS_RATIO} threshold_fail>= {FAIL_RATIO}")


if __name__ == "__main__":
    main()
