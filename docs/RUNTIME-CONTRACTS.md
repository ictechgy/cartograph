# Runtime discovery, collection and contracts

Available on the unreleased development branch. These contracts complement static compiler-index evidence;
they do not claim to discover every dependency created at runtime.

## Automatic discovery

`runtime discover` requires a current compiler index, not a contract file or an executable argument.
It joins exact Swift declaration locations and compiler API references with source names and
object-specific Interface Builder connections. Supported boundaries include class/protocol lookup,
selector creation/reference/invocation, target/action and timer registration, and NotificationCenter
observer/post relationships. Creating a selector only produces `lookupOnly`. It does not add a call.
Compiler-confirmed NotificationCenter publisher construction is a `notificationSubscription`
boundary. A known name and center yield `lookupOnly` until the compiler also confirms a supported
`sink` or `onReceive` consumer. Direct `NotificationCenter.notifications` becomes a subscription only
when the compiler also records the `for await` iterator and `next` operations. Confirmed consumers record
a static subscription site; a compatible post can depend on its enclosing declaration. These are
potential dependencies, not observed callback execution. Custom consumers, bare publishers and bare
async sequences do not gain callback edges.

Notification names can use literal values, immutable local declarations, or a bounded intrinsic table
whose exact compiler USRs are backed by installed Foundation, AppKit, UIKit or AVFoundation declarations.
The table also canonicalizes specific `_alwaysEmitIntoClient` AVFoundation compatibility properties to
the SDK constants that their checked Swift interface returns. It does not accept a member because its
spelling looks like an SDK notification. Names passed through an unsupported collection or loop variable
remain unresolved.

The default center and `NSWorkspace.shared.notificationCenter` are stable only after their exact compiler
references are confirmed. A locally constructed `NotificationCenter` or nonnil object filter is matched
only when both boundaries use the same immutable class construction in one straight-line lexical scope.
Registration must precede posting for those fresh local identities. Property and parameter USRs do not
prove that two calls received the same instance. A nil observer filter remains a wildcard on a proven
stable center.
A directly bound observer token or immutable alias followed by exact system `removeObserver` on the
same center removes that registration from a later post on the same definite path. Removal and posting
inside one branch are supported. A `defer` takes effect only after its plain `do` scope exits; a
function-scope `defer` does not cancel a post before function return. Direct exact
`AnyCancellable.cancel()` similarly ends a proven publisher subscription. Mutable or reassigned tokens,
uncertain branch merges, other centers, custom cancellation and unsupported token storage leave the
potential relationship visible. The optional `notificationRemovalReferences` and
`notificationCancellationReferences` fields preserve the exact compiler locations used for this check.

Manual Core Data `.xcdatamodel/contents` entities produce `coreDataEntityClass` resource relationships
only to uniquely indexed Swift `NSManagedObject` subclasses, including proven indirect subclasses.
For `.xcdatamodeld`, `.xccurrentversion` is required even when filtering leaves one model contents file.
Only a regular, non-symlink marker of at most 64 KiB containing a binary plist or UTF-8 XML plist is read.
A missing, excluded, nonexistent, invalid or traversal-like selection remains unresolved without fallback;
standalone `.xcdatamodel` needs no marker. Inactive versions stay visible as migration review evidence
instead of silently becoming active class links. `category` property generation can connect to an existing class
only when its Swift name and Objective-C runtime name both agree with the model. Generated classes,
`customClass` fallback, unsupported `manual` strings, duplicate entity names, ambiguous modules,
placeholders and missing/non-managed classes remain unresolved. Malformed XML and DTDs produce no
partial relationships. Entity-name fetch strings alone are not joined.

Model contents and `.xccurrentversion` are runtime resources for invalidation and impact selection.
Adding, changing or deleting either changes session and trace input fingerprints. Snapshot v2 preserves
and rebases them, and both `impact --file` and `impact --since` select the class from the active version.
Historical comparison keeps the before/current selections separate when the marker changes.

