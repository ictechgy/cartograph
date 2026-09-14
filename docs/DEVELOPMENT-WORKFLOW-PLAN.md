# Development workflow improvements

Status: the automatic discovery/collection milestone passed local acceptance (2026-09-14).
Broad framework and iOS execution coverage, plus external adoption validation, remain open.
Branch: `feature/change-impact-workflow`.
Unreleased and uncommitted. See [validation evidence](WORKFLOW-VALIDATION.md).

## Objective

Make Cartograph useful in commercial and open-source projects without a commercial license:
help people and coding agents inspect the effects of a change before editing, verify runtime
dependency evidence, and run repeatable checks in CI at a practical cost. Product competitiveness
must be supported by observable task improvements, not inferred from the number of features or tests.

## Clarified runtime acceptance requirement

Explicit contract validation alone does not meet the user's intended runtime discovery requirement.
The next implementation must discover supported dynamic boundaries and their connections from source,
resources and execution evidence with minimal manual contract writing. Track discovery recall,
false positives and unresolved boundaries on an independently labelled corpus and real applications;
line coverage of Cartograph is a separate implementation metric. Do not claim broad discovery from
passing a supplied-contract fixture or from retaining an entire class as a precaution.

Static findings, observed execution and unresolved boundaries must stay distinguishable. The second implementation now provides supported automatic selector/class/registration/resource
discovery and macOS debug execution collection. It does not provide universal instrumentation. The completion evidence below applies to that narrower
iteration and does not close this requirement.

## Required outcomes and acceptance evidence

1. **Change impact.** A symbol, explicit source file selection, or git change selection identifies
   direct and transitive consumers outside the changed files. Results include evidence paths,
   affected files/modules, relevant tests and entry points, runtime review requirements, and
   explicit ambiguity, missing input, scope and truncation information. Type/member containment,
   extensions and protocol/override dispatch must not silently lose consumers. Deletions and
   renames must not produce a clean result merely because the new index no longer contains them.
   Verify with pure graph tests, CLI contracts and actual compiler-index fixtures.
2. **Efficient agent access.** Provide a documented skill and a reusable query interface (MCP or
   an equivalent session protocol) that amortizes index loading over multiple requests, supports
   compact bounded responses, and handles source/index changes explicitly. Existing query v1
   semantics remain compatible. Verify multiple requests, error recovery, freshness and output
   size/latency against separate CLI invocations. Notify sibling projects of skill/contract changes.
3. **Runtime dependency verification.** Surface framework/runtime dependencies that are not
   ordinary direct calls. Support reviewable explicit evidence for application-specific dynamic
   dependencies and validate its targets rather than silently trusting names. Distinguish observed
   execution, declared contracts, static evidence and unknown coverage. Exercise real runtime
   behavior before/after a broken dependency; an unobserved call never proves deletion safety.
   Retain and test the existing cross-language bridge/external-retention path.
4. **CI practicality.** Reuse preparation across checks and repeated queries, or implement
   incrementality where correctness can be demonstrated. Record reproducible measurements on
   fixed inputs including a larger graph, and exercise invalidation after edits, rebuilds,
   configuration changes and deleted/renamed files. Do not describe the existing `--since`
   diagnostic filter as incremental analysis. Provide an executable CI example and performance
   regression check with documented machine/workload limits.

All outcomes require both README languages, generated skill consistency, meaningful negative tests,
and the repository gates: coverage >= 90%, CLI contracts, real-index corpus, and self-analysis for
dead code, module cycles, type cycles and layer rules. Runtime or performance evidence from a
restricted fixture is not a claim about all Swift applications or all build configurations.

## Execution order

- Establish change-impact semantics and implement the analysis, public document and CLI.
- Reuse that API for agent sessions and update the generated skill.
- Add runtime evidence validation and integrate it into impact review.
- Integrate combined CI checks, measure performance and fix the dominant costs.
- Run independent review, all required gates and representative end-to-end workflows; fix findings.

Independent design/exploration may run in parallel. Implementation ownership must not overlap.

## Baseline evidence

At `de1bac9`, the review session directly ran 850 tests (90.64% line coverage), CLI contracts,
the real-index corpus and all four self-analysis commands successfully. The 23-case value-flow
benchmark reproduced TP 20, FP 0, FN 0 over three runs. This is regression evidence, not external
adoption or a general accuracy estimate.

Existing gaps: `query` provides local neighborhoods; `--since` filters diagnostic locations rather
than calculating impact; `QuerySession` is internal and rebuilt across processes; runtime bridge
coverage and the unexecuted Flutter demo have explicit limits. README bridge/value-flow descriptions
contain stale statements that must be corrected against the final implementation.

## Completion evidence

All four implementation outcomes passed local acceptance. `impact` includes independent historical
comparison; the generated skill and MCP tools reuse bounded results and refresh changed inputs;
runtime contracts are bound to source/index/graph and the executed binary; `check` shares preparation
across all four CI checks. The existing query v1 and retention behavior remain compatible.

- 991 tests passed; production line coverage 90.20% (15909/17637), above the unchanged 90% gate.
- CLI contracts, original fixtures and value-flow/bridge regressions passed. New real-index impact,
  deletion/rename snapshots, Foundation execution and live MCP invalidation/recovery harnesses passed.
- Dead, module cycles, type cycles, rules and combined check reported no findings on this repository.
- Matched three-sample timings on 3,370 symbols/17,636 edges: ten queries 12.114 s CLI versus 1.737 s
  MCP (6.97×), warm MCP median 173.48 ms; four checks 4.359 s versus combined 1.270 s (3.43×).
  All result-equality, input-stability and performance gates passed.
- Both README languages, generated skill, CI, CHANGELOG, runtime documentation and sibling handoff
  notifications are updated. No commit, push or release was requested or performed.

Independent review and actual execution found and corrected dispatch over-propagation, type/extension
selection ambiguity, lost current snapshot limitations, stale cache metadata, Swift dynamic/ObjC
selector confusion, MCP lifecycle/response bounds, nested evidence caps, an unused helper and a CLI
type cycle. [The validation report](WORKFLOW-VALIDATION.md) records scope, timings, failures and
reproduction commands. External adoption and broad runtime completeness remain unproven; they are
not inferred from passing synthetic fixtures or local speed measurements.

## Automatic discovery milestone evidence

See [the current validation update](WORKFLOW-VALIDATION.md#automatic-runtime-discovery-update--2026-09-14)
for the 39-case relationship result, 1,068 tests, separate unit/integration coverage, native collection
failures, preserved old gates and the final 7.83×/3.35× workload measurements. The unresolved
framework patterns and macOS-only collection limit remain explicit; they are not counted as
successful absence of dependencies.
