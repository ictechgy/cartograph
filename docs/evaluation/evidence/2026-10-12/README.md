# Retained pilot rounds: 2026-10-12

These are validation observations, **not a final superiority result**. The source-authored oracle was
unchanged through all eleven rounds. `pilot-rounds.json` retains failed setup/adapter rounds and the
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

6. Run 38198751763 failed before native execution: one wrapper test compared a resolved private
   snapshot path against an unresolved macOS temporary-directory alias. A symlink regression reproduces
   the issue on Linux; the repair resolves both sides while preserving all snapshot-content assertions.
   Its bundle retains the complete failing contract phase and the original full job-log hash.

7. Run 38199069229 passed the wrapper suite, then failed a later adapter test comparing a canonical
   header dependency against an unresolved expected path. A project-symlink regression reproduces it.
   The entire offline comparison, adapter and privacy suite was then exercised under a deliberately
   symlinked temporary root. Only filesystem identity expectations changed; lexical path contracts remain.

8. Run 38199381784 passed offline contracts and the synthetic/public driver stages, then the mixed
   native driver exited 2. Its detailed reason remains unavailable: normalization rejected a literal
   Clang help option (fingerprint `4481f48fee5de938`), and the previous all-or-nothing upload gate
   withheld every bundle. The retained CI phase records that loss explicitly; native outputs, samples
   and costs cannot be reconstructed. A separately labeled local official-Clang help reproduction
   matches that exact fingerprint. Only ANSI color escapes were removed from the selected CI phase;
   the original phase/job hashes and transformation count are retained. This is not complete run evidence.

9. Run 38201210141 passed the synthetic/public validation stages and completed all 13 iOS validation
   states (including unbuilt and expected-failure states), but the observation wrapper exited 1. The mixed-ios normalizer blocked publication under
   `unmapped-absolute-path`; the native failure reason and detailed graph/query/freshness grades remain
   unavailable. This time the three independently safe bundles survived: synthetic (1,081 files),
   argument-parser (606) and mixed-setup (6), totaling 1,693 normalized files. Their setup/sample costs
   and the mixed wrapper's measured wall/CPU time and OS-reported wait4 peak-RSS record survive; mixed
   per-state and per-arm costs/samples do not. The root `bundle-status.json` retains hash-only inventory
   for 1,448 blocked mixed-ios text candidates, not their payloads. Its exact path, bytes and SHA256 are
   separately reviewed in `bundles.json`; it is not counted as a normalized observation. Neither the
   publication status nor the inventory establishes native correctness, graph errors or superiority.

10. Run 38203029381 preserved all four normalized bundles and completed all 13 validation states.
   Seven successful-build states stopped before graph/query scoring: the adapter misread Apple CLI
   module dependencies whose unit name was omitted. Six stale states did execute Cartograph queries
   with exit 0, but their limitations did not identify the relevant edited/deleted header or moved/deleted
   Swift path. All six state-specific freshness gates failed. An ignored `retain_public` fixture setting
   warning is a separate configuration diagnostic, never freshness evidence. The exact original outputs,
   configuration, every failed observation and setup/build/observation costs remain in this archive.
   No graph accuracy score or superiority claim is inferred from the adapter failure.

11. Run 38205053093 executed the repaired Apple nameless-module association and retained all 13
   state/result pairs. The initial actual CLI assembly matches all 23 authored edges; native Cartograph
   has 19, omitting the two project header-inline definitions and their four edges, with no extra edges.
   All six relevant-path freshness checks still fail. The edited-header rebuild carries both fresh C
   header records and a stale Swift-reachable BridgeKit PCM index unit; the renamed-header rebuild
   refuses that same unit's deleted old header dependency. Its unit dump is byte-identical in initial,
   edited and renamed states. This is retained compiler-input provenance failure, not an engine win;
   text evidence cannot distinguish stale PCM reuse from missing re-indexing. No still-reachable record
   was discarded and no source expectation changed. Every setup, build, observation and failure remains.

Round four's discovery plus first-query workflow was 1.236 seconds for native Cartograph and
5.654 seconds for CLI assembly. Repeated medians (four pairs) were 0.446 seconds for a fresh native CLI
and 0.125 seconds for a persisted baseline graph/BFS. These are different state regimes; the extra
default diagnostic also warmed native state. Release compilation was 677.624 seconds for Cartograph
and 29.984 seconds for `index-dump`, with the remaining setup costs separately retained. None of these
pilot observations establish the preregistered twenty-session composed-cost endpoint or memory dominance.

The archives contain only already-normalized text, their manifests and the reviewed publication status.
They contain no raw compiler indexes, objects, executables, toolchains, global caches or environment dumps.
Retained raw originals remain
private; each manifest distinguishes original hashes from normalized public hashes. Seven archives retain
the exact bytes of their public Actions artifacts. The three test-phase archives and round eight's partial
driver-phase archive were normalized separately after their failures. Rounds nine through eleven preserve all original
ZIP bytes, including the publication-status inventory. Archives are committed to avoid losing evidence
when Actions retention expires.

All bundle hashes, file lists, UTF-8 contents, normalized file hashes and explicitly inventoried
auxiliary status bytes/hashes are checked by:

```sh
python3 Scripts/verify-indexstore-pilot-evidence.py
```

Do not extract unverified archives into a source checkout. The verification script reads bounded ZIP
members directly without extracting files or executing content.
