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
| `Bridges.swift` | a Flutter method-call handler that only Dart invokes | the handler's type, until `--external-retentions` supplies the caller |
| `Bridges.swift` | the standard `FlutterPlugin` shape: `addMethodCallDelegate(instance, channel:)` plus `handle(_:result:)` | the handler method; the registration call names the channel without guessing, and the retention round-trips by the method's real USR |
| `Bridges.swift` | a handler passed as a method reference, `setMethodCallHandler(handleCall)` (audioplayers) | the arms of that method had no channel |
| `CorpusObjC/RNCalendar.m` | an Objective-C source with React Native export macros | not analysed; counted in `limitations` as `objective-c-sources` and read textually by `bridges` |

`expected-bridges.json` is the `bridges` output with the generation time, tool version and project
path replaced by placeholders; it pins that the literal found by syntax gets the USR the compiler
actually wrote. `external-retentions.json` is the file isthmus would hand back for that handler, and
`expected-unused-with-retentions.txt` is the report once it is applied. The script also checks that
the two reports differ — a retentions file that changes nothing has silently failed.

`lib/camera.dart` is not part of the SwiftPM build. It gives dartograph a real caller under the same
project root, so isthmus can run both producers and return retention evidence without rewriting
either document's `project` field.

Objective-C is not compiled into the graph. The `CorpusObjC` target exists so that the
`objective-c-sources` limitation is verified against a real `.m` file rather than a hand-built
snapshot. Every iOS project on the maintainer's desk was pure Swift, so this was the only place to
check it.

`expected-unused.txt` lists what *should* be reported. `verify-fixtures.sh` also runs with
`--retain-public` and compares against `expected-retain-public.txt`: every declaration a consumer
could reach is `public`, so any declaration whose syntax facts failed to attach would lose that
`public` and surface as a new line. What remains in that file is declared `private` on purpose, or
is internal and reached from a public entry point (`Bridges.swift`).