Class-generated entities require a `coredata-build-evidence` v1 document made by
`runtime prepare-coredata`. It fingerprints the source model container, selected contents,
`.xccurrentversion`, main-bundle compiled model, bundle, main executable and exact generated Swift files.
Each `CoreDataDeclaredGeneratedMapping` records `entityName`, the source artifact, `module`, current
`declarationUSRs` and `linkedBinarySymbols`. The generated class must have current compiler references,
the expected superclass, no conflicting USR/runtime name, and Swift metadata symbols that `/usr/bin/nm`
finds as definitions in the main executable. A class supplied only by a dynamically loaded framework is
unsupported without explicit
link-chain evidence.

With that opt-in context, `coreDataContainer` binds literal local `NSPersistentContainer(name:)` to the
verified main-bundle model. `coreDataFetch` additionally requires immutable local `viewContext` and
literal `NSFetchRequest<NSManagedObject>` bindings plus exact compiler calls. A default fetch includes
verified subentities from the model hierarchy. Escaped or mutated request/entity/context state remains
unknown. Boundary evidence uses the optional `coreDataModelName`, `coreDataSuperentityName`,
`coreDataContainerLocation`, `coreDataContextLocation`, `coreDataRequestLocation` and
`coreDataResultTypeLocation` fields; a repeated entity string alone is never identity.

The evidence can augment current-build `runtime discover`, `impact` and `snapshot`. It cannot be combined
with `--trace`, does not change default `query`/`dead`, and snapshots preserve verified generated source
facts and freshness for historical comparison. `serve --coredata-build-evidence <project-contained.json>`
fixes one path for MCP runtime/impact tools. A client request cannot replace it, and
`coreDataBuildEvidence` metadata is emitted separately from the base session.

Direct literal KVC keys produce `keyValueRead`/`keyValueWrite` links only for a uniquely indexed final
NSObject subclass and an explicit `@objc` instance property. Dotted paths use separate
`keyPathRead`/`keyPathWrite` operation kinds and the optional `keyPaths` field. Up to 16 segments resolve
all-or-nothing. Every intermediate needs an exact `valueTypeLocation` compiler reference to the annotated
final NSObject type; only the final write segment needs a setter. All target properties are dependencies
of the path operation, so an intermediate target in a write result is not a setter-execution claim.
Alternate accessors, KVC/key-path overrides, inferred/generic/array intermediates, non-final receivers,
dynamic paths and same-named custom APIs remain unresolved.

Inline or immutable-local `NSPredicate(format:)` evaluation reuses the read-path resolver only when the
limited parser consumes the complete format. Literal variadic arguments and literal `argumentArray` are
accepted; `%K` must receive a literal string at that exact argument position and `%@` values never become
keys. The evaluated root must be typed, and compiler references must confirm both the supported predicate
constructor and `evaluate(with:)`. The parser never executes the format. Collection operators,
`SUBQUERY`, functions, mutable predicates and dynamic formats remain review inputs.

Immutable standard Swift Dictionary factory/router registries use `registryEntry`, `registryLookup` and
`registryAlias`. Only literal string keys with named top-level function values are supported; immutable
aliases can preserve the declaration identity. `registryDeclarationLocation` and
`registryReferenceLocation` are checked against the exact declaration/lookup, while
`referencedTargetLocation` anchors the named function value. The resolver also requires the installed
toolchain's standard `Swift.Dictionary` subscript USR. This is not a general DI or plugin registry rule:
closures, instance methods, mutable/dynamic maps, duplicate keys, custom dictionary conformances and
external frameworks remain unresolved.

The compiler must identify the expected API, including interpreted name constructors and string
concatenation. A same-named user implementation cannot supply a trusted runtime name. Conditional
compilation, mutable names, unknown receivers and unindexed local functions stay unresolved rather
than choosing the last source declaration or the closest symbol. Unsupported notification buses,
mutable aliases, parameter/property instance identities and incompatible object filters remain candidates.
The scanner keeps these responsibilities separate: `RuntimeSourceBindings.swift` owns lexical binding
and shadowing, `RuntimeSyntaxNames.swift` owns syntax/name recognition, and
`RuntimeNotificationLifecycle.swift` owns notification token state. This split preserves behavior while
keeping name parsing from silently acquiring lifecycle or binding authority.

