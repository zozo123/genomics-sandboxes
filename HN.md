# Hacker News submission

## Title (pick one)

1. **Show HN: Warm one box, fork the genome — reference broadcast by VM snapshot**
2. Show HN: A VM snapshot is the reference broadcast (genomics scatter-gather)
3. Show HN: Stop re-staging the reference genome to every shard
4. Show HN: Map-reducing the human genome by forking a warm snapshot per chromosome

→ Recommend **#1 or #2** (concrete, method-forward, no hype).
URL: https://zozo123.github.io/genomics-sandboxes/

## First comment (author)

The reference genome and its indices are 8–40 GB of read-only state that never changes during a
run — a GRCh38 FASTA is ~3 GB, a BWA index adds ~5 GB, a STAR index 27–30 GB — yet GATK
scatter-gather workflows re-localize all of it to every one of hundreds of shards, and re-stage
it again on every spot preemption. The right move is to warm it once, snapshot the initialized
address space, and fork it copy-on-write to each shard: the same SnapStart/Firecracker trick. The
(N+1)th shard costs a page-table setup, not another multi-GB read, and every fork is
byte-identical because they map the same physical pages.

This matters more when the pipeline author is a model: you get disposable isolation for untrusted
code, O(1) broadcast across thousand-way fan-out, and a positive control baked into the warm-up —
here the CpG-island-density gradient (chr19 densest, chrY a desert) that a correct map-reduce must
reproduce. The whole thing was orchestrated by an agent driving four islo verbs; the site fetches
the real `receipts.json`, nothing is hardcoded.

Honest scope: my demo warm-up is a 72 MB toy, so I've shown the mechanism, not the at-scale
economics. Snapshots also only restore on a compatible CPU/kernel.

Code, kernel, and raw receipts: https://github.com/zozo123/genomics-sandboxes

## Pre-empting the likely top comment

> "This is just GC content, not real variant calling / methylation."

Right — deliberately. The CpG-island/gene-density gradient is a *positive control*, not the
product: a known-answer signal that tells me the sharding, per-shard compute, and reduce are
wired correctly. The contribution is the broadcast primitive, not the kernel. Swap in DeepVariant
or a methylation caller and the snapshot-fork shape is identical.
