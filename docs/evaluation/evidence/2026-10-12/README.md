# Retained pilot rounds: 2026-10-12

These are validation observations, **not a final superiority result**. The source-authored oracle was
unchanged through all five rounds. `pilot-rounds.json` retains failed setup/adapter rounds and the
contradictory performance regimes. `bundles.json` records exact archive hashes and bounded sizes.

1. Run 38190877188 failed an offline adapter regression: macOS `/var` and `/private/var` aliases were
   normalized asymmetrically. No native benchmark executed. Its bundle contains the complete failing
   comparison-contract test phase, the source job link and the full private job-log hash; unrelated
   checkout/cleanup logs are outside that explicitly identified test phase.
2. Run 38191268489 built both actual release executables but failed fixture compilation because direct
   `swiftc` lacked an explicit macOS SDK. The measured setup costs and failure output remain present.
3. Run 38192130782 passed synthetic accuracy/freshness, but the native default graph retained 11/13
   audited public-project edges versus 13/13 in the actual CLI assembly. Both missing edges were recursive
   self-calls deliberately filtered by the default projection. Caller sets at depths 1/3/5 matched.
4. Run 38194971111 used the explicit complete symbol-call projection. Both arms matched all 13 edges,
   with zero false positives/negatives, and the 1/4/10 caller sets. The separately retained default graph
   still reports 11/13; no oracle update erased that earlier observation.
5. Run 38195985366 repeated mandatory CI after reconciling squash-merged main with byte-identical
   source. Both complete-projection arms again matched all edges and callers. This was a merge-gate
   run, not a result-selected retry. Discovery plus first query was 0.810/4.065 seconds (native/baseline),
   while repeated workflow medians were 0.327/0.079 seconds. Release builds were 458.281/19.377 seconds.
   Every sample remains retained; the same state-regime and setup-cost caveats apply.

Round four's discovery plus first-query workflow was 1.236 seconds for native Cartograph and
5.654 seconds for CLI assembly. Repeated medians (four pairs) were 0.446 seconds for a fresh native CLI
and 0.125 seconds for a persisted baseline graph/BFS. These are different state regimes; the extra
default diagnostic also warmed native state. Release compilation was 677.624 seconds for Cartograph
and 29.984 seconds for `index-dump`, with the remaining setup costs separately retained. None of these
pilot observations establish the preregistered twenty-session composed-cost endpoint or memory dominance.

The archives contain only already-normalized text and their manifests. They contain no raw compiler
indexes, objects, executables, toolchains, global caches or environment dumps. Raw originals remain
private; each manifest distinguishes original hashes from normalized public hashes. The four native
round archives retain the exact bytes of their public Actions artifacts. The first test-phase archive
was normalized separately after its failure. Archives are committed to avoid losing evidence when
Actions retention expires.

All bundle hashes, file lists, UTF-8 contents and normalized file hashes are checked by:

```sh
python3 Scripts/verify-indexstore-pilot-evidence.py
```

Do not extract unverified archives into a source checkout. The verification script reads bounded ZIP
members directly without extracting files or executing content.
