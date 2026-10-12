# Final comparison preregistration

Status: **protocol declared; final adapters, toolchain and independent holdouts are not yet frozen**.
The two tiny fixtures in `indexstore-cli-benchmark.md` are validation data. Repairing an adapter
against them does not turn a later rerun into independent evidence.

## Claim and primary endpoint

The proposed claim is restricted to installed tools answering source-verified compiler-observed
direct/transitive caller batches on the frozen projects. It does not claim universal superiority,
a better compiler index,
or superiority over an IndexStoreDB API implementation or a persistent custom query service.

This call-only endpoint is separate from framework-aware `affected`/`impact` test selection.
XCTest lifecycle/runtime contracts require their own oracle and baseline contract. Conservative
test-class selection must not be counted as a false positive against an oracle of compiler calls.
Header/source freshness warnings remain separate correctness gates.

The primary metric is **composed source-to-result cost** for one independent paired session:

```
shared initial project build/index cost
+ arm-specific discovery/setup and ten predetermined initial queries
+ shared semantic-edit rebuild cost
+ arm-specific refresh and ten predetermined post-edit queries
```

Each arm is charged the full, identical measured shared build costs. Both read the exact same
index bytes. This is a composed cost, not an uninterrupted stopwatch duration. Engine-only totals
and already-built-index results are reported alongside it. A compiler-dominated failure to meet the
20% primary gate remains a failed primary result. An already-built workflow requires its own
preregistered scoped claim; it cannot replace the primary endpoint after outcomes are observed. Tool acquisition and release compilation
are measured and reported separately; an installed-tool claim cannot be restated as a full
installation/setup advantage without including those costs.

## Frozen experiment rules

- Twenty independent paired sessions per final workload; nested queries are not independent samples.
- Predetermined ten-query batches and semantic edits are committed before either arm runs on the
  final holdouts. Workload counts, thresholds and random seeds cannot be changed to obtain a win.
- Balanced randomized arm order at each indexed state; private per-session/per-arm reader caches.
  Shared OS filesystem caches are reported as uncontrolled rather than called filesystem-cold.
- Assemble the baseline graph once per immutable indexed state and reuse it, including its reverse
  adjacency, across all ten queries. Compare equivalent loaded/session state. If Cartograph uses a
  persistent cache, include an equivalent cached/session assembler regime with measured cache
  validation and rebuild costs. The literal fresh CLI/assembly regime is not the best possible baseline.
- Check the common index-content fingerprint before and after each arm, outside query timers.
  Preserve each shared compiler-build sample with its pair.
- Primary success requires at least a 20% paired-median composed-cost improvement and a paired
  95% bootstrap confidence interval for the Cartograph/baseline ratio entirely below 1.
  Resample whole session pairs, including their shared build costs, rather than individual queries.
- Every source-oracle, negative control, refresh, rename/delete, restoration and stale-input gate
  must pass with zero false positives and false negatives. Undefined empty-set precision/recall
  remain undefined; exact-set agreement is still required.
- Report first-process, repeated-process, refresh and startup costs separately. Report process-tree
  peak RSS using an explicitly validated sampler. `wait4` maximum RSS alone is not aggregate
  simultaneous process-tree memory and cannot establish memory dominance.
- Any memory or startup regression greater than 10% is an explicit tradeoff, not dominance.
  Preserve all failed rounds, versions, raw commands, output, samples and uncertainty estimates.
  Do not rerun or reseed a frozen experiment merely to obtain a favorable result.

## Separately declared existing-built endpoint

The secondary regime begins with an already-built immutable compiler index and fresh private reader
state. Each arm answers one predetermined ten-query caller batch: one actual CLI dump/assembly with
shared reverse adjacency for the baseline, and one native Cartograph batch. Neither arm receives a
warm persistent graph. Discovery, parsing and batch traversal are included in each arm's cost.

Use twenty independent paired sessions, balanced randomized order, the same exact accuracy and
freshness gates, at least 20% paired-median improvement, and a paired 95% bootstrap ratio interval
entirely below 1. Preserve project/tool setup costs and memory/startup regressions beside the result.
This endpoint concerns the existing-built fresh-reader batch only, not native/MCP session superiority.

**Overall success is primary-only.** Always report both endpoints, including a failed or inconclusive
primary when the secondary succeeds. Do not select whichever wins or relabel the secondary as the
composed source-to-result endpoint after observing outcomes.

## Final independent coverage

After the adapters are frozen, reserve fresh source-authored outcomes for both:

1. A SwiftPM multi-target project covering shared compilation contexts, cross-module callers,
   protocol/extension behavior, overload negatives, source renaming/deletion and stale records.
2. A small Swift/Objective-C iOS fixture covering headers, cross-language calls, source-only stale
   warnings, a rebuild and edit restoration on the same compiler/toolchain/index pipeline.

Missing iOS execution or unsupported contexts remain explicit unresolved coverage. They cannot be
silently removed and then presented as proof for mixed iOS projects. Native unsupported baseline
operations are distinguished from comparable operations supplied by the external assembler; they
are never converted into fabricated zero-recall scores.

The final source revision, adapter hashes, oracle hashes, toolchain/SDK versions, exact query list,
edit sequence, randomization seed and bootstrap implementation must be committed before execution.
Record nonidentifying CPU model, core counts, RAM and load/concurrency policy. The moving
`macos-latest`/newest-Xcode pilot is diagnostic; the final runner/toolchain regime must be pinned.
Any repair after observing final outcomes promotes that fixture to validation data and requires a
new independent final holdout. A failed or inconclusive gate is a result, not permission to weaken it.
