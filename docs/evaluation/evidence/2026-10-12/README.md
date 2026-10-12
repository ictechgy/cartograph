# Retained pilot rounds: 2026-10-12

These are validation observations, **not a final superiority result**. The source-authored oracle was
unchanged through all twenty-one rounds (thirty-two archives). `pilot-rounds.json` retains failed setup/adapter rounds and the
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

12. Run 38207788767 was mandatory exact-head CI after the evidence-only archival commit.
   It reproduces the original mixed outcomes: 13 completed validation states, all 13 observations
   failed, initial baseline 23/23 versus native 19/23 edges, six freshness failures and the same
   stale indexed-module provenance contradiction. No source oracle or product behavior changed.

13. Run 38209165923 keeps that same failed mixed lifecycle and adds a separate five-stage Apple
   compiler diagnostic under macOS SDK 26.5 / Apple Clang 2100.1.1.101. Object relocations and LLVM
   IR reflect the edited target after header edit/rename. PCM bytes change, but the indexed module
   unit remains byte-identical through a PCM-cache refresh. Rebuilding into an empty task-owned
   IndexStore makes the authored edge current while retaining the same refreshed PCM bytes.
   Initial/fresh-index index controls pass; the three intermediate stale index observations remain.
   All five object/IR targets and pre/post diagnostic guards pass. This establishes the bounded
   macOS compiler-input diagnosis, not mixed iOS correctness or an engine advantage. All original
   mixed failures, diagnostic commands, setup/refresh costs and hash manifests are retained.

14. Run 38212888445 is the first actual mixed-iOS validation of `fresh-shared-v2`, combined with
   the merged dependency-freshness repair. All seven rebuilt states pass the baseline's exact graph
   and ten-query source oracles, including header edit/rename, Swift rename/delete and restoration.
   Each arm reads the same verified input bytes. This removes the earlier shared stale-module-index
   failures under this explicit fresh-generation regime; no record is filtered to fit expectations.
   All six native changed/missing-path freshness checks now pass with completed exit-0 diagnostics.
   The remaining seven native failures are precisely the two missing header-inline declarations
   and their four call edges. Native query grading remains failed where those missing seeds prevent
   a complete answer. The separate header product repair is not included in this run.
   The full common preparation/rebuild cost is charged equally, with setup/hash/preflight costs
   separately retained. SDK content identity is still unproved and the final performance protocol
   remains unrun. All 13 validation states and all failed native results remain in the exact archive.

15. Run38217594404 combines the independently merged header-record admission fix with the same
   shared fresh-generation policy. All seven rebuilt states now pass both engines' exact graph and
   ten-query source oracles, with zero missing/extra edges or unresolved definitions and identical
   shared input bytes. All six native state-specific freshness diagnostics pass, including deleted
   headers/Swift files and renames. Rebuilt restoration graph/query checks also pass. The original
   two missing header definitions/four
   edges are now present without an oracle change. This closes that omission on the validation
   corpus; it is neither a new holdout nor comparative performance proof.
   The separate fixed native synthetic measurement-helper step completed successfully, but its
   evidence normalizer rejected package-contact metadata in the full pip install report. The helper
   artifact was correctly withheld; its detailed samples/results remain unavailable and are not
   reconstructed from later runs. All four compiler-comparison bundles survived unchanged. The
   exact blocker category, artifact and value-hash prefix remain in the ledger. Product coverage
   and strict self-analysis passed; the comparison job remains red for this publication failure.
   Full shared costs remain equal and retained. SDK contents and final20-session endpoints remain open.

