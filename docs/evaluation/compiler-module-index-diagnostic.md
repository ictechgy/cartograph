# Compiler module-index refresh diagnostic

This is a compiler-input investigation, not an engine benchmark or superiority result.
The mixed iOS pilot's source oracle remains unchanged. Run 38205053093 retained a
Swift-reachable BridgeKit PCM index unit whose contents stayed identical after a
header edit and rename, while current C/ObjC++ units referenced newer header records.
That input contradiction is not credited as a win for either reader.

`Scripts/diagnose-indexstore-module-refresh.py` isolates that behavior with an authored
C inline function imported by Swift. It reuses the verified pinned `index-dump`
binary and library from the pilot setup. The five predetermined stages are initial,
header edit, header rename, PCM-cache refresh, and fresh-index rebuild. Refresh moves
only the diagnostic's private tree aside and preserves its bytes; it never clears a
global cache. The existing mixed lifecycle is not changed by this diagnostic.

For each stage it retains:

- Exact compiler, LLVM disassembler, library and CLI hashes, commands and measured costs.
- The source-authored expected target, source hashes, actual object relocations and LLVM IR.
- PCM hashes before/after IR, an unchanged-index guard around IR and read-only CLI calls,
  and the current source unit's exact named dependency on the Bridge PCM unit.
- Complete unit/record dumps, index-file hashes, and exact expected/observed header call edges.
- Every intermediate failure; intermediate stale index facts are observations, never dropped.

Initial and fresh-index controls must match the authored call. Actual object and IR
calls must match in every stage. The diagnostic does not require a particular compiler
to exhibit the stale-unit problem: an implementation that updates every stage is valid.
Named PCM dependency ambiguity or unsupported disassembly fails explicitly.

## Local Linux validation

Official Swift 6.4 and pinned IndexStoreDB revision
`64aa0b26913249c4e7c21d351a215fba02702003` produced these observations:

- Initial index/object/IR calls agree on `base`.
- After edit and rename, PCM bytes and object/IR calls change to `alternate`, but the module
  index unit still names the original header and its old call.
- Moving the private PCM cache aside and rebuilding does not update that index unit.
- Moving the old index aside and rebuilding into an empty index at the same path, while
  keeping the PCM cache, updates the unit to the renamed header and correct call.

The object relocation and pre-IR PCM controls distinguish fresh compiled code from
stale indexed module facts in this Linux reproduction. They alone do not prove the Apple compiler has the same cause. The separately
retained Apple execution below supplies that bounded native confirmation. SDK/disassembler discovery in the workflow
is outside the recorded diagnostic commands. No timing dominance or complete setup-cost
claim is made from this diagnostic.

Three normalized local rounds are retained in
[`module-refresh-evidence/2026-10-12`](module-refresh-evidence/2026-10-12/bundles.json):

1. The initial harness failed because resolving the `swiftc` symlink changed its invocation
   name to `swift-driver`. A regression now preserves the driver alias.
2. All five stages completed and exposed the stale-index/fresh-code distinction.
3. After adding recorded harness/adapter hashes and per-stage executable hash checks, all
   five stages completed again with the same outcome. This is a validation repair rerun,
   not a result-selected performance repetition.

The third run records harness SHA256
`f8a652fff8178edd1036bc21d191aa29c20fbee6ff07af634dd72bcb4b52efb3`.
All 305 normalized text files and three manifests are hash-checked without extraction:

```sh
python3 Scripts/verify-module-refresh-diagnostic.py
```

The archives omit object/PCM/index binaries and private workspace paths. Their manifests
retain original hashes separately from normalized hashes. Raw originals and earlier
exploratory runs remain in the private task workspace.

A later common-build refresh policy must be reviewed separately, applied before both
arms see the same index bytes, and charge its actual full rebuild/refresh cost to each
composed source-to-result endpoint. This diagnostic does not silently substitute a
fresh-build regime for the failed incremental round.

## Actual Apple validation

Run [38209165923](https://github.com/ictechgy/cartograph/actions/runs/38209165923),
head `d6bab511fa23baba15a2e3128947da9e5a84472f`, executed the identical harness with
macOS SDK 26.5 / Apple Clang 2100.1.1.101. All five stages completed. Object/IR calls
match the source in every stage, and PCM contents change after edit/rename. The module
index unit stays byte-identical across initial/edit/rename/PCM-cache-refresh; only the
fresh-index rebuild updates its header identity and call target. The refreshed PCM
bytes remain identical into that final stage. Every stage retains source/index/PCM
hashes and guards proving the read-only diagnostics did not mutate those inputs.

The normalized archive is included as round 13 in
[`evidence/2026-10-12/bundles.json`](evidence/2026-10-12/bundles.json), with all exact
command, output and cost records under `synthetic/runs/module-refresh-diagnostic/`.
Its complete artifact has 3,588 normalized files, 6,675,105 compressed bytes and
35,072,236 expanded bytes. The original mixed iOS lifecycle still has all 13 failed
observations; that cohort has not yet adopted or validated a fresh-generation policy.
Neither the macOS diagnostic nor its initial/final index matches is a Cartograph
accuracy or performance win. The original incremental failures are not relabeled.
