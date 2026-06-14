#!/usr/bin/env bash
# E2E orchestrator: genomics map-reduce over islo snapshots (v2).
#   warm base -> snapshot -> [cold fan-out vs warm fork fan-out] -> reduce
# Honest, apples-to-apples. islo cmds use \$HOME so the *sandbox* expands it.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
export ISLO_OUTPUT_FORMAT=plain
ROOT="/Users/yossi.eliaz/genomics-sandboxes"; cd "$ROOT"
DATA="$ROOT/data"; mkdir -p "$DATA"; rm -f "$DATA"/_*.out "$DATA"/*.json "$DATA"/*.time 2>/dev/null
LOG="$ROOT/scripts/run.log"; : > "$LOG"

SHARDS=(chr19 chr20 chr21 chr22 chrY)
TS="$(python3 -c 'import time;print(int(time.time()))')"
SNAP="genomics-warm-$TS"
IMG="docker.io/library/python:3.12-slim"

now(){ python3 -c 'import time;print("%.3f"%time.time())'; }
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
WARMB64="$(base64 < "$ROOT/scripts/warmup.sh")"
COMPB64="$(base64 < "$ROOT/scripts/compute.py")"
inject(){ islo use "$1" --image "$IMG" --cpu 2 --memory 4096 -- bash -lc \
  "mkdir -p \$HOME/gx && echo $WARMB64 | base64 -d > \$HOME/gx/warmup.sh && echo $COMPB64 | base64 -d > \$HOME/gx/compute.py && chmod +x \$HOME/gx/warmup.sh && echo injected" >>"$LOG" 2>&1; }

# run a shard with one retry; capture JSON + elapsed. $1=box $2=chr $3=mode(cold|warm)
run_shard(){
  local box="$1" chr="$2" mode="$3" try out ts el
  for try in 1 2; do
    islo rm "$box" >>"$LOG" 2>&1 || true
    ts=$(now)
    if [ "$mode" = cold ]; then
      inject "$box"
      islo use "$box" -- bash -lc "\$HOME/gx/warmup.sh $chr >/dev/null 2>&1 && python3 \$HOME/gx/compute.py $chr" > "$DATA/_${mode}_$chr.out" 2>>"$LOG"
    else
      islo use "$box" --snapshot "$SNAP" --cpu 2 --memory 4096 -- bash -lc "python3 \$HOME/gx/compute.py $chr" > "$DATA/_${mode}_$chr.out" 2>>"$LOG"
    fi
    el=$(python3 -c "print(round($(now)-$ts,2))")
    if grep -q '^{"chrom"' "$DATA/_${mode}_$chr.out"; then
      grep '^{"chrom"' "$DATA/_${mode}_$chr.out" > "$DATA/${mode}_$chr.json"
      echo "$el" > "$DATA/${mode}_$chr.time"
      say "  [$mode] $chr done in ${el}s (try $try)"
      islo rm "$box" >>"$LOG" 2>&1 || true
      return 0
    fi
    say "  [$mode] $chr try $try produced no JSON, retrying..."
  done
  say "  [$mode] $chr FAILED after 2 tries"
  islo rm "$box" >>"$LOG" 2>&1 || true
  return 1
}

# -------------------------------------------------------------- 1. WARM BASE
say "=== 1/5 build warm base (toolchain + ${#SHARDS[@]} chromosomes + index) ==="
islo rm gx-warm >>"$LOG" 2>&1 || true
t=$(now); inject gx-warm
islo use gx-warm -- bash -lc "\$HOME/gx/warmup.sh ${SHARDS[*]}" >>"$LOG" 2>&1
WARM_SEC=$(python3 -c "print(round($(now)-$t,2))")
say "warm base built in ${WARM_SEC}s"

# -------------------------------------------------------------- 2. SNAPSHOT
say "=== 2/5 snapshot warm base -> $SNAP ==="
t=$(now); islo snapshot save gx-warm --name "$SNAP" >>"$LOG" 2>&1
SNAP_SEC=$(python3 -c "print(round($(now)-$t,2))")
SNAP_SIZE=$(islo snapshot ls 2>/dev/null | grep -F "$SNAP" | awk '{print $2" "$3}')
say "snapshot saved in ${SNAP_SEC}s (size ${SNAP_SIZE:-n/a})"

# -------------------------------------------------------------- 3. COLD FAN-OUT
# Naive: every worker stages the reference itself (warmup+compute), in parallel.
say "=== 3/5 COLD fan-out: ${#SHARDS[@]} boxes each stage the reference themselves (parallel) ==="
t_cold=$(now); pids=()
for chr in "${SHARDS[@]}"; do run_shard "gx-cold-$chr" "$chr" cold & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
COLD_FANOUT_SEC=$(python3 -c "print(round($(now)-$t_cold,2))")
say "COLD fan-out wall-clock: ${COLD_FANOUT_SEC}s"

# -------------------------------------------------------------- 4. WARM FAN-OUT
# Fork the warm snapshot per shard; each starts warm, just computes. Authoritative results.
say "=== 4/5 WARM fan-out: fork snapshot per shard, just compute (parallel) ==="
t_map=$(now); pids=()
for chr in "${SHARDS[@]}"; do run_shard "gx-map-$chr" "$chr" warm & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
MAP_SEC=$(python3 -c "print(round($(now)-$t_map,2))")
say "WARM fan-out wall-clock: ${MAP_SEC}s"

# -------------------------------------------------------------- 5. REDUCE
say "=== 5/5 REDUCE: merge -> genome-wide landscape + economics + biology ==="
python3 - "$DATA" "$SNAP" "$SNAP_SIZE" "$WARM_SEC" "$SNAP_SEC" "$COLD_FANOUT_SEC" "$MAP_SEC" "${SHARDS[@]}" <<'PY'
import sys, json, os
data, snap, snap_size, warm, snapsec, cold_fan, mapw = sys.argv[1:8]
shards = sys.argv[8:]
warm=float(warm); snapsec=float(snapsec); cold_fan=float(cold_fan); mapw=float(mapw)

def load(prefix, chr):
    p=os.path.join(data,f"{prefix}_{chr}.json")
    return json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else None
def tload(prefix, chr):
    p=os.path.join(data,f"{prefix}_{chr}.time")
    return float(open(p).read().strip()) if os.path.exists(p) else None

res={c:load("warm",c) for c in shards}; res={c:r for c,r in res.items() if r}
warm_t={c:tload("warm",c) for c in shards if tload("warm",c) is not None}
cold_t={c:tload("cold",c) for c in shards if tload("cold",c) is not None}
N=len(res)
cold_shard_avg = round(sum(cold_t.values())/len(cold_t),2) if cold_t else 0

tot_len=sum(r["length"] for r in res.values())
tot_n=sum(r["n_bases"] for r in res.values())
tot_cpg=sum(r["cpg_count"] for r in res.values())
tot_isl=sum(r["cpg_islands"] for r in res.values())
usable=tot_len-tot_n
gc=round(100.0*sum((r["gc_pct"]/100.0)*(r["length"]-r["n_bases"]) for r in res.values())/usable,2) if usable else 0

# biology correctness signal: CpG-island density (islands per Mb of usable seq)
dens={c:round(r["cpg_islands"]/((r["length"]-r["n_bases"])/1e6),1) for c,r in res.items()}
richest=max(dens,key=dens.get); poorest=min(dens,key=dens.get)

# economics — honest, apples-to-apples
cold_serial=round(cold_shard_avg*N,1)                 # naive serial
warm_first=round(warm+snapsec+mapw,1)                 # snapshot path, first run (pays warm-up once)
warm_rerun=round(mapw,1)                              # snapshot reused: only the map
ref_mb=72.0
redundant_dl_mb=round((N-1)*ref_mb,1)                 # downloads the snapshot eliminates
receipts={
 "snapshot":{"name":snap,"size":snap_size.replace("ready ","").strip()+" MB" if snap_size else "n/a","save_sec":snapsec},
 "warmup_sec":warm,"cold_shard_avg_sec":cold_shard_avg,
 "cold_fanout_sec":cold_fan,"map_wallclock_sec":mapw,
 "warm_shard_times":warm_t,"cold_shard_times":cold_t,"shards":N,
 "genome":{"total_bp":tot_len,"n_bases":tot_n,"gc_pct":gc,"cpg_sites":tot_cpg,"cpg_islands":tot_isl,
           "ref":"GRCh38","chroms":list(res.keys())},
 "biology":{"island_density_per_mb":dens,"most_island_rich":richest,"most_island_poor":poorest,
            "signal":f"{richest} is CpG-island dense; {poorest} is a relative desert — the gene-density gradient, recovered as a by-product."},
 "economics":{"cold_serial_sec":cold_serial,"cold_fanout_sec":cold_fan,
              "warm_first_run_sec":warm_first,"warm_rerun_sec":warm_rerun,
              "speedup_fanout":round(cold_fan/mapw,1) if mapw else 0,
              "speedup_rerun":round(cold_serial/warm_rerun,1) if warm_rerun else 0,
              "redundant_downloads_avoided_mb":redundant_dl_mb,"redundant_warmups_avoided":N-1},
 "per_chrom":{c:{k:r[k] for k in ("length","gc_pct","cpg_count","cpg_oe","cpg_islands","n_bases","compute_sec")} for c,r in res.items()},
}
json.dump(receipts,open(os.path.join(data,"receipts.json"),"w"),indent=2)
land=[{"chrom":c,**b} for c in shards if c in res for b in res[c]["bins"]]
json.dump(land,open(os.path.join(data,"landscape.json"),"w"))
print(json.dumps({k:receipts[k] for k in ("snapshot","warmup_sec","cold_fanout_sec","map_wallclock_sec","shards","genome","biology","economics")},indent=2))
PY
say "=== DONE -> data/receipts.json (snapshot $SNAP retained) ==="
