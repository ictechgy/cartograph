# Contributing to Cartograph

Thanks for taking the time. This document covers what you need to build, test and land a change.

## Prerequisites

- macOS 14 or later
- A Swift toolchain compatible with the pinned dependencies (development uses Swift 6.4)

`indexstore-db` has no semantic version tags — it tracks Swift releases on branches. `Package.swift`
pins `release/6.4.1`. CI selects the newest Xcode installed on its runner and verifies the compiler
fixtures on that toolchain; it is not a fixed multi-version compatibility matrix. When you move the
pin, delete any cached index database (`$TMPDIR/cartograph-index-db`): the
index format is backward-compatible but never forward-compatible, so a newer store read with an
older `libIndexStore` fails or, worse, reads nothing.

## Build and test

```bash
swift build
swift test
Scripts/coverage.sh          # tests plus the coverage gate
Scripts/coverage.sh --report # per-file breakdown
```

Line coverage must stay at or above 90% for `Sources/`. Tests, dependencies and
`CartographTestSupport` are excluded from the denominator.

Do not chase the number with tests that assert nothing. `coverage.sh` prints the unit-test-only
percentage, then merges profiles from the instrumented CLI contract, automatic discovery, Core Data version, native
collection and MCP harnesses. `--unit-only` retains the original unit measurement. Integration
profiles count actual execution of the same production code; no production files are removed to
reach the threshold. Dependency discovery recall and false positives remain separate metrics.
`--skip-test` rejects newer source, test, fixture, skill, harness, binary or unit-profile timestamps; rerun the full
command after changes. `python3 Scripts/verify-coverage-inputs.py` verifies this reuse contract with
isolated stub tools. Those stub values are never included in the product's coverage measurement.

## Analyze the repository with itself

```bash
swift build
swift run cartograph dead   --strict
swift run cartograph cycles --strict
swift run cartograph cycles --level type --strict
swift run cartograph rules  --strict
```

All four analysis commands must pass. `.cartograph.yml` in the repository root configures this.

This is not ceremony: the protocol-witness false positive, the `@main` false positive and the
absolute-vs-relative glob bug were all found this way and by nothing else.

## Architecture rules

Dependencies flow one way:

```
CartographCore  ←  Config · Syntax · Analysis · Export · IndexStore  ←  Kit  ←  CLI
```

- `CartographCore` has no external dependencies. Keep it that way.
- Only `CartographIndexStore` may import `IndexStoreDB`. Only `CartographSyntax` may import
  `SwiftSyntax`. Only `CartographConfig` may import `Yams`.
- Analysis code takes an `IndexSnapshot` and returns values. If a new analysis needs to read a file
  or run a process, that belongs in `CartographKit` or above.

`cartograph rules` enforces the first two in CI.

## Adding a retention rule

Retention rules are the reason this tool is trustworthy or not, so they carry an extra bar:

1. Add a case to `RetentionReason` with an explanation sentence. `dead --explain` prints it.
2. Implement the check in `RetentionPolicy`.
3. Add a test that fails without the rule and passes with it.
4. If it is configurable, add the option to `RetentionOptions` **and** to
   `ConfigurationTemplate`, and document it in both READMEs.

Prefer retaining too much over too little. A false positive costs a reviewer's trust; a false
negative costs one uncollected deletion.

### Narrowing one

That bar is for widening. Narrowing a retention rule is the opposite trade and needs the opposite
evidence, because a narrower rule fails **silently**: the corpus keeps passing while the tool quietly
stops reporting something, or starts reporting something it must not.

1. Put the shapes that must **stay** retained into `Fixtures/FalsePositiveCorpus` first, next to the
   ones that must now be reported, and say in the corpus README which real project each came from.
2. Measure the delta on at least three real projects and put the table in the pull request: findings
   before, findings after, what is newly reported, what is no longer reported.
3. Check every newly reported declaration by hand. `grep` for the name; a genuine finding has one
   occurrence, its declaration.
4. Say what the rule still covers. Narrowing usually means the rule now applies to members but not
   to the type that holds them, or the other way round — write that sentence into both READMEs.

## Commits

Conventional Commits, with the body in Korean or English:

```
feat(analysis): 순환 의존성 탐지 구현
fix(core): 경로 글롭이 절대 경로와 맞지 않던 문제 수정
```

Scopes match the module names: `core`, `config`, `syntax`, `analysis`, `export`, `indexstore`,
`kit`, `cli`. Keep commits small and single-purpose. Explain *why* in the body — the diff already
says what.

Work on a branch (`feature/…`, `fix/…`, `refactor/…`), never directly on `main`. Run
`swift build && Scripts/coverage.sh` before opening a pull request.

## Code style

- Four spaces, 120 column limit.
- **Project language:** documentation and user-facing output in English, source comments in Korean
  (the maintainer's working language), identifiers always in English. Pull requests may be written
  in either language.
- Document *why*, not *what*. `// 순환을 끊을 후보 간선을 고른다` is noise next to a function called
  `suggestedEdgeToBreak`; the reason it picks the lowest-weight edge is not.
- Every public type and function carries a doc comment.
- No empty `catch` blocks. Error messages state the cause **and** the way out.
