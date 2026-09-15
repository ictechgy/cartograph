# External-project comparison — 2026-09-15

This pilot did **not demonstrate an impact-review accuracy or agent-time advantage**
over ordinary source search or SourceKit-LSP. Cartograph produced the expected
nonlocal consumers, with two additional containing types. Its unused-code scan
was quicker than the installed Periphery OSS binary on these inputs, but the
disagreements exposed one confirmed misleading diagnostic and several missed
candidates. Reliability improvements have stronger evidence here than adding
more analysis mechanisms.

The product was **Cartograph 0.13.0**, unchanged during the evaluation. The
[protocol](2026-09-15-protocol.md), [frozen tasks](2026-09-15/tasks.json),
[machine-readable scores](2026-09-15/results.json), and
[agent answers](2026-09-15/agent-results.json) accompany this report.
The [agent prompts](2026-09-15/agent-prompts.json) preserve their instructions with
only the local workspace prefix normalized.

## Scope and controls

Three fresh public checkouts were pinned before tool comparison. These are
libraries; this is not an evaluation of three complete iOS applications.

| Project | Pinned revision | Production symbols / edges | Graph source files | Initial Swift build |
|---|---|---:|---:|---:|
| [Alamofire](https://github.com/Alamofire/Alamofire/tree/bda9ed57d72988a3a2ada33d824583541f86eac6) | `bda9ed5` | 2,167 / 9,378 | 44 | 12.75 s |
| [Kingfisher](https://github.com/onevcat/Kingfisher/tree/ab1c1de54a1ce1adfe1733c7195056a153029d3a) | `ab1c1de` | 2,016 / 9,303 | 68 | 9.16 s |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser/tree/93c68882a28d9c82cd87be0acb7d76e35494b9b5) | `93c6888` | 1,374 / 6,505 | 53 | 22.91 s |

Environment: Apple Silicon, Apple Swift 6.4 (`swiftlang-6.4.0.27.1`). Analysis
covers macOS production sources: `Source/**`, `Sources/**`, and
`Sources/ArgumentParser/**` plus `Sources/ArgumentParserToolInfo/**`, respectively.
Tests were built for Alamofire and Argument Parser, but excluded from scored
production findings and consumers. Kingfisher's package does not include its
Xcode test suite. No application scenarios or historical bug fixes were executed.

Cartograph and Periphery OSS **3.8.0** read the same `.build/out` per project.
Both retained public/Objective-C declarations. Periphery's unused-import and
redundant-public analyses were disabled; its parameters were counted separately.
An additional scan enabled its assign-only analysis. Flags align the task scope;
they do not make the engines' retention semantics identical.

SourceKit-LSP used its normal background indexing on the same pinned sources.
Disabling it initially produced empty results; those setup attempts are excluded.
The accepted run waits for `workspace/synchronize(index: true)`. SourceKit-LSP's
own index is distinct from the index supplied to the two CLI scanners.

Kingfisher reports **28 of 98 source files without a known index unit**. This
limitation remains in Cartograph output. Inactive platform branches and external
library clients are outside the oracle; an absent finding is not evidence about
them.

## Change-impact review

Independent source readers selected two declarations per project from recent
changes, without seeing tool results. The six tasks contain **14 immediate
consumer declarations and 16 reference lines**. They are small tasks with one to
four consumers each; their selection favors bounded, inspectable changes.

The oracle distinguishes exact local functions from their nonlocal enclosing
declarations. For `isTaskCancelled`, `failCurrentSource` at
`KingfisherManager.swift:363` is nested inside `retrieveImage` at line 303. Both
representations were recorded before querying the tools.

| Changed declaration | Expected nonlocal consumers | Cartograph `impact --depth 1` | SourceKit-LSP incoming calls |
|---|---:|---:|---:|
| Alamofire `Instant.init()` | 4 | 4 | 4 |
| Alamofire `processNextResponseSerializer()` | 3 | 3 + containing `Request` | 3 |
| Kingfisher `isTaskCancelled` | 3 | 3 | 3 |
| Kingfisher `deliverOriginalCacheHit` | 2 | 2 + containing `KingfisherManager` | 2 |
| Argument Parser `getHelpBanner()` | 1 | 1 | 1 |
| Argument Parser `CommandInfoV0.bashCompletionScript` | 1 | 1 | 1 |

Both tools found **14/14 nonlocal consumers**. Cartograph added two containing
types, which are extra review candidates for this function/property-level task.
Those types can still be relevant context in a broader impact report.

At exact local-function granularity, both tools identify **13/14** and project
the remaining local function to its enclosing method. SourceKit-LSP also returns
the exact reference line, allowing source inspection to recover the local
function. Ripgrep retrieves all **16/16 witness lines** among **28 raw matching
lines**; it still requires semantic interpretation of declarations, comments,
overloads, and containing functions. This is retrieval coverage, not a claim
that text search performs semantic analysis.

All accepted samples were stable after normalizing unordered retrieval results.
Cartograph CLI and MCP returned exactly equal impact documents; MCP session
generation/fingerprint remained stable. Depth truncation is expected at depth 1
and was not treated as output truncation.

## Agent-assisted review

Six fresh native agents used the same `explore` role: **gpt-5.6-luna, low
reasoning**. Each answered both tasks for one project. One arm was assigned ordinary
source search; the other was also allowed Cartograph and received command guidance.
Both could inspect the same source and were asked to include local functions and
exclude transitive callers/containing types. The gold answers were withheld.

| Assigned tools | Exact task answers | Exact local consumers | Nonlocal projection | Clock time by project (AF / KF / AP) |
|---|---:|---:|---:|---:|
| Source search | 6/6 | 14/14 | 14/14 | 28 / 27 / 29 s |
| Source search + Cartograph | 5/6 | 13/14 | 14/14 | 40 / 27 / 39 s |

The single discrepancy was the nested `failCurrentSource`: the Cartograph arm
returned its enclosing `retrieveImage`, despite the local-function instruction.
It retained the correct reference line. This is a specificity error in this
review task, not evidence that it would introduce an application regression.

The recorded sums are **84 s and 106 s**. These are agent-reported clock readings
at one-second resolution, one observation per arm/project, on a shared host.
They are descriptive, with no statistical significance claim. Token usage, cost,
complete native tool transcripts, full editing success, tests saved, and developer
adoption were not measured. No result here establishes the behavior of another
model or a full IDE-equipped coding workflow.
The agents' [reported command arrays](2026-09-15/agent-reported-commands.json)
name Cartograph calls in the added-tool arm, but include some abbreviations.
They are self-reports, not captured execution traces; adherence to the assigned
tool restrictions is not independently verified. Prompts and answer records are
hash-linked to make the preserved assignment/response pairing inspectable.

## Unused-code comparison

The aligned scans produced the following counts. They are output counts, not
precision or recall; common findings were not exhaustively adjudicated.

| Project | Cartograph declarations | Periphery OSS nonparameter declarations | Additional Periphery parameter diagnostics | Assign-only diagnostics in the separate scan |
|---|---:|---:|---:|---:|
| Alamofire | 18 | 21 | 17 | 5 |
| Kingfisher | 8 | 8 | 22 | 14 |
| Argument Parser | 35 | 37 | 16 | 3 |

There were **57 overlapping declaration USRs and 13 disagreements** in the
aligned scans. Independent review examined all 13 using source and the existing
graph. An incoming reference alone does not prove liveness: isolated clusters
and unused protocol requirements must be considered separately.

**Confirmed Cartograph misleading diagnostic:** Kingfisher's
[`KFCrossPlatformViewRepresentable`](https://github.com/onevcat/Kingfisher/blob/ab1c1de54a1ce1adfe1733c7195056a153029d3a/Sources/SwiftUI/KFAnimatedImage.swift#L77)
is used in the conformance clause at line 85, in the same macOS branch. Cartograph
reports the alias as unused and its graph has no incoming edge. The original
target builds; renaming only the alias makes the compiler reject the conformance
at line 85. This confirms a missing reference in the diagnostic's evidence.

**Nine Periphery-only candidates have source-backed explanations:**

- Six are kept by broad `dynamicDispatch` retention: Alamofire's void `around(_:)`
  overload and the internal `OfflineRetrier` initializer/factory pair; Argument
  Parser's `checkAsyncHierarchy`, `dumpHelpArgumentDefinition`, and
  `uniquingAdjacentElements`. Their apparent references are from unreachable
  helpers, self-recursion, comments, or tests excluded from the production scope.
- Three concern unused protocol requirements/default implementations:
  Kingfisher's `DisplayLinkCompatible.timestamp` and Argument Parser's two
  `_visibility` declarations. A read of a concrete implementation does not imply
  a read through the protocol requirement. Existing graph traversal can preserve
  the requirement and then its default implementation.

These are scoped missed-finding candidates, including conservative retention
tradeoffs. Coordinated removal has not been validated by application tests.

**Three remaining Cartograph-only candidates:** Argument Parser's
`DecodableParsedWrapper` is a plausible redundant marker protocol; its behavior
is implemented against other constraints. `isSubcommands` and `_platformLock`
have no live field use, but Periphery also reports both when assign-only analysis
is enabled. Those two differences come from the benchmark flag, not a missing
Periphery capability. The full adjudication is in
[adjudications.json](2026-09-15/adjudications.json).

The separate assign-only scan's 22 diagnostics are not 22 proven removal
opportunities. For example, Kingfisher's processing-identity fields participate
in synthesized `Hashable` behavior. The scan did not enable Periphery's optional
Equatable/Hashable retention flags, so these results need that policy context.

## Timing

Three accepted serial samples used unchanged inputs. Scan samples preceded the
agent trials; final query samples were repeated after those trials ended.
Filesystem caches were not dropped. Each table entry is a median; these are small
graphs, not large-application scalability measurements.

| Project | Cartograph unused scan | Periphery OSS aligned scan |
|---|---:|---:|
| Alamofire | 0.247 s | 1.208 s |
| Kingfisher | 0.223 s | 1.152 s |
| Argument Parser | 0.214 s | 1.176 s |

Periphery also analyzes parameters and has different retention semantics. The
table supports lower observed scan latency on this workload, not an engine-wide
speedup or a comparison against current commercial Periphery.

Across the six impact questions, per-task median latency ranged as follows:

| Operation | Range |
|---|---:|
| Cartograph standalone `impact` | 183–233 ms |
| Cartograph warm MCP `impact` | 129–145 ms |
| SourceKit-LSP warm prepare + incoming-call requests | 2.7–4.2 ms |
| Ripgrep raw retrieval | 6.0–7.9 ms |

Cartograph returns broader runtime/review evidence, so these are not identical
output workloads. The measurements nevertheless show the cost a user pays when
asking only for immediate consumers. MCP does not eliminate that cost.

A **post-pilot supplement** also measured the existing `query` command, to avoid
basing the recommendation solely on `impact`. Its `usedBy` consumers were the
same for all six tasks, including the two containing types and the local-function
projection. Three serial samples per task measured **229–426 ms** for standalone
`query` and **113–117 ms** for its cached MCP tool. CLI/MCP query documents were
equal and stable. `query` also returns dependencies and reachability, so it still
does more work than incoming-call lookup. This supplement uses unchanged pinned
sources and tool versions; it does not replace the frozen agent intervention or
constitute a before/after optimization measurement.
[Supplemental results](2026-09-15/symbol-query-supplement.json)

SourceKit-LSP's first observed initialization/index preparation was approximately
17.9 / 11.3 / 25.6 s for the three projects, separately from their Swift builds.
With its existing index, later initialization took 0.38 / 0.36 / 1.05 s.
Cartograph MCP handshake, preparation, and first impact response took
0.72 / 0.71 / 0.67 s with compiler indexes already available. Preparation and warm
latency must stay separate; none is a clean-machine installation measurement.

## Current competitive context

The measured Periphery binary is archived OSS **3.8.0**. Current Periphery's
official site documents agent-oriented output, a VS Code extension, a reusable
public-repository workflow, and claimed scan improvements. Agent integration by
itself is therefore not an exclusive product distinction.
[Current Periphery](https://periphery.pro/)

The current product's local scans require account authentication; its account-free
OSS option runs through the official public GitHub workflow. No account was
created, credentials read, or public workflow published in this evaluation.
Its runtime performance/accuracy is **not run**, not zero.
[Installation](https://periphery.pro/docs/installation/),
[OSS workflow](https://periphery.pro/docs/open-source/)

SwiftLint is not a substitute for the same impact question; it does expose an
opt-in analyzer `unused_declaration` rule. Its binary was unavailable locally,
and its analyzer was not included in the measured ranking.
[SwiftLint rule](https://realm.github.io/SwiftLint/unused_declaration.html)

## Priorities supported by this pilot

1. **Repair missing typealias evidence in conformance/inheritance clauses.** The
   Kingfisher case is a compiled real-project counterexample, and misleading
   unused diagnostics directly undermine trust.
2. **Audit protocol requirement/witness reachability and `dynamicDispatch`
   retention.** Preserve existing safeguards; any narrowing still needs opposite
   cases and the repository's three-project delta checks. The nine candidates
   provide concrete cases for that work, not permission for blanket narrowing.
3. **Make direct-consumer review precise and inexpensive.** Separate containing
   types from immediate function/property consumers, expose callsite evidence,
   and preserve nested-function context. Measure a bounded direct-consumer query
   independently from richer runtime impact analysis.
4. **Test a harder user workflow before broadening the product.** These easy,
   local reference tasks show no added agent benefit. Historical deletion/rename,
   dispatch, resource, and cross-language change tasks can test the existing
   differentiators, with the same source access and an LSP-capable baseline.

## Reproduction and verification

The scripts require Python 3, the specified installed CLIs, Git, and the same
Swift toolchain. `prepare` downloads public sources into a fresh directory and
refuses to overwrite existing projects. Example, from this repository:

```bash
EVAL_ROOT=/path/to/fresh/cartograph-evaluation
python3 Scripts/benchmark-external-projects.py prepare \
  --repos "$EVAL_ROOT/repos" --output "$EVAL_ROOT/raw/prepare" \
  --manifest docs/evaluation/2026-09-15/metadata.json
python3 Scripts/benchmark-external-projects.py scans \
  --repos "$EVAL_ROOT/repos" --output "$EVAL_ROOT/raw/scans"
python3 Scripts/benchmark-external-projects.py scans --project argument-parser \
  --repos "$EVAL_ROOT/repos" --output "$EVAL_ROOT/raw/scans-scope-corrected"
python3 Scripts/benchmark-external-projects.py queries \
  --repos "$EVAL_ROOT/repos" --output "$EVAL_ROOT/raw/queries-final" --tasks "$EVAL_ROOT/tasks.json"
python3 Scripts/benchmark-external-projects.py mcp \
  --repos "$EVAL_ROOT/repos" --output "$EVAL_ROOT/raw/mcp-final" --tasks "$EVAL_ROOT/tasks.json"
python3 Scripts/benchmark-external-projects.py symbol-queries \
  --repos "$EVAL_ROOT/repos" --output "$EVAL_ROOT/raw/symbol-query-supplement" --tasks "$EVAL_ROOT/tasks.json"
python3 Scripts/verify-external-oracles.py --root "$EVAL_ROOT"
```

Scoring this recorded pilot additionally reads `agent-results.json`; copying the
published answers replays its scoring, not a new agent trial. New trials need
fresh answers under the protocol:

```bash
cp docs/evaluation/2026-09-15/agent-results.json "$EVAL_ROOT/agent-results.json"
python3 Scripts/score-external-comparison.py --root "$EVAL_ROOT" --output "$EVAL_ROOT/scores.json"
```

Seven isolated compiler mutations rejected the changed target as expected,
including the live typealias. Explicit compiler diagnostics covered 10 of the
16 task reference lines plus the alias's conformance. The compiler stopped
before diagnosing six other task references; these remain source/LSP-backed
witnesses, not claimed compiler-validation passes. Source bytes and mtimes were
restored, and all external tracked source trees remained unchanged.
[Compiler evidence](2026-09-15/compiler-mutations.json)

Local raw command outputs, preparation logs, failed setup attempts, and accepted
samples are preserved in the evaluation workspace described in the delivery
message. The repository stores compact results with project-relative paths;
raw native-agent tool transcripts are not included.

Repository verification passed: **1,207 tests**, unit coverage **86.70%**, and
unit plus actual CLI integration coverage **92.91% (26,190/28,188)** across 151
production files. The 90% gate, CLI contract, real-index fixtures, build, dead-code,
module/type cycle, and layer-rule checks all passed. Python compilation and local
JSON/link checks passed. The preparation command was also executed against a
second set of three fresh pinned checkouts; all built successfully. These checks
validate the artifacts and unchanged product code, not broad analysis accuracy.
[Verification record](2026-09-15/verification.json)

The final harness rejects command failures/timeouts, JSON-RPC/tool errors, version
or binary-hash drift, changed tracked sources/revisions, and modified oracle files.
The scorer separately validates graph and assign-only scan metadata. Actual
negative controls confirmed failure propagation and rejection of unready LSP
evidence and changed gold. Native-agent command compliance remains the expressly
unverified self-report described above.
