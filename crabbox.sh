#!/usr/bin/env bash
#
# crabbox.sh — genome-wide reference-broadcast fan-out on a throwaway cloud fabric.
#
#   ./crabbox.sh run        # warm one box (all 24 GRCh38 chromosomes + index),
#                           # snapshot it, fork one box per chromosome, reduce, time it, tear down.
#
# Why this exists
#   The reference genome + indices are large, read-only, and shared by every shard
#   of a scatter-gather. Instead of re-staging them per worker, we warm one box,
#   snapshot its initialized state once, and restore-and-fork it copy-on-write per
#   chromosome. This is the genome-wide version of the 5-chromosome demo.
#
# How it works (and where crabbox fits)
#   crabbox (https://github.com/openclaw/crabbox) is the ephemeral "warm a box,
#   sync the working tree, run the suite, tear down" path; it leases boxes from a
#   broker that runs on islo.dev's sandbox fabric. crabbox's lease path needs a
#   configured coordinator (`crabbox login --url <broker>`). When a coordinator is
#   present we go through `crabbox run`; otherwise we drive the same fabric directly
#   through the islo CLI (snapshot + restore-and-fork), which is what the
#   snapshot-broadcast argument actually requires. Either way the orchestrator —
#   the "harness" that calls warm → snapshot → fork → reduce and times each phase —
#   is an agent (Claude Code), not a human at a terminal.
#
# Requirements
#   - islo            (https://islo.dev), logged in   — sandbox fabric
#   - crabbox         (optional; only used if a coordinator is configured)
#
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
export ISLO_OUTPUT_FORMAT=plain
ROOT="/Users/yossi.eliaz/genomics-sandboxes"; cd "$ROOT"
DATA="$ROOT/data"; mkdir -p "$DATA"
LOG="$ROOT/scripts/wg.log"; : > "$LOG"

# all 24 GRCh38 chromosomes
CHROMS=(chr1 chr2 chr3 chr4 chr5 chr6 chr7 chr8 chr9 chr10 chr11 chr12 \
        chr13 chr14 chr15 chr16 chr17 chr18 chr19 chr20 chr21 chr22 chrX chrY)
MAXP="${MAXP:-8}"                       # concurrent forks (fabric-friendly waves)
TS="$(python3 -c 'import time;print(int(time.time()))')"
SNAP="genomics-wg-$TS"
IMG="docker.io/library/python:3.12-slim"
FORKMEM="${FORKMEM:-8192}"              # chr1 (~250 Mb) needs headroom
COLD_REF="chr1"                         # cold baseline shard (largest)

now(){ python3 -c 'import time;print("%.3f"%time.time())'; }
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
WARMB64="$(base64 < "$ROOT/scripts/warmup.sh")"
COMPB64="$(base64 < "$ROOT/scripts/compute.py")"
inject(){ islo use "$1" --image "$IMG" --cpu 2 --memory 4096 --disk 25 -- bash -lc \
  "mkdir -p \$HOME/gx && echo $WARMB64 | base64 -d > \$HOME/gx/warmup.sh && echo $COMPB64 | base64 -d > \$HOME/gx/compute.py && chmod +x \$HOME/gx/warmup.sh && echo ok" >>"$LOG" 2>&1; }

