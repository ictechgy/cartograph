# Enum expansion review

The existing `impact --before <snapshot>` comparison includes an additive
`enumChangeReview` section in JSON and text. Select the changed enum, an added
case, or its source file with the existing impact selectors. Ordinary graph
impact and exit-status behavior are unchanged.

Capture a baseline with this version before adding enum cases, then rebuild the
current index and compare it with that baseline. Older snapshots still decode,
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
subject expressions. Unsupported decision evidence and missing coverage are
shown explicitly. A default-only switch without sufficient arm evidence is
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
