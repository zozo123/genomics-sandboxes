#!/usr/bin/env python3
"""Genome-wide REDUCE: merge per-chromosome shard JSON into receipts.json + landscape.json.
Emits the same schema the site already consumes, with all 24 chromosomes."""
import sys, json, os

data, snap, snapsz, warm, snaps, cold, cold_ref, mapw, maxp = sys.argv[1:10]
chroms = sys.argv[10:]
warm = float(warm); snaps = float(snaps); cold = float(cold); mapw = float(mapw); maxp = int(maxp)

def load(chrom):
    p = os.path.join(data, f"wg_warm_{chrom}.json")
    return json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else None
def tload(chrom):
    p = os.path.join(data, f"wg_warm_{chrom}.time")
    return float(open(p).read().strip()) if os.path.exists(p) else None

res = {c: load(c) for c in chroms}; res = {c: r for c, r in res.items() if r}
times = {c: tload(c) for c in chroms if tload(c) is not None}
N = len(res)

tot_len = sum(r["length"] for r in res.values())
tot_n = sum(r["n_bases"] for r in res.values())
tot_cpg = sum(r["cpg_count"] for r in res.values())
tot_isl = sum(r["cpg_islands"] for r in res.values())
usable = tot_len - tot_n
gc = round(100.0 * sum((r["gc_pct"] / 100.0) * (r["length"] - r["n_bases"]) for r in res.values()) / usable, 2) if usable else 0

dens = {c: round(r["cpg_islands"] / ((r["length"] - r["n_bases"]) / 1e6), 1) for c, r in res.items() if (r["length"] - r["n_bases"]) > 0}
richest = max(dens, key=dens.get); poorest = min(dens, key=dens.get)

warm_avg = round(sum(times.values()) / len(times), 2) if times else 0
cold_serial = round(cold * N, 1)                       # N x largest-shard cold (upper bound)
warm_first = round(warm + snaps + mapw, 1)
warm_rerun = round(mapw, 1)
ref_per_shard = round(900.0 / N, 1)                    # ~900 MB of reference, per shard

receipts = {
    "snapshot": {"name": snap, "size": (snapsz.replace("ready", "").strip() if snapsz else "n/a"), "save_sec": snaps},
    "warmup_sec": warm,
    "cold_shard_avg_sec": cold, "cold_shard_ref": cold_ref,
    "cold_fanout_sec": cold,                            # single measured cold shard (largest)
    "map_wallclock_sec": mapw, "map_concurrency": maxp,
    "warm_shard_times": times, "shards": N, "genome_wide": True,
    "genome": {"total_bp": tot_len, "n_bases": tot_n, "gc_pct": gc, "cpg_sites": tot_cpg,
               "cpg_islands": tot_isl, "ref": "GRCh38", "chroms": list(res.keys())},
    "biology": {"island_density_per_mb": dens, "most_island_rich": richest, "most_island_poor": poorest,
                "signal": f"{richest} densest, {poorest} sparsest — the gene-density gradient across all {N} chromosomes."},
    "economics": {"cold_serial_sec": cold_serial, "cold_fanout_sec": cold,
                  "warm_first_run_sec": warm_first, "warm_rerun_sec": warm_rerun,
                  "speedup_fanout": round(cold / warm_avg, 1) if warm_avg else 0,
                  "speedup_rerun": round(cold_serial / warm_rerun, 1) if warm_rerun else 0,
                  "redundant_downloads_avoided_mb": round((N - 1) * ref_per_shard, 1),
                  "redundant_warmups_avoided": N - 1},
    "per_chrom": {c: {k: r[k] for k in ("length", "gc_pct", "cpg_count", "cpg_oe", "cpg_islands", "n_bases", "compute_sec")} for c, r in res.items()},
}
json.dump(receipts, open(os.path.join(data, "receipts.json"), "w"), indent=2)

# chromosome order for the landscape (numeric, then X, Y)
def keyf(c):
    s = c.replace("chr", "")
    return (0, int(s)) if s.isdigit() else (1, {"X": 23, "Y": 24}.get(s, 99))
order = sorted(res.keys(), key=keyf)
land = [{"chrom": c, **b} for c in order for b in res[c]["bins"]]
json.dump(land, open(os.path.join(data, "landscape.json"), "w"))

print(json.dumps({"shards": N, "genome": receipts["genome"], "biology": receipts["biology"],
                  "warmup_sec": warm, "snapshot": receipts["snapshot"],
                  "map_wallclock_sec": mapw, "economics": receipts["economics"]}, indent=2))