run_shard(){ # $1 box $2 chr $3 mode(cold|warm)
  local box="$1" chr="$2" mode="$3" try ts el
  for try in 1 2; do
    islo rm "$box" >>"$LOG" 2>&1 || true
    ts=$(now)
    if [ "$mode" = cold ]; then
      inject "$box"
      islo use "$box" --cpu 2 --memory "$FORKMEM" --disk 25 -- bash -lc "\$HOME/gx/warmup.sh $chr >/dev/null 2>&1 && python3 \$HOME/gx/compute.py $chr" > "$DATA/_wg_${mode}_$chr.out" 2>>"$LOG"
    else
      islo use "$box" --snapshot "$SNAP" --cpu 2 --memory "$FORKMEM" -- bash -lc "python3 \$HOME/gx/compute.py $chr" > "$DATA/_wg_${mode}_$chr.out" 2>>"$LOG"
    fi
    el=$(python3 -c "print(round($(now)-$ts,2))")
    if grep -q '^{"chrom"' "$DATA/_wg_${mode}_$chr.out"; then
      grep '^{"chrom"' "$DATA/_wg_${mode}_$chr.out" > "$DATA/wg_${mode}_$chr.json"
      echo "$el" > "$DATA/wg_${mode}_$chr.time"
      say "  [$mode] $chr ${el}s (try $try)"; islo rm "$box" >>"$LOG" 2>&1 || true; return 0
    fi
    say "  [$mode] $chr try $try: no JSON, retry"
  done
  say "  [$mode] $chr FAILED"; islo rm "$box" >>"$LOG" 2>&1 || true; return 1
}

cmd_run(){
  say "=== genome-wide reference-broadcast fan-out · ${#CHROMS[@]} chromosomes · harness=Claude Code ==="
  command -v crabbox >/dev/null && say "crabbox present; coordinator: $(crabbox whoami 2>&1 | head -1)"

  # 1 · WARM BASE (download all 24 chromosomes + index, once)
  say "=== 1/5 warm base: toolchain + ${#CHROMS[@]} GRCh38 chromosomes + index ==="
  islo rm gx-wg-warm >>"$LOG" 2>&1 || true
  t=$(now); inject gx-wg-warm
  islo use gx-wg-warm --cpu 2 --memory 4096 --disk 25 -- bash -lc "\$HOME/gx/warmup.sh ${CHROMS[*]}" >>"$LOG" 2>&1
  WARM=$(python3 -c "print(round($(now)-$t,2))"); say "warm base built in ${WARM}s"

  # 2 · SNAPSHOT (the broadcast)
  say "=== 2/5 snapshot warm base -> $SNAP ==="
  t=$(now); islo snapshot save gx-wg-warm --name "$SNAP" >>"$LOG" 2>&1
  SNAPS=$(python3 -c "print(round($(now)-$t,2))")
  SNAPSZ=$(islo snapshot ls 2>/dev/null | grep -F "$SNAP" | awk '{print $2" "$3}')
  say "snapshot saved in ${SNAPS}s (size ${SNAPSZ:-n/a})"

  # 3 · COLD BASELINE (one large shard from scratch, for honest per-shard cold cost)
  say "=== 3/5 cold baseline: $COLD_REF from scratch ==="
  t=$(now); run_shard gx-wg-cold "$COLD_REF" cold; COLD=$(python3 -c "print(round($(now)-$t,2))")
  say "cold baseline ($COLD_REF) ${COLD}s"

  # 4 · WARM FAN-OUT (fork per chromosome, in waves of MAXP)
  say "=== 4/5 warm fan-out: fork ${#CHROMS[@]} shards from snapshot (MAXP=$MAXP) ==="
  t_map=$(now); i=0
  while [ $i -lt ${#CHROMS[@]} ]; do
    pids=()
    for j in $(seq 0 $((MAXP-1))); do
      idx=$((i+j)); [ $idx -ge ${#CHROMS[@]} ] && break
      run_shard "gx-wg-${CHROMS[$idx]}" "${CHROMS[$idx]}" warm & pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p"; done
    i=$((i+MAXP))
  done
  MAP=$(python3 -c "print(round($(now)-$t_map,2))"); say "warm fan-out wall-clock ${MAP}s"

  # 5 · REDUCE
  say "=== 5/5 reduce -> data/receipts.json (genome-wide) ==="
  python3 scripts/reduce_wg.py "$DATA" "$SNAP" "$SNAPSZ" "$WARM" "$SNAPS" "$COLD" "$COLD_REF" "$MAP" "$MAXP" "${CHROMS[@]}" | tee -a "$LOG"
  say "=== DONE (snapshot $SNAP retained) ==="
}

case "${1:-run}" in
  run) cmd_run ;;
  *) echo "usage: crabbox.sh run"; exit 1 ;;
esac
