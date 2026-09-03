# False-positive corpus

Patterns that produced false positives in real code, kept as a fixture that actually compiles.

Unit tests run on hand-built snapshots, so they cannot check what the compiler really writes into
the index store. Every false positive found in this repository lived exactly there. `Scripts/verify-fixtures.sh`
builds this package and compares the whole finding list, in both directions: a new false positive
and a lost detection are equally a failure.

The package uses SwiftUI, deliberately. A hand-written property wrapper does **not** reproduce the
symbol shape that matters: the compiler emits `$name` as a separate implicit symbol only for
wrappers like `@State`, and that split is precisely what the false positive was about. The first
version of this fixture used a local wrapper and passed while the bug was reinstated — it proved
nothing. Building against SwiftUI measured at 7 seconds, so fidelity won.

| File | Pattern | Was reported as unused |
|---|---|---|
| `PropertyWrappers.swift` | a property read only through `$projected` | the wrapped property |
| `Accessors.swift` | calls inside a getter and a `willSet` | the callee |
| `Enums.swift` | a case consumed only through `allCases` | the case |
| `Names.swift` | `` `default` ``, `init?(rawValue:)` | analysed as internal, then unused |
| `Names.swift` | a local shadowing a member name | the member lost its facts |
| `Names.swift` | a generic parameter | reported as a dead type alias |
| `CorpusApp/main.swift` | top-level statements | the whole executable |

`expected-unused.txt` lists what *should* be reported. `verify-fixtures.sh` also runs with
`--retain-public`, where the list must be empty: every declaration here is `public`, so any
declaration whose syntax facts failed to attach would lose that `public` and surface.