16. Run 38220745660 passes all three exact-head CI jobs and repeats all 13 successful mixed states
   without changing the source oracle. It also preserves the first fully published native synthetic
   helper packet after the strict package-provenance repair. Both exact public artifact ZIPs are kept:
   3,625 normalized comparison files and 204 normalized helper files, with independent hash replay.
   The helper runs 44 tests: 42 pass and two explicit Linux-only orphan-adoption controls are skipped.
   All 16 fixed calibration pairs agree on output. Eight RSS runs retain 174 rows / 245 process members;
   each repeated-child run observes all 13 identities. Requested 10 ms sampling actually has median
   intervals 15–31 ms and maxima up to 42 ms, as the unchanged receipts disclose.
   Timing-only observer/no-observer median ratios are 0.972 and 1.051, with both 95% intervals crossing
   parity. Memory-observed ratios are 1.099 and 1.104, showing measurable observer overhead and supporting
   separate matched RSS runs. These synthetic diagnostics are not product timing or superiority proof.
   Native failure-control outcomes remain in the test log; their temporary individual artifacts are
   not present. macOS detached/unobserved ancestry gaps, moving-runner control, actual-engine
   calibration, SDK content identity, a fresh holdout and final 20-session endpoints remain open.
   Full product coverage is 92.81% (40,478/43,614 lines), with 2,008 tests in 203 suites. Earlier failed
   rounds, including round 15's unavailable helper details, are unchanged.

17. Run 38230196392 again passes all 13 mixed validation states against the unchanged oracle.
   Product checks pass 2,008 tests in 203 suites at 92.81% coverage (40,477/43,614 lines); self-analysis
   also passes. The separate new SDK diagnostic fails after five successful probes because Apple
   Swift 6.3.3 reports an additional sdkPath field. Its output also reports /usr/lib/swift outside
   declared SDK/toolchain roots. This is retained as an input-discovery failure, not an engine loss.
   All pre/post generation and completed-probe guards pass. Original child exit1, 11.526 seconds,
   discovery's identical 11.403-second per-arm accounting, and red publication outcome remain visible.
   The safe SDK artifact contains 27 normalized discovery files plus its exact hash-only attempt and
   publication envelopes. No root is accepted. The original three artifacts are byte-preserved.
   Synthetic helper validation retains all 16 pairs and 170 RSS rows/248 process members. Timing-only
   median ratios are 0.998 and 1.007 with both confidence intervals crossing parity; memory-observed
   ratios are 1.275 and 1.070. These remain diagnostic observer costs, not product performance proof.
   Detailed host-path existence/link layout, full SDK contents, actual-arm calibration, fresh holdouts
   and the final performance gates remain pending. Earlier failures are unchanged.

18. Run 38233336308 again passes all 13 mixed validation states and the separate synthetic helper
   diagnostic. Product checks pass 2,008 tests in 203 suites at 92.81% coverage (40,477/43,614 lines).
   The SDK child completes with exit1 after 11.384 seconds, but its detailed discovery bundle is
   blocked by the privacy scanner. The two-file safe SDK envelope retains the original outcome,
   11.415-second supervisor cost and 0.243-second publication cost. The exact blocker hashes identify
   setup/discovery/probes/clang-cxx.stderr and the suffix /include/c++/v1; the preceding raw path,
   actual selector failure, probe count and path existence/link layout remain unavailable.
   A focused compiler-relative parent-path reproduction motivates a separately reviewed explicit
   normalization alias; it does not recover this round's missing detail. No root is accepted.
   Independent comparison/helper artifacts survive unchanged, with all 14 rebuilt graph projections
   and 21 ten-query batches regraded against the existing source oracle. Every synthetic pair and RSS
   sample remains in the helper archive. Earlier failures remain unchanged; no performance proof.

19. Run 38236591686 passes all 13 mixed validation states and the synthetic helper diagnostic.
   Product checks pass 2,008 tests in 203 suites at 92.82% coverage (40,483/43,614 lines).
   SDK discovery completes with exit1; its detailed bundle remains unavailable. Exactly two safe
   envelopes retain the 14.117-second child, 14.149-second supervisor and 0.534-second publication
   costs, with the original failure. The first compiler-relative normalization alias is verified,
   but the strict scanner still blocks a suffix whose exact hash preimage is /v1 in
   setup/discovery/probes/clang-cxx.stderr. This does not identify the preceding raw path or recover
   any actual selector/probe/root-layout detail. A separate synthetic control covers both official
   Darwin libc++ candidate families; it does not reclassify this unavailable native evidence.
   All 3,625 comparison files and 204 helper files remain independently available and hash-verified:
   14 graph projections and 21 ten-query batches exactly regrade against the unchanged oracle;
   16 synthetic pairs, 162 RSS rows and 232 members remain retained with their limits. No SDK root,
   final runtime closure or comparative performance result is accepted.