The JSON `runtime-discovery` v1 document gives every recognized boundary a status, with full counts
and bounded findings/targets/candidates. `needsReview` is an analysis result; `--strict` makes unresolved
boundaries fail the CLI. `shadowed` means a known non-system call, while `unindexed` means no adequate
compiler identity exists. The Swift index omits some local-function references, so both are valid
non-connecting outcomes for a local same-named function.

Automatic relationships augment `impact` with origin `automatic` and relationship `automaticRuntime`.
They do not mutate the ordinary graph or change `dead`/`query` retention. Artifact selections can seed
the Swift declarations referenced by an XIB/storyboard or Core Data model. A verified generated-source
context is opt-in and stays separate from the base query session. Snapshot v2 preserves raw runtime facts,
compiler anchors, generated-source facts and captured freshness; v1 remains readable with an explicit
missing-evidence limit.

`Scripts/verify-runtime-discovery.py` checks an independently labelled compiler corpus with 59 supported
positive relationships plus negative classifications and real Foundation/AppKit/Combine execution.
`Scripts/verify-runtime-keypaths.py` checks 12 KVC/predicate property relationships, and
`Scripts/verify-runtime-registry.py` checks 7 immutable Dictionary relationships. These are three separate
bounded regression sets and cannot be combined into one universal completeness percentage. Separately,
`Scripts/verify-coredata-versions.py` compares `.xccurrentversion` selection with `momc`, loads the compiled
model in a real executable, checks category generation and snapshot/history/`--since` behavior, and
verifies that Cartograph leaves invalid selections, unsupported `manual` values, `customClass` fallback
and generated-name collisions unresolved. The negative `momc` invocation's exit code and output artifact
are recorded separately from Cartograph's conservative result; its diagnostic text is not a product contract.
`Scripts/verify-coredata-build-evidence.py` generates and compiles a class model, loads/fetches it through
Core Data, checks main-executable symbols, the CLI/MCP fixed-path flow, snapshots and current-build impact,
and rejects changed artifacts, foreign symlinks, ambiguous models and missing generated definitions.

## Automatic execution collection

```bash
cartograph runtime collect --executable <macOS-debug-executable> --output /tmp/runtime-trace.json -- <arguments>
cartograph runtime discover --trace /tmp/runtime-trace.json --executable <macOS-debug-executable>
cartograph impact <name-or-USR> --trace /tmp/runtime-trace.json --executable <macOS-debug-executable> --format json
```

Collection compiles the embedded native collector with local Clang, launches the specified executable,
and records supported Foundation/Objective-C APIs. It does not build the application, modify its code
signature or change entitlements. Hardened apps can refuse injection. Physical iOS devices are not
supported. The read-only MCP tools do not expose application execution.

For an already installed iOS 15+ Simulator debug test app, add `--simulator <booted-device-UUID>` and
`--bundle-id <app-bundle-id>`. Keep `--executable` pointing to the matching build's executable.
The command neither boots devices nor installs apps; it refuses an already running app and checks
installed executable bytes before and after collection. Its temporary collector and logs live in a
private directory inside that app's data container. A leftover launched process is terminated only
when its current bundle PID matches the collected process identity.

Default Simulator exit mode requires a dedicated scenario harness that calls `exit(0)` on success.
`simctl launch --console` can return zero even when the app crashes, so the collector separately records
the app's explicit exit code and normal shutdown. Missing either is a partial trace: force-closing an
interactive app and `_exit(0)` do not establish completion. `exit(7)` remains failure even when simctl
returns zero. The UIKit corpus verifies these cases on an actual simulator, including timeout while
the app ignores SIGTERM. Physical devices remain unsupported.

