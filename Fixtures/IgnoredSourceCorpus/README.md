# Ignored-source corpus

Teams often keep generated code (R.swift, SwiftGen, Sourcery) in `.gitignore` and generate it during
the build. Source discovery drops Git-ignored files, so declarations used only by that code lost their
callers and were reported as unreachable. Cartograph now reads the ignored files that the compiler
indexed separately and retains the declarations they use as `ignoredSourceReference`. Unit tests check
this on hand-built snapshots. This corpus checks it on a real compiler index, in both directions.

An ignored file cannot be committed, and adding one to `FalsePositiveCorpus` would change the
`limitations` in its frozen JSON expectations. So this package lives on its own. The files it needs
are in `Templates/` as `.txt` files. `Scripts/verify-ignored-sources.py` copies the package, writes the
templates and an ignored link into the copy, runs `git init`, and checks that Git really ignores
exactly those paths. Then it builds a fresh index with `swift build --scratch-path` and runs the CLI.
`Scripts/verify-fixtures.sh` runs it after the false-positive corpus.

The package does not compile without the generated file. `Screen.title` reads
`GeneratedAccessors.screenTitle`, as app code reads `R`.

## Cases

| Source | Ignored file that uses it | Expected |
|---|---|---|
| `Helper.usedByGenerated()` | `GeneratedAccessors.swift`, compiled | retained, `ignoredSourceReference` |
| `Screen.fallbackTitle`, `Screen` | `GeneratedAccessors.swift` reads it by name | retained; `Screen.title`, which nobody reads, is reported |
| `AdoptedByGenerated` | `GeneratedConformer` conforms to it | retained, `ignoredSourceReference` |
| `ExtendedOnly` | only extended (`extends` is not a use) | reported |
| `Helper.usedOnlyByUncompiledCopy()` | `.claude/worktrees/copy/...`, not compiled, so no index records | reported |
| `Helper.usedOnlyByExcludedGenerated()` | `R.generated.swift`, compiled, but the default exclude `**/*.generated.swift` filters it | reported |
| `deadCaller()` → `DeadCallee.run()` | ignored link `Links/DeadChain.swift` to the tracked file | both reported; the link is not read again as an ignored source |
| `Helper.neverCalled()` | none | reported |

[`expected-unused.txt`](expected-unused.txt) is the complete `unused-symbol` list, written from the
source and not from Cartograph output. The verifier also checks these things:

- No finding and no graph node comes from an ignored file.
- There is no cycle at type or symbol level. The real code has one, `Screen` ↔ `GeneratedAccessors`.
- The `source-discovery-exclusions` limitation lists exactly the four ignored paths. It says that
  ignored sources are followed, and it counts the one ignored file outside the include/exclude scope.
- `query` gives the state and reason above for each declaration, and `dead --explain` names the
  ignored source.
- Control: on the same index, un-ignoring `GeneratedAccessors.swift` makes the type cycle and that
  file's own unused types (`GeneratedAccessors`, `GeneratedConformer`) appear. So the checks above are
  not empty.

## Provenance

The 2026-11-03 family review found the missing callers. The fix shipped in PR #237. In the third
review, a one-off Linux build confirmed it end to end: a helper called only from a Git-ignored
`Generated.swift` was retained, and an uncalled helper was still reported. That check was not
frozen. The default-exclude boundary is new here. R.swift writes `R.generated.swift` by default.
Under the default `exclude`, its uses were not followed, while the limitation said ignored sources
were followed.

## Run

```sh
swift build
python3 Scripts/verify-ignored-sources.py --cartograph .build/debug/cartograph
```

`--output-dir` must name a new or empty directory. `SWIFTPM_FLAGS` or `--swiftpm-flags` passes
environment-specific SwiftPM paths, as in `verify-recursive-calls.py`.

To see the verifier fail, make one of these changes, rebuild, and rerun:

- Make `IgnoredSourceReferences.targets(in:)` return an empty set. `Helper`, `Screen` and
  `AdoptedByGenerated` appear in the list (members of an unused type are folded into it).
- Return every ignored path from `untrackedSources`. `DeadCallee` disappears from the list.
- Drop the `pathFilter` from `ignoredSourceFiles`. `usedOnlyByExcludedGenerated()` disappears from
  the list.
- Count `extends` as a use. `ExtendedOnly` disappears from the list.
- Drop the outside-scope sentence from the limitation. The limitation check fails. A binary built from
  the commit before this corpus fails there and nowhere else.