20. Run 38240360620 passes product/self-analysis, all 13 mixed states and synthetic helper checks.
   Product: 2,008 tests, 203 suites, 92.81% coverage (40,477/43,614 lines). All 14 graph projections
   and 21 ten-query batches regrade exactly; helper evidence retains 16 pairs and 171 RSS rows/248 members.
   The two-family normalization repair succeeds: all 36 SDK files and two safe envelopes are available.
   Eight probes exit0 with passed post-guards, then C++ search parsing fails invalid-absolute-path.
   Exact normalized Clang output and original raw hashes remain retained; a synthetic selected-compiler
   parent-alias control reproduces this stage without reconstructing private path prefixes.
   Swift runtimeLibraryPaths directly names /usr/lib/swift, observed as a directory with directory-only
   components and no content read. It remains unresolved; this is not loader closure or root acceptance.
   Selector costs reconcile 4.492 seconds of probes plus 6.865 seconds of setup/guards to 11.358 seconds.
   The wrapper's full 14.696-second diagnostic is assigned identically to both arms; outer child 14.888,
   supervisor14.931 and publication7.249 seconds are separate/nested receipts, not added twice.
   Discovery remains red and unaccepted. Earlier unavailable SDK rounds retain their original status.

21. Run 38244410533 passes product coverage, all 13 mixed states and synthetic helper checks.
   Product: 2,008 tests, 203 suites, 92.81% coverage (40,477/43,614 lines). All 14 graph projections
   and 21 ten-query batches regrade exactly; helper evidence retains 16 pairs and 165 RSS rows/233 members.
   SDK discovery completes with exit 1, but its detailed JSON is blocked by strict normalization.
   Exactly two safe envelopes retain the original exit, costs and failed publication; the actual
   selector outcome, probe count and path layout are unavailable. Verified blocker hash preimages
   identify setup/discovery/results.json and suffix /v1, without recovering the preceding path.
   A complete synthetic parser-result control matches all blocker hashes at the root-relative
   coverage string usr/include/c++/v1. Replacing that diagnostic scalar with validated lossless
   components permits the prospective bundle while preserving original/canonical paths and scanner.
   This local diagnosis does not reconstruct the blocked native result or accept any runtime root.
   The original child wall is 12.716 seconds, supervisor 12.739 seconds and publication 0.592 seconds;
   child time is nested in supervisor time. All failed/available evidence remains in the ledger.

Round four's discovery plus first-query workflow was 1.236 seconds for native Cartograph and
5.654 seconds for CLI assembly. Repeated medians (four pairs) were 0.446 seconds for a fresh native CLI
and 0.125 seconds for a persisted baseline graph/BFS. These are different state regimes; the extra
default diagnostic also warmed native state. Release compilation was 677.624 seconds for Cartograph
and 29.984 seconds for `index-dump`, with the remaining setup costs separately retained. None of these
pilot observations establish the preregistered twenty-session composed-cost endpoint or memory dominance.

The archives contain only already-normalized text, their manifests and the reviewed publication status.
They contain no raw compiler indexes, objects, executables, toolchains, global caches or environment dumps.
Retained raw originals remain
private; each manifest distinguishes original hashes from normalized public hashes. Twenty-eight archives retain
the exact bytes of their public Actions artifacts. The three test-phase archives and round eight's partial
driver-phase archive were normalized separately after their failures. Rounds nine through twenty-one preserve all original
ZIP bytes, including the publication-status inventory. Archives are committed to avoid losing evidence
when Actions retention expires.

All bundle hashes, file lists, UTF-8 contents, normalized file hashes and explicitly inventoried
auxiliary status bytes/hashes are checked by:

```sh
python3 Scripts/verify-indexstore-pilot-evidence.py
```

Do not extract unverified archives into a source checkout. The verification script reads bounded ZIP
members directly without extracting files or executing content.