For interactive debug apps on macOS or Simulator, use `--duration <seconds>` (at least one millisecond,
shorter than `--timeout`). The interval starts after a matching active collector/PID handshake. A private
request asks the collector to seal its event log; a nonce/PID-bound immutable acknowledgement records
event counts and elapsed time. Writes and sealing use the same lock, so late or in-flight callbacks that
return after sealing cannot append to that prefix. The controller then stops the process it launched.

This mode emits `runtime-trace` **v2**: `collectionComplete` remains false, `evidenceComplete` states
whether the observation window is usable, and `observationWindow` records requested/elapsed milliseconds,
sealed event count and process cleanup outcome. Application/scenario success is not verified, even when
the tool terminates the process successfully. Early exit, missing/foreign/corrupt acknowledgement,
overflow, truncated values, wrong hooks/counts/PID, failed cleanup or changed inputs prevent complete
evidence. v1 keeps its original process-exit meaning. The reader and public Core completeness query
validate structural consistency instead of trusting an isolated completion flag.

The `runtime-trace` v1 document carries input and executable fingerprints, a collector handshake,
process exit status, bounded events and completeness information. Child-process events are excluded.
The optional `launch` object records platform, process ID, and Simulator UUID/bundle ID. Older v1
documents without this metadata remain readable. Existing DYLD injection libraries are rejected:
another interposer can hide supported calls without causing the Objective-C hook handshake to fail.
Timeout, app failure, missing injection, corrupt/dropped events or changed inputs leave a partial
trace and exit 2. Program stdout/stderr are forwarded to stderr and are not stored as trace payloads.
The collector forwards method return values without adding ARC retain/release operations; void and
primitive-return selector calls are tested as well as object-return calls.

Events distinguish `lookup`, `registration` and `invocation-returned`. A successful selector lookup
only creates a token. Registration confirms that the registration call returned, not that a callback
ran. Exact local caller/callee symbol identities are preferred; unknown, ambiguous and external
identities remain visible. Name/receiver matching does not fall back to nearest source lines.
If the receiver class or method implementation changes across a selector call, or a stable method
identity cannot be obtained, `dispatchUncertain` prevents a post-call replacement from being reported
as the implementation that ran. This does not claim to detect every concurrent runtime mutation.

With `--trace`, discovery returns `runtime-discovery-comparison` with separate `staticDiscovery` and
`observed` sections. Incomplete or stale traces produce no observed graph connections. `impact`
identifies observed relationships separately and retains their kind (lookup, registration or invocation).
Trace impact cannot be combined with historical `--before`, since their evidence can describe different
builds. Unexecuted paths and APIs outside the collector hooks remain unknown.

The collector currently covers `NSClassFromString`, `NSProtocolFromString`, `NSSelectorFromString`,
three `performSelector` variants (instance and class receivers), and selector-based NotificationCenter
registration. It does not automatically recover arbitrary closures, custom DI containers, Core Data
models, URL routers, plugin registries, Combine streams, KVC or predicate semantics. Some of those
source patterns are counted as limitations. Keep using the existing bridge/isthmus workflow for
cross-language callers; this feature does not infer every Dart/JavaScript caller from Swift alone.

## Explicit scenario assertions

The workflow separates what should happen from what an application test reports happened. The
plan/check commands require a built executable so the plan is tied to the binary that the scenarios
actually exercise:

1. Declare a dynamic dependency with a stable ID, a target declaration, an optional local source
   declaration, its mechanism and the scenarios that must exercise it. An expected result value
   is optional. Use an exact USR when a name is ambiguous.
2. Build the application and prepare a plan with `runtime plan --contracts <path> --executable <path> --strict`.
   The plan resolves declarations and binds the contract to the project's source/index/configuration
   fingerprint, the loaded graph fingerprint and the executable's raw SHA-256 fingerprint. It also
   records source/index-unit freshness for each binding.
3. Run application tests or instrumentation and record an observation for each required scenario,
   carrying that plan fingerprint and the observed executable fingerprint. Record failure explicitly.
   Cartograph never executes commands supplied in a contract or observation document.
