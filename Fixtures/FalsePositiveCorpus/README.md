# False-positive corpus

Patterns that produced false positives in real code, kept as a fixture that actually compiles.

`LocalFunctions.swift` reproduces Kingfisher's omitted named-local consumer: an outer function
uses a handler, which uses a local consumer, which calls the target. The CLI harness requires
that exact depth-1/2/3 chain. The previous binary fails by returning only the outer function
at depth 1. Whole dead-code lists must remain unchanged, so attribution cannot break liveness.

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

## Retention.swift — both directions in one file

The other files here are false positives: shapes that must **not** be reported. `Retention.swift`
holds both directions, because the rules it exercises were narrowed rather than widened and a
narrower rule fails silently — the corpus keeps passing while the tool stops reporting something.

Reported on purpose: a `View` nobody draws (HealthMap had five, including `CourseTag` and
`CourseThumbnail`), the same shape written as `extension X: View` so the two spellings cannot drift
apart, an `Equatable` enum nobody constructs (HealthMap's `HealthMapListSectionState`, whose four
cases used to be reported one by one while the enum itself was not), and a struct kept alive only by
its synthesized memberwise initializer (`NotificationPreferencesController`).

Retained on purpose, in the same file: a view used only inside another view's body, a struct built
only through its memberwise initializer, and a type used only as an enum case's associated value.
The users live in `exerciseRetentionShapes()` inside the module rather than in `main.swift`, because
a synthesized initializer is internal and giving these types an explicit `public init` would delete
the very shape the case exists to test.

The Objective-C `ObjCCameraPlugin` in `RNCalendar.m` combines the file-local immutable channel
constant from [share_plus at 13e1704](https://github.com/fluttercommunity/plus_plugins/blob/13e1704/packages/share_plus/share_plus/ios/share_plus/Sources/share_plus/FPPSharePlusPlugin.m)
and the direct registrar/delegate shape from package_info_plus at the same revision. It is a
small handwritten fixture, not copied plugin implementation. Its registration and `nativePhoto`
branch must be exported with `sourceLanguage: objective-c` and no fabricated Swift symbol. The
header only supplies types so the Objective-C compiler can index the shape without Flutter SDK.
The Swift dead-code lists must remain identical because this declaration is outside that graph.
## Conformance typealiases

`AliasConformance.swift` reproduces Kingfisher's macOS
`KFCrossPlatformViewRepresentable` conformance alias (revision
`ab1c1de54a1ce1adfe1733c7195056a153029d3a`, `KFAnimatedImage.swift:77,85`).
The compiler emits a relationless explicit alias reference and a co-located
implicit protocol/baseOf occurrence. `LivePlatformViewAlias` must stay reachable;
`UnusedPlatformViewAlias` must remain reportable. A nearest-type fallback is not
valid evidence for this connection.

## Dispatch and public contracts

`StaticExtensionDispatch.swift` covers the over-retained protocol/generic extension helpers found
in Alamofire (`Protected.swift`, `OfflineRetrier.swift`) and Swift Argument Parser
(`HelpGenerator.swift`, `SequenceExtensions.swift`). Called helpers, explicit Swift `dynamic`,
and dynamic replacements must survive; uncalled ordinary helpers must be reported.

`ProtocolDispatch.swift` pairs the unused-requirement shapes from Kingfisher's
`DisplayLinkCompatible.timestamp` and Argument Parser's `ArgumentSetProvider._visibility` with
live existential/generic calls, inherited protocol defaults, class overrides, and an external
`Array: Identifiable` witness. Its two unused `run()` declarations are distinct USRs, so the
expected message lists intentionally contain that line twice.

`InheritedAccess.swift` preserves public protocol requirements and public extension APIs under
`--retain-public`, matching the public `AlamofireExtended`, `DataResponseSerializerProtocol`, and
Kingfisher `CallbackOperationQueue` contracts. The host is instantiated, but its extension APIs
are deliberately uncalled: default analysis reports them, while public retention keeps them.
The explicit public member inside a private extension intentionally produces a compiler warning;
its access remains public and was also checked from a separately compiled client.

Removing receiver-as-caller edges makes the uninstantiated Flutter channel stub reportable as a
type instead of separate initializer/method findings. The registrar protocol is used only by an
unreached registration method unless public APIs are retained. External bridge roots still keep
the actual channel/handler paths they identify.

## Ignore comments — both judgements

`IgnoreComments.swift` and `FileIgnored.swift` pin the two verdicts a `cartograph:ignore`
comment can get, matching Periphery 3.7's superfluous-ignore detection. `IgnoredButUsed` is
called by `exerciseIgnoreCommentShapes()` (itself reachable from `main.swift`), so its comment
suppresses nothing and must be reported. `IgnoredAndDead` is genuinely unreachable, so its
comment is doing real work: it must neither be reported as superfluous nor let the declaration
surface in `expected-unused.txt`. `FileIgnored.swift` carries `cartograph:ignore:all` over a
file whose only declaration is used, producing one file-scope diagnostic instead of one per
declaration. The full list lives in `expected-superfluous-ignore.txt`.
