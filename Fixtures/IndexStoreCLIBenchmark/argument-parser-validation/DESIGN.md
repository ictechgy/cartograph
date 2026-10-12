# Frozen public-project validation oracle

## Status and purpose

This is a **real-project validation workload, not the final holdout**. The parent protocol requires a separate fresh final corpus after adapter freeze, covering a multi-target SwiftPM project and a small Swift/Objective-C iOS project with header, rename/delete, stale-index, target-context, overload, protocol-extension, cross-module, and edit/restoration scenarios. This one-source-state public package cannot establish all of that.

The oracle was authored by reading the upstream Swift source and checking all source mentions. No Cartograph or comparator query, graph, diagnostic, generated USR inventory, or output was used to derive or alter the expected results. Neither arm was run by this researcher. `oracle.json` is the executable truth contract; `source-mention-audit.txt` preserves the source-only mention inventory. The locally authored graph was traversed only to verify its manually assigned minimum depths.

The practical user question is: **Before changing the option-name suggestion distance algorithm, which source-declared callables in the built ArgumentParser library can call it, directly or within five caller hops? Give each callable's source location and minimum depth.** This is structural reverse-impact information for reviewing and testing a change. It does not assert that each returned function's observable return value changes. In particular, `exitCode(for:)` constructs `MessageInfo` and is a structural caller even though its resulting numeric exit code need not depend on the suggestion text.

## Immutable project and build scope

- Repository: https://github.com/apple/swift-argument-parser.git
- Revision: `6a52f3251125d74daf04fcbd5e6f08a75d074382`
- Release tag at that exact revision: `1.8.2`
- Commit subject: `Update changelog for the 1.8.2 release (#914)`
- Sources tree: `c129dc47af2ef80b11512ad57d589f00d47b286a`
- License: Apache License 2.0 with Swift Runtime Library Exception, SPDX `Apache-2.0 WITH Swift-exception`; complete text in upstream `LICENSE.txt`.
- The upstream `Package.swift` declares `dependencies: []` at line 28. Build only `ArgumentParser`, including its local dependency `ArgumentParserToolInfo`. These contain 53 Swift files / 13,350 source lines at this revision.
- Tests, examples, tools, plugins, `ArgumentParserTestHelpers`, synthetic SwiftPM test runners, SDK/stdlib source, and either comparison tool's own source are outside the query universe.
- Verify all paths/hashes with `source-manifest.json` before running. The upstream checkout was clean at source-audit time.

Use an unmodified standalone checkout/archive of the pinned package and an empty fresh scratch directory. Build `--target ArgumentParser` once with the selected common toolchain and index-emission configuration. Both arms must read the exact same completed immutable compiler-index directory. Persist compiler version/target, full build command, package revision, source-manifest hash, unit/record manifest, and selected `libIndexStore` path/hash. Ensure the chosen target's index exists; do not assume merely requesting `-index-store-path` created it. Exclude source compilation from query latency because it is shared input, and disclose its cost separately.

Do not analyze the cached package as part of Cartograph's own dependency build: that would mix tool source and its consumer edges into this oracle's scope. Do not use a stale index with old units or a different target universe.

## Source identity and semantics

The seed is **the declaration of `editDistance(to:)` in the constrained `StringProtocol` extension** at `Sources/ArgumentParser/Utilities/StringExtensions.swift:145:8`. The extension begins at line 12 and has `where SubSequence == Substring`. This is a real extension of a standard-library protocol declared in the project; it is not a declaration on `String`, and must not be dropped merely because its extended type is external.

Use the source IDs in `oracle.json`, not bare names, for scoring. The source IDs consist of project-relative path, declaration-name line, and one-based declaration-name column, with a full qualified signature recorded alongside. Overloads must remain distinct. No expected compiler USRs are supplied or learned from a product. An adapter may resolve source identities using actual runtime records, but may not hard-code the expected caller edges or answers.

Allowed edges are explicit static **caller → callee** calls. Calls inside unnamed closures belong to the enclosing named callable. Deduplicate repeated call sites by callable. Member containment, shared owners, parameter-type references, sibling calls, property reads, and mere mentions do not add caller edges. Reverse BFS reports the minimum depth and excludes the seed. Self-recursion does not add symbols or inflate depth. No path through an external/SDK callable is inferred.

## Exact answers and source proof

Paths below are relative to `Sources/ArgumentParser/`.

Seed (not in result): `StringProtocol where SubSequence == Substring.editDistance(to:)`, `Utilities/StringExtensions.swift:145:8`.

1. Depth 1: `ErrorMessageGenerator.unknownOptionMessage(origin:name:)`, `Usage/UsageGenerator.swift:297:8`. Its filter and comparator closures call the distance helper at lines 316, 321, and 322. Three sites mean one caller.
2. Depth 2: `ErrorMessageGenerator.makeErrorMessage()`, `Usage/UsageGenerator.swift:180:8`, calls `unknownOptionMessage` at line 196.
3. Depth 2: `ErrorMessageGenerator.missingValueOrUnknownCompositeOptionMessage(origin:shortName:compositeName:)`, `Usage/UsageGenerator.swift:340:8`, calls `unknownOptionMessage` at line 345.
4. Depth 3: `ArgumentSet.errorDescription(error:)`, `Usage/UsageGenerator.swift:143:8`, calls `makeErrorMessage` at lines 147 and 152.
5. Depth 4: `MessageInfo.init(error:type:columns:)`, `Usage/MessageInfo.swift:17:3`, calls `ArgumentSet.errorDescription` at line 141.
6. Depth 5: `ParsableArguments.message(for:)`, `Parsable Types/ParsableArguments.swift:121:22`, calls the initializer at line 124.
7. Depth 5: deprecated `ParsableArguments.fullMessage(for:)`, `Parsable Types/ParsableArguments.swift:129:22`, calls the initializer at line 132.
8. Depth 5: `ParsableArguments.fullMessage(for:columns:)`, `Parsable Types/ParsableArguments.swift:145:22`, calls the initializer at line 149.
9. Depth 5: `ParsableArguments.exitCode(for:)`, `Parsable Types/ParsableArguments.swift:198:22`, calls the initializer at line 201.
10. Depth 5: `ParsableArguments.exit(withError:)`, `Parsable Types/ParsableArguments.swift:228:22`, calls the initializer at line 235.

