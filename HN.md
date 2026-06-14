# Hacker News submission

## Title (pick one)

1. **Show HN: Map-reducing the human genome on disposable sandboxes**
2. Show HN: A VM snapshot is the MapReduce broadcast (genomics demo)
3. Show HN: Bring Your Own Genome – analyze DNA on computers that self-destruct
4. Show HN: I forked a warm reference-genome sandbox per chromosome

→ Recommend **#1** as the submission title (concrete, technical, no hype).
URL: https://zozo123.github.io/genomics-sandboxes/

## First comment (author)

A decade ago, scanning the methylation landscape of a few chromosomes meant a wet lab, a
cluster, and a bioinformatics team. I wanted to see how far that's collapsed, so I ran a real
one end-to-end from a laptop — and the interesting part turned out to be an infra idea, not a
genomics one.

Genomics is embarrassingly parallel (scatter by chromosome/interval, gather), but the painful
part is the *broadcast*: every worker needs the multi-GB reference + indices + toolchain before
it can do a second of real work. So instead of re-staging that on each worker, I warm **one**
box, snapshot it, and fork the snapshot per chromosome. A VM snapshot is just the most efficient
possible broadcast of a read-only base — same trick as Firecracker snapshots / Lambda SnapStart /
CRIU, pointed at a genome.

Real receipts from the run on islo.dev: warm base built once in 24s → 127 MB snapshot saved in
3.9s → five chromosome forks start *warm* and finish in ~15s wall-clock, vs 34s if each worker
re-stages the reference itself. The site fetches the actual `receipts.json`; nothing's hardcoded.

The part I didn't expect to like: it's self-checking. The fan-out recovers a known fact —
CpG-island density tracks gene density, so chr19 lights up (287 islands/Mb) and chrY is a desert
(80/Mb). If the plumbing were wrong, the biology would be wrong.

Honest caveats up front: island calls are candidates (Gardiner-Garden & Frommer; Takai & Jones
tightened the rule), it's the public reference not anyone's personal genome, and at this toy
scale the first-run speedup is modest — the real payoff is amortization (re-runs pay only the map
wall-clock) and byte-identical reproducibility across shards. Swap in a 3 GB reference + BWA
indices across a cohort and the snapshot stops being an optimization.

There's also a privacy angle I find compelling given the 23andMe collapse: a sandbox is a
computer that dies on purpose. You can analyze a genome on a box you control and then destroy,
instead of depositing it in a third party's permanent, sellable database.

Code, kernel, and raw receipts: https://github.com/zozo123/genomics-sandboxes — happy to answer
questions about the islo run or the CpG math.

## Pre-empting the likely top comment

> "This is just GC content, not real variant calling / methylation."

Right — deliberately. It's a transparent, verifiable proxy that exercises the exact pattern
(scatter→gather) real pipelines use. The contribution isn't the kernel; it's the broadcast
primitive. Swap the kernel for DeepVariant or a methylation caller and the snapshot-fork shape is
identical.
