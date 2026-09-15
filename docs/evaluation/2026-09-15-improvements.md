# Reliability improvements after the external comparison

The implementation addresses the concrete gaps in the
[unchanged-0.13.0 comparison](2026-09-15-comparison.md): one used typealias reported
as unused, nine missed unused-code candidates, two receiver types misidentified
as callers, and repeated Xcode-discovery overhead in warm MCP queries.

On the same three pinned projects, the revised build reports all nine missed
candidates and stops reporting the used alias. All 14 expected nonlocal consumers
remain present; the two extra receiver types disappear. Per-task median warm
query latency falls from **114–119 ms to 42–51 ms** in the counterbalanced runs.
These are scoped correctness and latency results, not a new agent-productivity
or market-advantage claim.

[Machine-readable measurements](2026-09-15-improvements/results.json) preserve
the two run orders, all 720 timed requests, binary/compiler identities, diagnostic
USRs, graph counts, and query fingerprints. Local workspace prefixes are normalized.

## Controls

- Baseline: source archive of `f80936bc34cd9c62dd61959e65acb7ed65422092` (0.13.0),
  rebuilt in release mode with the same Apple Swift 6.4 toolchain as the changed build.
  Both binaries still print 0.13.0; their SHA-256 identities distinguish them.
- Inputs: unchanged pinned Alamofire `bda9ed5`, Kingfisher `ab1c1de`, and Swift
  Argument Parser `93c6888`, with the original compiler index stores. The collector
  checks revisions, tracked changes, untracked analysis inputs, compiler identity,
  and the index-library identity.
- Scope: the original macOS production-source include filters and `--retain-public`.
  Kingfisher still reports 28 of 98 source files without a known index unit.
  Inactive platform branches and external clients are outside the evidence.
- Execution: one before/after pass, then one after/before pass, with no concurrent
  builds or tests during timing. Each arm uses its own MCP process, warms it, and
  measures three sets of ten queries for each of the six frozen tasks per pass.
  Filesystem caches are not flushed. Initialization and cold installation are not timed.
- Validation: within each arm, CLI and MCP query documents agree, all repeated
  results and session identities are stable, and both run orders produce identical
  findings, graph counts, and query fingerprints. Outputs intentionally differ
  between builds; this is not byte-equivalent-output optimization.

Reproduce with `Scripts/benchmark-analysis-improvements.py --before <baseline-release>
--after <changed-release> --evaluation-root <frozen-workspace> --output <new-directory>
--order before-after`, then repeat into a second directory with `--order after-before`.
The frozen workspace is prepared by `Scripts/benchmark-external-projects.py`;
the original manifest and tasks are preserved beside the first comparison.

## What changed and what remains protected

**Compiler relationships.** Only `calledBy` supplies a call owner. `receivedBy`
describes the receiver type, so it no longer creates a type-to-method call edge.
For relationless conformance typealias references, an implicit `baseOf` occurrence
at the exact same file, module, line, and UTF-8 column supplies the owner only when
that owner is unique and is a known nominal/protocol/extension declaration.
The nearest-declaration fallback is not broadened.

The raw compiler evidence is preserved for
[Alamofire calls](2026-09-15-improvements/alamofire-request-raw-index.json),
[Kingfisher calls](2026-09-15-improvements/kingfisher-manager-raw-index.json), and
[the conformance alias](2026-09-15-improvements/kingfisher-kfanimatedimage-raw-index.json).
The alias has an explicit relationless reference at `KFAnimatedImage.swift:85:47`;
the co-located implicit protocol occurrence has `baseOf` to the representer struct.

**Dispatch and reachability.** Broad index `dynamic` roles are refined only when
one exact source identifier binds to one indexed USR, the symbol is not implicit,
and the declaration and its ancestors contain no unresolved attributes. Explicit
`dynamic`, Objective-C exposure, dynamic replacement, unknown attributes/macros,
missing source, legacy facts, and ambiguous binding stay conservative. The syntax
analysis revision invalidates old cached facts.

A direct concrete witness call no longer proves use of its protocol requirement.
Actual requirement calls still activate eligible concrete/default implementations;
requirement refinement, class dispatch, and external contracts remain protected.
Contracts with targets or dispatch relations filtered out of the graph are treated
conservatively using the original snapshot. Unused helpers in SDK extensions are
reported even when the extension itself is not a reportable type.

**Public access.** Protocol requirements and enum cases inherit access, and
explicit-access extensions provide the default access for their members. Ordinary
public nominal members still default to internal. An extension default is not an
access ceiling: an explicitly public member of a private extension remains public.
These distinctions prevent the narrower dispatch policy from exposing library APIs
as new unused findings under `--retain-public`.

**Process waiting.** Xcode path discovery uses process termination notification
instead of `waitUntilExit()` run-loop polling. It still reads the current selection
on each check, drains stdout, and verifies successful exit. No selection-path cache
or index-freshness shortcut is introduced. Tests exercise actual process launch
failure, unsuccessful exit, signal termination, and stdout closing before exit.

## Three-project diagnostic delta

| Project | Before | After | Newly reported | No longer reported |
|---|---:|---:|---:|---:|
| Alamofire | 18 | 21 | 3 | 0 |
| Kingfisher | 8 | 8 | 1 | 1 |
| Swift Argument Parser | 35 | 40 | 5 | 0 |
| Total | 61 | 69 | 9 | 1 |

