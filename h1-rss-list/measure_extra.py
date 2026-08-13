#!/usr/bin/env python3
"""H1 supplementary checkpoint measurement, run AFTER loader.py's own write+measure phase
for a given checkpoint (both containers' object counts must already be stable at that
checkpoint). Adds the two things the original loader.py did not capture:

  1. RSS anon-vs-file split, via /proc/<pid>/smaps_rollup on the host (same technique
     loader.py uses for total VmRSS -- no shell in the Garage image, so read the container's
     init PID's /proc entry directly from the host via sudo). LMDB is mmap'd, so most of
     Garage's RSS should be file-backed (elastic, reclaimable under memory pressure) rather
     than anonymous (the real OOM-risk portion) -- this is what the pre-registered "RSS > 6
     GiB" kill criterion cannot distinguish on its own.
  2. `du -sb` on Garage's metadata_dir and data_dir SEPARATELY (MinIO only has one data dir).

Instrumentation validated 2026-08-12 with synthetic ground truth before trusting it against
a real container (see RESULTS-H1-completion.md "Instrumentation validation"): a touched 50MB
anonymous bytearray attributed +51,204/-64 kB to Anonymous/file-backed; a touched 60MB
read-only file mmap attributed +8/+61,440 kB to Anonymous/file-backed -- the split cleanly
discriminates the two cases it exists to tell apart. `du -sb` was cross-checked against a
17,825,792-byte file and returned exactly that figure (ext4, no compression).
"""
import argparse
import json
import subprocess
import time


def read_pid(container):
    return subprocess.run(
        ["docker", "inspect", "-f", "{{.State.Pid}}", container],
        capture_output=True, text=True, timeout=10, check=True,
    ).stdout.strip()


def read_smaps_rollup_kib(pid):
    text = subprocess.run(
        ["sudo", "cat", f"/proc/{pid}/smaps_rollup"],
        capture_output=True, text=True, timeout=10, check=True,
    ).stdout
    d = {}
    for line in text.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            v = v.strip()
            if v.endswith("kB"):
                d[k.strip()] = int(v.split()[0])
    return d


def du_bytes(path):
    # timeout=180 was enough through the 1M checkpoint but timed out at 2M on MinIO's
    # data_dir: MinIO stores one file (plus per-object xl.meta) per object, so `du -sb`
    # has to stat millions of inodes -- an operational cost Garage's LMDB-backed
    # metadata_dir (a handful of large files) doesn't pay. This is itself a real finding
    # about the two engines, not just a harness bug -- see RESULTS-H1-completion.md.
    # Raised generously (30 min) since this runs during the measurement phase, off the
    # write-throughput critical path, and object count only grows from here (up to 3.44M).
    out = subprocess.run(
        ["sudo", "du", "-sb", path],
        capture_output=True, text=True, timeout=1800, check=True,
    ).stdout
    return int(out.split()[0])


def snapshot(container, extra_dirs):
    pid = read_pid(container)
    r = read_smaps_rollup_kib(pid)
    rec = {
        "rss_kib": r.get("Rss", 0),
        "anon_kib": r.get("Anonymous", 0),
        "file_kib_approx": r.get("Rss", 0) - r.get("Anonymous", 0),
        "pss_anon_kib": r.get("Pss_Anon", 0),
        "pss_file_kib": r.get("Pss_File", 0),
        "pss_shmem_kib": r.get("Pss_Shmem", 0),
    }
    for name, path in extra_dirs.items():
        rec[name] = du_bytes(path)
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", type=int, required=True)
    ap.add_argument("--garage-container", default="h1-garage")
    ap.add_argument("--minio-container", default="h1-minio")
    ap.add_argument("--garage-meta-dir", default="/opt/build-scratch/h1-data/garage-meta")
    ap.add_argument("--garage-data-dir", default="/opt/build-scratch/h1-data/garage-data")
    ap.add_argument("--minio-data-dir", default="/opt/build-scratch/h1-data/minio")
    ap.add_argument("--out", default="h1-extra-results.jsonl")
    args = ap.parse_args()

    record = {"checkpoint": args.checkpoint, "ts": time.time()}
    record["garage"] = snapshot(
        args.garage_container,
        {"metadata_dir_bytes": args.garage_meta_dir, "data_dir_bytes": args.garage_data_dir},
    )
    record["minio"] = snapshot(
        args.minio_container,
        {"data_dir_bytes": args.minio_data_dir},
    )

    with open(args.out, "a") as f:
        f.write(json.dumps(record) + "\n")

    g, m = record["garage"], record["minio"]
    print(
        f"[extra] checkpoint={args.checkpoint} "
        f"garage_rss={g['rss_kib']/1024:.1f}MiB (anon={g['anon_kib']/1024:.1f} file={g['file_kib_approx']/1024:.1f}) "
        f"meta_dir={g['metadata_dir_bytes']/1e6:.1f}MB data_dir={g['data_dir_bytes']/1e6:.1f}MB | "
        f"minio_rss={m['rss_kib']/1024:.1f}MiB (anon={m['anon_kib']/1024:.1f} file={m['file_kib_approx']/1024:.1f}) "
        f"data_dir={m['data_dir_bytes']/1e6:.1f}MB",
        flush=True,
    )


if __name__ == "__main__":
    main()
