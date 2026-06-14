#!/usr/bin/env bash
# MAP fan-out: one islo box per chromosome from the snapshot, in waves of 8.
set -u
export PATH="$HOME/.local/bin:$PATH"
export ISLO_OUTPUT_FORMAT=plain
cd /Users/yossi.eliaz/genomics-sandboxes

SNAP=genomics-wg-1781449331
CHROMS=(chr1 chr2 chr3 chr4 chr5 chr6 chr7 chr8 chr9 chr10 chr11 chr12 chr13 chr14 chr15 chr16 chr17 chr18 chr19 chr20 chr21 chr22 chrX chrY)
WAVE=8

run_shard() {
  local chr="$1"
  local box="gx-wg-${chr}"
  local json="data/wg_warm_${chr}.json"
  local tf="data/wg_warm_${chr}.time"
  local raw="data/_wg_warm_${chr}.out"
  local attempt line
  for attempt in 1 2; do
    local s0 s1
    s0=$(date +%s.%N)
    islo use "$box" --snapshot "$SNAP" --cpu 2 --memory 8192 -- \
      bash -lc "python3 \$HOME/gx/compute.py ${chr}" >"$raw" 2>>"$raw.err"
    s1=$(date +%s.%N)
    line=$(grep -m1 '^{"chrom"' "$raw")
    if [ -n "$line" ]; then
      printf '%s\n' "$line" >"$json"
      awk "BEGIN{printf \"%.2f\", ${s1}-${s0}}" >"$tf"
      islo rm "$box" >/dev/null 2>&1
      echo "OK   ${chr} ($(cat "$tf")s)"
      return 0
    fi
    echo "RETRY ${chr} (attempt ${attempt} produced no JSON)"
    islo rm "$box" >/dev/null 2>&1
  done
  echo "FAIL ${chr}"
  return 1
}

T0=$(date +%s.%N)
i=0
while [ $i -lt ${#CHROMS[@]} ]; do
  pids=()
  for ((j=0; j<WAVE && i<${#CHROMS[@]}; j++, i++)); do
    run_shard "${CHROMS[$i]}" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  echo "--- wave done ---"
done
T1=$(date +%s.%N)
awk "BEGIN{printf \"%.2f\", ${T1}-${T0}}" >data/MAP_SEC
echo "MAP_SEC=$(cat data/MAP_SEC)"