The nine additions match the source-backed missed candidates from the original
independent [adjudication](2026-09-15/adjudications.json). Each was inspected again
against the pinned source. References inside unreachable helpers, self-recursion,
and tests outside the selected scope do not establish production reachability.
These findings support review, not automatic deletion; coordinated removal and
application behavior were not tested.

| Project and declaration | Source | Source-based assessment |
|---|---|---|
| AF `around(_:)` returning Void | `Source/Core/Protected.swift:46` | Its caller is the uncalled `withState` helper at line 149; live callers use the value-returning overload. |
| AF `OfflineRetrier.init(monitor:maximumWait:isOfflineError:)` | `Source/Features/OfflineRetrier.swift:109` | Internal initializer reached only by the uncalled factory below. |
| AF `offlineRetrier(monitor:maximumWait:)` | `Source/Features/OfflineRetrier.swift:237` | Internal extension factory has no active production caller. |
| KF `DisplayLinkCompatible.timestamp` | `Sources/Utility/DisplayLink.swift:39` | Concrete timestamp access does not call this protocol requirement. |
| AP `ArgumentSetProvider._visibility` requirement | `Sources/ArgumentParser/Parsable Types/ParsableArguments.swift:299` | Concrete wrapper storage and assignments do not use the requirement. |
| AP `ArgumentSetProvider._visibility` default | `Sources/ArgumentParser/Parsable Types/ParsableArguments.swift:303` | Default belongs to the unused requirement; concrete types supply their own values. |
| AP `checkAsyncHierarchy(_:root:)` | `Sources/ArgumentParser/Parsable Types/ParsableCommand.swift:209` | Only active call is self-recursion; its former entry is commented out. |
| AP `dumpHelpArgumentDefinition()` | `Sources/ArgumentParser/Usage/HelpGenerator.swift:524` | No active production caller. |
| AP `uniquingAdjacentElements()` | `Sources/ArgumentParser/Utilities/SequenceExtensions.swift:25` | Callers are tests outside the production scope. |

The removed diagnostic is KF `KFCrossPlatformViewRepresentable` at
`Sources/SwiftUI/KFAnimatedImage.swift:77`, used in the conformance at line 85.
The existing compiler mutation experiment and the new raw-index relation support
its restored reachability.

## Direct consumers and latency

Both builds find 14/14 expected nonlocal consumers across the six frozen tasks.
The revised build removes `Request` and `KingfisherManager` from the caller sets.
No missing or extra nonlocal consumers remain in these tasks. Symbol counts stay
at 2,167 / 2,016 / 1,374; graph edges change from 9,378 / 9,303 / 6,505 to
9,039 / 8,956 / 6,478 as receiver-only edges are removed and alias evidence is added.

Each table value is the median of 60 warm MCP `query` requests per arm, pooling
both execution orders. Individual run medians and samples remain in the JSON.

| Task | Before | After | Observed reduction |
|---|---:|---:|---:|
| AF clock initializer | 117.02 ms | 48.99 ms | 58.1% |
| AF response serializer | 115.69 ms | 50.53 ms | 56.3% |
| KF cancellation flag | 114.17 ms | 43.03 ms | 62.3% |
| KF original cache hit | 118.76 ms | 46.77 ms | 60.6% |
| AP help banner | 114.30 ms | 42.03 ms | 63.2% |
| AP Bash completion | 114.28 ms | 42.66 ms | 62.7% |

The measured reduction is 56–63% on these warm sessions. It combines revised graph
work with the process-wait fix; it does not isolate an engine-wide speedup or
establish statistical significance. No new Periphery or SourceKit-LSP timing or
agent trial was run. The original comparison's limitations still apply.

**Remaining local-function limitation:** `failCurrentSource` is absent as an index
symbol and its references remain attributed to outer `retrieveImage`. Exact local
consumer granularity therefore remains 13/14; source inspection is still needed
for that case. The implementation does not synthesize graph symbols by guessing
from mangled parameter names.

## Verification

The measured production diff and release binary hashes were rechecked after all
final gates. [Verification evidence](2026-09-15-improvements/verification.json)
records the commands, exit codes, coverage counts, and log hashes.

| Final check | Result |
|---|---|
| `Scripts/coverage.sh` | 1,248 tests / 143 suites passed; unit coverage 86.86% (24,752/28,497), actual CLI integration coverage **92.99%** (26,498/28,497), threshold 90%. |
| Fresh `swift build` and CLI contract | Passed. |
| Actual compiler fixture harness with fresh debug binary | Passed: 22 unused findings, one test-only finding, public retention, bridges and target filters, external retention/explanation, Objective-C limitations. |
| `dead --strict` | No findings; 5,099 symbols / 27,147 edges, with the configured-path-filter limitation preserved. |
| `cycles --strict` and `cycles --level type --strict` | Both passed with no findings. |
| `rules --strict` | Passed with no findings. |

Regression coverage includes opposing retained/reported compiler cases for alias
use, static versus dynamic helpers, actual generic/existential requirements,
protocol defaults/refinement, class dispatch, external witnesses, and implicit
public access. Focused tests additionally cover ambiguous source bindings, unknown
attributes, filtered contracts, external-extension grouping, and real process exits.
The tests do not establish behavior on arbitrary applications or inactive targets.

These measurements were captured from the working implementation on
`fix/analysis-query-reliability` before release preparation. Recorded binary versions
and hashes identify those prerelease measurements.
