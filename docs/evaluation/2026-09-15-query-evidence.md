# Query reference evidence and detailed local-function diagnostics

This change implements the first two follow-up priorities: inspectable reference
sites and actionable explanations for unrefined local functions. The additive
[query contract](../QUERY-EVIDENCE.md) preserves existing fields, graph facts,
retention behavior, and exit codes.

## Concrete behavior

For Kingfisher's `isTaskCancelled`, `query` still identifies the local
`failCurrentSource(_:retryContext:with:)` declaration at line 363. Its new
`referenceEvidence` also identifies **the actual use at line 365, UTF-8 column 26**.
The `call` and `reference` relationships are both preserved and marked
`compilerAndSyntax`: the index supplied the target/occurrence and source analysis
refined its owner. Ordinary indexed callers carry `compiler`; syntax-only local
entry edges carry `syntax`. Inferred correlations and unknown legacy provenance
remain explicitly distinguished.

For transitive neighbors, each item records the actual `sourceUSR`, `targetUSR`,
and intermediate `viaUSR`. The declaration location is never reused as a missing
callsite. Duplicate index records are folded, all minimum-depth vias remain, and
independent evidence limits expose omitted counts.

The five previously aggregate-only Kingfisher local-function limitations are now
explained individually:

| Local function | Source | Reason |
|---|---|---|
| `safeResume(with:)` | `General/KingfisherManager.swift:1354` | `localType` |
| `createEffectBuffer(_:)` | `Image/ImageDrawing.swift:335` | `conditionalCompilation` |
| `decode(_:)` | `Image/ImageProgressive.swift:156` | `unknownAttributes` |
| `processing(_:)` | `Image/ImageProgressive.swift:277` | `unknownAttributes` |
| `checkRequestAndDone(r:)` | `Networking/ImageDownloader.swift:394` | `unknownAttributes` |

Paths in this table are relative to Kingfisher's `Sources/`. Each item also has an
owner and a suggested inspection/rebuild action. These explain why refinement was
skipped; they are not instructions to delete or rewrite the functions. The same
details appear in `found`, `ambiguous`, and `notFound` query responses.

## Bounds and compatibility

- At most 20 evidence records per neighbor and 200 per query result. Omitted
  evidence is counted separately from omitted neighbors.
- At most 50 local-function diagnostic items, with full total/omitted counts.
  Configured path filters apply to the details.
- Missing optional evidence means not supplied. Unknown or missing locations do
  not become compiler-confirmed callsites.
- Reference provenance and local diagnostics survive snapshot encoding and path
  rebasing. Old snapshots remain readable with unknown provenance.
- The evidence index is prepared once per query session, restricted to visible
  graph relationships. Query-time work does not copy every occurrence when only
  a bounded prefix can be returned.
- The generated Cartograph skill explains provenance, intermediate hops, and
  omission counts. Companion repositories received local compatibility notices;
  their runtime implementations and the bridge exchange schema were not changed.

## Verification

The pre-change binary fails the new evidence and detailed-diagnostic assertions.
Focused regressions cover direct and transitive directions, multiple shortest
paths, duplicates, missing/invalid locations, unknown provenance, zero/global
budgets, legacy decoding, snapshot sorting/rebasing, filtered diagnostics, and
response-status parity. The real compiler corpus checks actual local reference
origins and a named unentered local in a `notFound` response.

The same pinned Alamofire, Kingfisher, and Swift Argument Parser inputs are used
for before/after release comparisons with both execution orders. Query outputs
are stable within each arm and agree between CLI and MCP. All six frozen tasks
retain their **14/14 exact expected consumers**. Full symbol graph documents are
identical before and after, and unused diagnostics remain **21 / 8 / 40**.

The new evidence covers **16/16 frozen reference witness lines**. Every returned
record was checked against an actual graph edge, the correct direction/intermediate,
and a valid position in the pinned source, with all evidence limits respected.
Removing only the new optional fields reproduces the prior query documents exactly.

| Final check | Result |
|---|---|
| Full test suite | **1,291 tests / 149 suites passed**. |
| Coverage | **92.94%** with actual CLI integration (27,555/29,648 lines); unit-only 87.03% (25,804/29,648); threshold 90%. |
| CLI contract and real compiler corpus | Passed, including reference origins and detailed `notFound` diagnostics. |
| Self-analysis | Dead code, module cycles, **type cycles**, and layer rules all passed with no findings. |
| Final artifact identity | Current source and release binary hashes match the measured and verified artifacts. |

The type-cycle gate caught a result type calling back into its enclosing binder.
Reason selection now belongs to the Core reason value type, removing that reverse
dependency while preserving the diagnostic decisions. All final gates were rerun
after this correction.

The measurements, representative responses, and final required-check evidence
are in [the evidence directory](2026-09-15-query-evidence/verification.json).
These checks establish data correctness and compatibility; they do not establish
an improvement in agent editing productivity. Measurements were recorded from the
working implementation on `fix/analysis-query-reliability` before release preparation.
