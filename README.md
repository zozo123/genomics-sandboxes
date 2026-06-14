# Warm one box. Fork the genome.

**Reference broadcast by VM snapshot — a real, reproducible genomics demo on [islo.dev](https://islo.dev).**

🔗 **Live:** https://zozo123.github.io/genomics-sandboxes/

![Warm one box. Fork the genome.](./og.png)

---

Sequencing collapsed to ~$100 a genome ([Ultima UG 100](https://www.statnews.com/2024/01/30/ultima-genomics-dna-sequencing-100-dollars/), 2024; ~$80 in 2025).
Reading DNA isn't the cost anymore — computing on it is, and the expensive part is the
*read-only* state every pipeline shares: the reference FASTA (~3 GB) and its indices (BWA ~5 GB,
STAR 27–30 GB, plus GATK bundles) — 8–40 GB of immutable bytes. Best-practice scatter-gather
workflows ([nf-core](https://pubmed.ncbi.nlm.nih.gov/32055031/), GATK Best Practices) fan a run
across 50–1000 shards and re-localize that identical reference to every one of them.

**The one idea: a VM snapshot is the reference broadcast.** Warm one box (open the reference,
load the indices, page them resident), snapshot the initialized address space, and fork it
copy-on-write per shard — the same mechanism Firecracker and Lambda SnapStart use. The (N+1)th
shard costs a page-table setup, not another multi-GB read, and every fork is byte-identical
because they map the same physical pages.

I validated the fan-out against a **positive control**, not a discovery: per-chromosome
CpG-island density is known to track gene density, so a correct map-reduce *must* return chr19
(most gene-dense) on top and chrY (a gene desert) at the bottom. It does. Recovering a known
gradient from an independently written kernel is evidence the sharding, compute, and reduce are
all wired correctly — exactly the check you want when the pipeline is model-written.

## What it computes

Per human chromosome (GRCh38), in 1 Mb bins:

- **GC %** and the GC landscape (isochores)
- **CpG observed/expected** ratio
- **CpG-island candidates** — Gardiner-Garden & Frommer (1987): 200 bp window, GC > 50 %, obs/exp > 0.6
- assembly-gap (N) fraction

CpG islands aren't trivia: methylation at CpG sites is the switch behind epigenetic age clocks,
cancer screens (promoter hypermethylation), and cell identity — the same signal consumer
epigenetic tests are built on.

## The pattern

```
warm one box ──▶ snapshot it ──▶ fork per chromosome ──▶ reduce
 (toolchain +     (the read-only   (MAP: each shard       (merge per-shard
  reference +      base, broadcast   restores warm,         JSON → genome-wide
  index, once)     to every worker)  just computes)         landscape, delete boxes)
```

Four verbs of the islo CLI:

```bash
# 1 · warm base: toolchain + GRCh38 chromosomes + index (paid once)
islo use gx-warm -- bash -lc './warmup.sh chr19 chr20 chr21 chr22 chrY'

# 2 · broadcast: freeze the warm box to a snapshot
islo snapshot save gx-warm --name genomics-warm

# 3 · MAP: fork one warm box per chromosome, in parallel
for chr in chr19 chr20 chr21 chr22 chrY; do
  islo use gx-map-$chr --snapshot genomics-warm -- python3 compute.py $chr &
done; wait

# 4 · REDUCE: merge per-shard JSON, then delete the boxes
```

Driven end-to-end by [`scripts/run_demo.sh`](./scripts/run_demo.sh).

## Real receipts (this run)

| | |
|---|---|
| Chromosomes (shards) | 5 — chr19, chr20, chr21, chr22, chrY |
| Bases scanned | 277,817,649 (~278 Mb) |
| CpG sites | 3,201,954 |
| CpG-island candidates | 37,374 |
| Warm base built (once) | 24.1 s |
| Snapshot | 127 MB, saved in 3.9 s |
| Cold fan-out (each worker re-stages) | 34.2 s wall-clock |
| Warm snapshot-fork fan-out | 14.8 s wall-clock |
| First-run / re-run speedup | 2.3× / 7.4× |
| Redundant reference downloads avoided | ~288 MB |

Raw numbers behind every figure: [`data/receipts.json`](./data/receipts.json) (the site fetches
it live — nothing is hardcoded). Per-shard outputs are in `data/warm_*.json` / `data/cold_*.json`.

### The free correctness check

The fan-out recovers a known biological fact: **CpG-island density tracks gene density.**

| chromosome | CpG-island candidates | islands / Mb |
|---|---|---|
| chr19 | 16,809 | **287.6** (densest in the genome) |
| chr22 | 6,814 | 174.0 |
| chr20 | 7,162 | 112.0 |
| chr21 | 4,484 | 111.9 |
| chrY  | 2,105 | **79.7** (a gene desert) |

If the map-reduce were wrong, the biology would be wrong. It isn't.

## Reproduce

```bash
# islo CLI + login required (https://islo.dev)
bash scripts/run_demo.sh           # warm → snapshot → cold/warm fan-out → reduce → data/
python3 -m http.server 8799        # then open http://localhost:8799
```

| File | Purpose |
|------|---------|
| `index.html` / `styles.css` / `script.js` | the interactive explainer (vanilla, no build, fetches `data/*.json`) |
| `scripts/compute.py` | the MAP kernel — one chromosome → JSON (numpy, memory-frugal) |
| `scripts/warmup.sh` | the warm-up that gets snapshotted (toolchain + reference + index) |
| `scripts/run_demo.sh` | host orchestrator: warm → snapshot → cold/warm fan-out → reduce |
| `data/` | measured receipts + reduced landscape + raw per-shard outputs |
| `og-card.html` | self-contained 1200×630 social card (rendered to `og.png`) |

## Caveats (read these)

**Not medical advice.** This computes sequence statistics on the *public* human reference. It is
not a clinical test, not a diagnosis, and says nothing about any individual. CpG-island counts
are candidate calls (Gardiner-Garden & Frommer 1987; Takai & Jones 2002 tightened the rule), not
curated annotations like ENCODE's cCRE Registry (Moore et al., *Nature* 2020).

The snapshot/fork-for-startup mechanism is **standard systems infrastructure** (CRIU, Firecracker
COW restore, AWS Lambda SnapStart) — pointed here at a heavy, read-only genomics reference
fan-out. Nothing about the mechanism is claimed as new. At this toy scale the first-run speedup
is modest; the real payoff is **amortization** (re-runs pay only the map wall-clock) and
**byte-identical reproducibility** across shards. Scale to a 3 GB reference + BWA indices across a
cohort and the snapshot becomes the only sane way to do it.

## Related

- [The Sandbox Shift](https://zozo123.github.io/sandboxes-why-how-when/)
- [The Living Layer](https://zozo123.github.io/the-living-layer/)
- [Databases in the AI Era](https://zozo123.github.io/databases-in-the-ai-era/)

Ideas owed to Dean & Ghemawat (MapReduce, 2004) and the ENCODE Consortium. Reference: GRCh38
(UCSC goldenPath). By [Yossi Eliaz](https://www.linkedin.com/in/yossi-eliaz), 2026.
