# Enum expansion review

The existing `impact --before <snapshot>` comparison includes an additive
`enumChangeReview` section in JSON and text. Select the changed enum, an added
case, or its source file with the existing impact selectors. Ordinary graph
impact and exit-status behavior are unchanged.

Capture a baseline with enum-aware Cartograph (0.27.0 or a later capable
release) before adding enum cases, then rebuild the current index and compare it with that baseline. Older snapshots still decode,
but their missing enum inventories are reported as unavailable, not as empty
complete case sets.

## First supported slice

- A switch on an explicitly typed, unshadowed function parameter, with
  compiler-bound enum case arms and `default` or `@unknown default`.
- A direct finite array literal of compiler-bound enum cases calling the modeled
  standard-library `contains`, with the same typed-parameter argument proof.
- Direct `!` negation of that membership call, with a compiler-bound modeled
  negation operator.

Candidates identify an added case that is not unconditionally named before a
fallback, or whose identity is outside an explicit literal set. They include enum
and case USRs, declaration and decision locations, explicit and guarded case
sets, operation targets and limitations. A guarded case is not unconditional
handling. A negated membership has a distinct kind.

These are review candidates, not proven behavioral bugs or runtime paths.
Custom equality can affect even standard `contains`. A custom or unknown
membership target, an unproved subject type, a shadowed name, a refutable or
unsupported pattern, stale source, conditional compilation or an incomplete
inventory remains unresolved or partial. References in a branch body do not
attribute an unrelated decision.

## Coverage and comparison limits

Enum identity is matched by compiler USR and module. Missing enums are unmatched,
not empty inventories. Case additions are observations between two indexed
builds: differing build configuration, conditional compilation or indexing
scope can resemble source additions. This version does not prove those builds
have equivalent scope.

Absent per-file facts mean unscanned. Conflicting captures are marked conflicted
rather than unioned into a complete inventory. Snapshot export filters facts with
their included files, and snapshot relocation rebases all evidence locations.

The first slice does not evaluate if/guard case, equality/inequality, filters,
aliased or dynamic collections, `allCases`, local-variable dataflow or arbitrary
subject expressions. Detected but unsupported decision evidence and missing
coverage are shown explicitly; unsupported syntax is not an exhaustive census. A default-only switch without sufficient arm evidence is
unresolved.

Only selected enum expansions are reported. Lists are deterministically ordered,
`--limit` bounds reported lists, total counts remain uncapped, and
`truncated` signals omitted output. The feature is review information rather
than a new `--strict` failure category.

## Regression coverage

The tests include paired real compiler-index captures before and after an enum
expansion, ordinary and negated array membership, custom `contains`, located
fallbacks, guarded arms, selection isolation, deterministic JSON/text, legacy
snapshots, conflicting merges, export filtering and historical path rebasing.
The compiler fixture is also the compatibility check for the exact standard
library USRs; an unknown identity must not silently fall back to matching a name.

## Upgrade and baseline migration

Enum expansion review first shipped in [0.27.0](https://github.com/ictechgy/cartograph/releases/tag/0.27.0).
The current installation examples pin published
[0.27.1](https://github.com/ictechgy/cartograph/releases/tag/0.27.1), whose tag identifies
`41eb2df349eed5e5593d0edf948c86c3750150c7`. Its
[release workflow](https://github.com/ictechgy/cartograph/actions/runs/39046187278) verified the
unpacked universal archive, including the public enum-change contract, before publication.
The separate [Homebrew update](https://github.com/ictechgy/homebrew-tap/pull/62) and
[post-merge install tests](https://github.com/ictechgy/homebrew-tap/actions/runs/39048130600) passed
on macOS arm64. Check `cartograph --version` after your own install or upgrade.

0.27.1 removes redundant Impact preparation work without changing the enum-review contract or
snapshot format. The regression evidence does not establish an end-to-end latency improvement;
the original baseline recapture and coverage limitations below still apply.

1. At the pre-change revision, rebuild the relevant targets with the intended Swift toolchain,
   build configuration and conditional flags. Use the actual compiler index store produced by that
   build; changing a requested index path does not guarantee the build system used it.
2. Capture with the new tool and save the snapshot outside any checkout/build directory that you
   will replace. For example, `cartograph snapshot --project /path/to/before --index-store
   /path/to/before-index --revision before-enum-change -o /path/to/evidence/before.json`.
3. At the changed revision, rebuild the same target/configuration scope, then run
   `cartograph impact Status --project /path/to/current --index-store /path/to/current-index
   --before /path/to/evidence/before.json --format json`. An added case or source-file selector
   can be used instead. Use `--format text` for a readable review.
4. Read `enumChangeReview.status`, `changes`, `candidates`, `issues`,
   `unresolvedDecisions`, uncapped counts and `truncated` together. An empty candidate array with
   partial/unavailable coverage is not a clean bill of health.

Analysis-snapshot version remains 2. Optional `snapshot.enumImpactFiles` carries inventories and
decision facts; older snapshots remain readable. Recapture a legacy baseline from its original
revision and compiler build if the inventory is missing. Do not substitute today's case list or
edit an old snapshot to make it appear complete. Current use-site evidence can be used with a
capable historical inventory; historical decision facts are not required for every current site.

Syntax cache schema 15 discards older cache documents automatically; the analyzer identity also
includes the tool version. No manual cache deletion is required for this migration. The first
analysis may reparse unchanged Swift files. That refresh does not rebuild an index, recreate a
baseline or make stale source fresh.

## Packaged and toolchain verification

The existing change-impact verification script uses paired real compiler builds, persists the
baseline with the supplied CLI, and checks JSON/text enum expansion results plus a no-addition
control. The larger corpus also preserves explicit partial coverage for its two Swift Testing
macro files; the gate verifies those exact issues instead of presenting partial coverage as clean.
Release verification runs that same script against the executable extracted from the
universal archive and compares this packaged guide with its source copy.

CI uses the newest Xcode available on its macOS runner. The exact compiler-bound `contains` and
negation identities are tested on that toolchain; this is not a multi-toolchain compatibility
matrix. Unknown identities remain unresolved rather than falling back to method spelling.
A universal archive contains arm64 and x86_64 slices; the host verification does not imply that
both slices were executed or that an incompatible `libIndexStore` can be loaded.

Publication is a separate step: the Release workflow validates the reviewed source SHA and
version, verifies the unpacked package, then creates/verifies the exact tag and publishes. Its
manual `tag`/`source_sha` dispatch is a real release operation, not a dry run. Existing tags and
historical benchmark records are not rewritten; `final_evidence: false` remains a limit on those
comparison claims.