4. Check the observations with `runtime check --contracts <path> --observations <path> --executable <path> --strict`.
   Missing or ambiguous declarations, failed observations, wrong values, missing required scenarios,
   source/index freshness problems and stale plans remain distinct results. A changed executable,
   source, index or contract rejects the old observation as current evidence.

The observation producer is identified in the report. These are supplied execution claims, not
cryptographic attestation, and Cartograph does not discover all runtime dependencies. An unobserved
contract is unverified; it is never evidence that code is unused or safe to delete. Coverage applies
only to the listed scenarios and the built configuration.

```json
{
  "format": "runtime-contracts",
  "version": 1,
  "contracts": [
    {
      "id": "settings.route",
      "source": "Router.openSettings",
      "target": "SettingsController.open",
      "mechanism": "selector",
      "requiredScenarios": ["open-settings"],
      "expectedValue": "opened"
    }
  ]
}
```

## Observation producer

Application tests record observations after exercising the real lookup, registration or callback.
This is the document shape; replace both fingerprint placeholders with the prepared plan and the
raw SHA-256 of the executable actually tested. Generate `observed` only when the scenario really
succeeded; use `failed` for an attempted call that failed. A missing record remains unobserved.

```json
{
  "format": "runtime-observations",
  "version": 1,
  "planFingerprint": "<64 hex characters from the pre-scenario plan>",
  "executableFingerprint": "<64 hex characters from the actual tested executable>",
  "producer": "MyAppIntegrationTests",
  "observations": [
    {
      "contract": "settings.route",
      "scenario": "open-settings",
      "outcome": "observed",
      "value": "opened"
    }
  ]
}
```

The [Foundation producer fixture](../Fixtures/RuntimeContractCorpus/Sources/RuntimeProbe/main.swift)
shows real selector/class lookup, explicit failure recording and executable hashing. Its
[verification script](../Scripts/verify-runtime-contracts.py) runs the complete plan → execute →
check sequence. Labels are at most 256 UTF-8 bytes, symbols and values 4096 bytes; empty values are
allowed. Contract IDs and required scenarios must be unique within their documented scopes.
File inputs are limited to 2 MiB, 1000 contracts, 100 required scenarios per contract and 10,000
observations. Expected and observed values are compared but are not echoed in the report.

## Executable acceptance coverage

- Real Foundation selector/class lookup succeeds and its observation validates.
- Changing the runtime registration/selector string preserves compilation but fails execution;
  the recorded failure fails the contract check.
- A required scenario not exercised remains unverified, including empty observation lists.
- A changed source, index or contract invalidates a previous observation plan.
- Invalid, ambiguous and removed source/target declarations do not silently become graph edges.
- Validated declared runtime relationships appear in impact reports with provenance;
  they remain distinguishable from compiler-recorded direct calls.

The implementation now exposes `RuntimeContract`, `RuntimeObservation`, `RuntimePlanDocument` and
`RuntimeCheckDocument` through CartographKit. `runtime plan` and `runtime check` both require
`--executable`; observations carry a raw SHA-256 `executableFingerprint`, and the plan records the
final input/graph fingerprints and binding freshness. `Scripts/verify-runtime-contracts.py` builds
and executes `Fixtures/RuntimeContractCorpus` with real Foundation selector and class lookup. It
checks successful execution, a selector spelling change that still compiles but fails at runtime,
empty observations, old plans, old binaries with copied plan IDs, and a removed target. These are
synthetic regression scenarios; teams must supply observations from their own application tests.

`selector` requires Objective-C exposure evidence: Swift `dynamic`, dynamic replacement, and
dynamic member lookup alone do not create an Objective-C selector. `classLookup` requires a class;
Swift classes can also be found by qualified runtime name. The observation producer must exercise
the actual string lookup or registration; resolving the target in a plan does not prove that call.

`impact --runtime-contracts` adds declared relationships for that invocation. It does not consume
observations, claim execution, or add retention roots to `dead`/`query`. A current contract that
still requires a deleted target remains incomplete even when `impact --before` can resolve the
selected declaration in the historical snapshot. Update the contract only when its requirement
has actually changed, then rebuild and rerun the relevant scenarios.
