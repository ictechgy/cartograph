# Recursive call corpus

The default architecture graph projection deliberately filters self-loops. This
feature adds explicit `graph --level symbol --include-self-loops` export while
preserving that default contract. This dependency-free SwiftPM executable checks
that the opt-in export retains compiler evidence for source-authored recursive
calls. It is an original, reduced fixture, not a copy of upstream code.

## Provenance

The native audit of Swift Argument Parser 1.8.2, pinned to
[`6a52f3251125d74daf04fcbd5e6f08a75d074382`](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382),
exported 11 of 13 independently identified authored call edges. This mismatch
was against a complete authored-call oracle, not a promise that the default
architecture diagram included recursion. The two missing edges were recursive:

- [`MessageInfo.init(error:type:)`](https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/Sources/ArgumentParser/Usage/MessageInfo.swift#L17),
  declared at 17:3, with self-call sites on lines 56 and 70.
- [`UsageGenerator.makeErrorMessage`](https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/Sources/ArgumentParser/Usage/UsageGenerator.swift#L180),
  declared at 180:8, with a self-call site on line 229.

The fixture preserves the enum-initializer delegation shape with two distinct
occurrences and an instance-method recursive call. `unusedRecursion(_:)` adds the
opposite-direction safety case: calling itself must not make an otherwise
unreachable function reachable. The ordinary `main` → `renderMessage` →
`formatMessage` caller chain distinguishes direct and transitive consumers and
must never acquire a self-loop.

## Independent expectations

[`expected-calls.json`](expected-calls.json) enumerates declarations and authored
call sites from the source, with explicit 1-based UTF-8 locations. It is not a
snapshot of Cartograph output and the verifier has no update-golden mode. Review
source edits and expectation edits together; never regenerate the oracle from the
implementation under test.

There are eight authored in-project call occurrences and seven distinct call
edges. Four occurrences form three self-call edges, including both initializer
sites. The enum-case assignment is a reference, not a function call. Calls to
Swift standard-library declarations are outside this project graph.

The compiler-backed verifier checks:

- Default symbol JSON and evidence omit all loops; opt-in JSON contains exactly
  the three expected self-call edges and all four recursive occurrence sites.
- All authored call edges, weights, and occurrence locations match in both
  directions, so extra edges and missing edges both fail.
- Non-self edges, nodes, default DOT/Mermaid diagrams, and module/file/type
  rollups retain their loop-free behavior. The flag requires explicit symbol
  level; missing level and each other level fail with usage exit 64.
- Call-only direct and transitive queries exclude their seed, reject unexpected
  callers, preserve authored caller depths, and terminate. Reachability is checked
  separately using the default graph so the `@main` containment rule remains
  active. Cycles remain empty at module, type, and symbol levels.
- The complete unused-symbol list contains only `unusedRecursion(_:)`; impact
  excludes its seed and preserves the expected caller chain without truncation.
- The executable runs to completion, exercising both initializer branches and
  method recursion.

## Run

Build Cartograph on its supported native macOS environment, then pass that exact
executable instead of relying on an old release binary:

```sh
swift build
python3 Scripts/verify-recursive-calls.py --cartograph .build/debug/cartograph
```

`--output-dir <directory>` must name a new or empty directory; logs and summaries
from prior runs are never overwritten. Every run creates a
new fixture copy and a new `swift build --scratch-path` directory. The verifier
finds a populated compiler index in the resulting backend layout (`out` or the
SwiftPM binary directory's `index/store`); it never assumes that
`-Xswiftc -index-store-path` was honored. `SWIFTPM_FLAGS` or `--swiftpm-flags` can
supply environment-specific SwiftPM cache/config/security paths.

The fixture itself also compiles and runs with Linux Swift, but that alone does
not verify Cartograph's native index-reader or CLI behavior. A verifier pass is
reported only after every real CLI assertion succeeds. To demonstrate the
regression, rebuild the product with self-call collection disabled and rerun the
same command: the exact opt-in call-edge comparison must fail. Discarding just
one initializer occurrence must fail the weight or evidence comparison. Restore
and rebuild the product before using that binary for any subsequent validation.
