# Competitive gap scan — 2026-09-18

Capability review of Cartograph 0.18.0 against the tools previous rounds measured
(Periphery OSS 3.8.0 → Periphery Pro, SourceKit-LSP, Semgrep 1.164, CodeQL) plus
tools not previously compared (SwiftLint analyzer rules, Emerge Reaper, Serena
MCP, ios-agent-mcp). This is a feature/gap analysis, not a re-run of the
benchmark corpus — the frozen evaluation workspace is no longer on disk.

## What competitors added since the archived baseline

- **Periphery 3.4→3.8 / Pro**: baseline support, superfluous
  `// periphery:ignore` detection (3.7), `--retain-equatable/hashable-properties`,
  Bazel 9 mode, unused `@IB*` member detection, wrapped properties excluded
  from assign-only, `--write-results`. Commercial Pro adds guided setup polish;
  the analysis model is unchanged (index → graph → reachability from roots).
- **SwiftLint**: `unused_declaration` and `unused_import` are analyzer rules —
  same index-store technique, per-file granularity, `unused_import` supports
  autocorrection.
- **Emerge Reaper**: dead-code detection from *production runtime data*
  (class instrumentation + telemetry), now fully open-sourced and unmanaged.
  Different mechanism — complements rather than competes with static scans.
- **Serena MCP**: agent-facing symbol tools (`find_symbol`,
  `find_referencing_symbols`, `insert_after_symbol`) over sourcekit-lsp —
  read+edit, multi-language, no graph queries.
- **ios-agent-mcp**: xcodebuild/simctl workflows — different product.

## What Cartograph already covers

dead + `--explain`, unused-parameter / assign-only / unused-import warnings,
test-only symbols, baseline suppression, `cartograph:ignore` comments,
per-member IB resolution (`interfaceBuilderOutlet`/`Action` boundaries),
cycles + weakest link, metrics, YAML rules, query/impact/dataflow, bridges +
external retentions, runtime discovery/collect/verify, SARIF + checkstyle +
github-actions formats, MCP serve, snapshot diffs.

## Gaps (ranked)

1. **Warm `query` latency vs LSP** *(P1, already measured)* — harder-comparison
   recorded LSP warm ~1.1 ms vs MCP ~43 ms; every `query` rebuilds the
   reachability report and evidence index even for direct-consumer questions.
   The open item named there is a **bounded direct-consumer path** — the same
   pull-model pattern PR #104 applied to `impact` (compute only what the
   question needs from adjacency lists, cache reachability per session).
   **Done** — `AnalysisSession` caches the prepared analysis per generation;
   warm `query` ≈ 0.1 ms inside the freshness window (PR #106).
2. **Superfluous `cartograph:ignore` detection** — Periphery 3.7 reports an
   ignore comment when the declaration is actually used. Prevents
   suppression-rot. Warning-class diagnostic; cheap (reachability result +
   attribute set already exist). **In progress** — counterfactual `dead`
   warning under `superfluous-ignore` (PR #107).
3. **Redundant public accessibility** — Periphery's redundant-public analysis
   (disabled in our comparisons) flags decls referenced only inside their own
   module → could be `internal`. Computable from index references; fits the
   non-strict warning class. Watch the `retain_public` interaction.
4. **File-seeded `impact --before` misses edges removed between two changed
   files** — documented H4 limitation: both endpoints land in `changeScope`,
   not `affected`. Fix = diff the change-scope subgraphs between snapshots.
5. **Mechanical fix path** — SwiftLint autocorrects `unused_import`. A
   `cartograph fix` (or `--fix`) for the safe warning classes (remove unused
   imports, `_` for unused parameters) is the one piece of write-path a
   competitor ships. Agents can do it by hand; a verified fixer is safer.
6. **Impact granularity flag** — pilot noted exact consumers +2 containing
   types. Distinguish them in output instead of flattening.
7. **Test-impact query** *(differentiator, not gap)* — reverse reachability
   from XCTest/`@Test` roots: "which tests does this change touch". No Swift
   competitor does this; reuses the existing graph + `impact` plumbing.
8. **Official GitHub Action** — composite action wrapping
   `check`/`dead --strict` + SARIF upload. Distribution friction only.
9. **`retain_equatable/hashable_properties`** — minor option parity.
10. **Runtime-telemetry retention (Reaper-style)** — ingest production
    used-type reports as external retention evidence. Large; the `runtime`
    evidence pipeline is the natural seam. Research only.

## Explicitly not gaps

- **Bazel mode** — Periphery has it; niche, no demand signal.
- **Editing tools in MCP (Serena-style)** — out of scope; Cartograph is
  read-only analysis by design.
- **`unused_declaration` per-file** — `dead` is strictly more capable
  (retention rules + `--explain`).
- **Unused `@IBOutlet`/`@IBAction`** — already per-member via
  RuntimeDiscoveryResolver.
- **Assign-only on wrapped properties** — already excluded via
  `accessHidingOwners`/`isAccessVisible`.