Additional relevant edges that do not change shortest depth:

- `makeErrorMessage` also calls `missingValueOrUnknownCompositeOptionMessage` at `UsageGenerator.swift:201`.
- `makeErrorMessage` calls itself at `UsageGenerator.swift:229`.
- `MessageInfo.init` calls itself at `MessageInfo.swift:56` and `:70`.

`oracle.json` records all 13 distinct caller/callee edges entering nodes before the depth-5 frontier, with all 17 syntactic call sites. This includes both recursive edges and both diamond paths through the composite-option message. The audit searches the entire 53-file build scope for every relevant callee; other `errorDescription` occurrences are `LocalizedError.errorDescription` property reads, documentation, or unrelated variables, not this method. The initializer's `self.init` calls are separately read in its full source body.

The bounded answer counts are:

- Depth 1: exactly 1 caller.
- Depth 3: exactly 4 callers (depths 1, 2, 2, 3).
- Depth 5: exactly 10 callers (depths 1, 2, 2, 3, 4, 5, 5, 5, 5, 5).

All other in-scope source callables are negative by exact-set scoring. Explicit controls in the JSON include the sibling help route, `missingValueForOptionMessage` (wrong direction), `MessageInfo.fullText` (sibling callee), unrelated string indentation, the parsing-only APIs, and genuine depth-6 callers. `parseOrExit`, synchronous `ParsableCommand.main(_:)`, asynchronous `AsyncParsableCommand.main(_:)`, and legacy `AsyncMainProtocol.main()` are outside depth 5 even though each reaches `exit(withError:)` in one more hop.

## Workload and preregistration

The three tasks use the same seed and depths 1, 3, and 5. They are correlated depth-boundary checks, **not three independent projects or independent samples**. The depth-5 task reaches public diagnostic APIs and is the most useful real-project validation task. It covers a constrained protocol extension, unnamed closures, repeated calls, a diamond, recursive edges, an initializer, cross-file callers, a deprecated overload, and exact depth boundaries. It does not cover real Swift/Objective-C compilation, stale records, edit refresh, header changes, or cross-module call paths.

For the parent study, do not replace or weaken its frozen final decision rule: **20 independent balanced paired sessions of saved-source edit → 10 queries → edit → refresh/recompile → 10 post-edit queries; at least 20% lower median total session wall time, paired bootstrap ratio upper 95% confidence bound below 1, and zero false positives, false negatives, or stale-result failures.** The public-project oracle is validation evidence only. Its source-static workflow cannot establish that final session result.

If reporting exploratory timing on this validation workload, label it separately and predeclare the implementation, cache policy, exact entry/exit timing, source/module scope, and adapter hashes before first observation. End-to-end result time must include each arm's required discovery, native CLI subprocesses, parsing, graph construction, depth traversal, and answer normalization. Compilation shared by both arms may be excluded, while tool-specific ingestion/preparation must be included or separately amortized with an explicit session query count. Do not call repeated runs with shared ingestion independent cold observations. Interleave balanced AB/BA order and retain every valid run.

The actual upstream comparator is `index-dump` at IndexStoreDB commit `64aa0b26913249c4e7c21d351a215fba02702003`, whose source `Sources/index-dump/index-dump.swift` accepts one unit-or-record name and emits that unit or record. A generic adapter may enumerate relevant native units/records and reconstruct calls from its output; report this adapter explicitly. Give it the same generic caching/amortization opportunities as Cartograph. Do not penalize it with needless repeated dumps of unchanged records, use an output-derived oracle, or claim that raw byte reduction is token/time savings unless the measured consumer genuinely must ingest those bytes. Native CLI invocations, bytes, peak memory, cold preparation, and warm query time are secondary descriptive measures, not substitutions for the final preregistered cost gate.

## Accuracy and reproducibility checks

- Before either tool is run, freeze this directory's hashes and the chosen generic normalizer/adapter hashes.
- Verify source hashes and expected definition anchors.
- Require exact source-ID set equality and minimum-depth equality for every query. Compare each arm independently to the frozen source oracle; agreement between arms is insufficient.
- Missing declarations, ambiguous overload resolution, parse failures, incomplete records, unsupported attribution, or unexpected extra callers fail the check; they must not silently disappear or be converted into an empty answer.
- Keep normalized source results, raw native outputs, commands, exit codes, tool/adapter hashes, and timing logs. A generic filtering step may enforce the fixed source universe, but may not remove a wrong in-universe answer based on this oracle.
- Product-only fixes after viewing this validation case do not turn the case back into a holdout. Never claim this one package demonstrates universal superiority or satisfies the final mixed-language/edit-refresh protocol.

## Deliverable files

- `oracle.json`: exact source nodes, call edges, answers, and negative controls.
- `source-manifest.json`: SHA-256 hashes for `Package.swift`, `LICENSE.txt`, and the 53 build-source Swift files.
- `source-mention-audit.txt`: source-only callee-mention inventory used to check completeness.
- `verify_oracle.py`: source-hash/anchor and authored-graph consistency check, without executing either comparison tool.
- `SHA256SUMS`: hashes of the frozen design artifacts.
