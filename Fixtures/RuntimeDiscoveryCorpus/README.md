# Runtime discovery compiler corpus

This macOS-only Swift package measures automatic runtime dependency discovery against a real
compiler index. The expected relationships in `ground-truth.json` come from the source-level
Objective-C and Foundation behavior, not from Cartograph output.

The corpus covers Objective-C class aliases, module-qualified Swift classes, protocol lookup,
literal and immutable name construction, selector tokens, `#selector`, `perform`, typed and
constructed receivers, inheritance and overrides, timer registration, notification observers,
compiler-confirmed publisher consumers and posts, object-filter counterexamples, Interface Builder actions and
outlets, exact SDK notification constants, `NSWorkspace.shared.notificationCenter`, same-scope immutable
notification center and object identities, direct `for await` notification sequences, Core Data model classes,
shadowed APIs, unsupported wrappers, and
declarations that cannot be exposed to Objective-C. Direct KVC keys cover an explicit `@objc`
property on a final `NSObject` class; getter variants, overrides, writes to `let`, key paths,
non-final receivers and user-defined lookalike APIs are negative cases. Explicit Objective-C getter
aliases, higher-priority getter properties, and getter-only computed properties also prevent a
direct property write/read claim.

`Scripts/verify-runtime-discovery.py` builds this package in a fresh scratch directory. It reports
TP, FP, and FN relationships using labelled `(source, target, kind)` tuples. Resolved and
already-indexed targets count as relationships. Review classifications and silent negative cases
are checked separately. The gate requires 100% precision and at least 95% recall for the declared
supported-positive set. The current bounded set contains 59 positive relationships; that number is not
a claim of universal runtime coverage.

Malformed Core Data XML, generated entities, missing classes and ambiguous model versions are checked as
negative classifications rather than successful relationships. The unsupported set is deliberately outside the recall denominator. It records gaps instead of
turning them into successful absences. Current examples include key-value reflection and custom
selector registries. Common patterns not claimed by this corpus include predicate format strings,
Combine operators after publisher construction, dependency-injection containers, Core Data fetch names without
model evidence, state
restoration identifiers, URL routing, and framework-specific plugin registries.

The script also verifies a stale source against its old index, then builds a separate post-change
index after deleting one selector target and renaming another. The v2 snapshot comparison must
retain the historical automatic runtime evidence without reading the edited current source as
historical metadata.

The built corpus executable runs the supported KVC read and write and requires
`kvc=before->after`. It also verifies that Objective-C method and property selectors named
`getTitle` win KVC reads, so both positive and negative dispatch assumptions are checked against
Foundation behavior. Notification execution verifies default and workspace centers, SDK constant
identity, and a local custom center with matching and nonmatching object filters.
It also runs a fresh local center twice after removing a directly bound observer token and requires
zero callbacks. Immutable token aliases, removal and posting in the same branch, and a `defer` whose
plain `do` scope has already exited are modeled. Mutable/reassigned tokens, uncertain branch merges,
function-scope `defer`, other centers and unsupported token storage remain potential relationships.
Direct immutable `AnyCancellable.cancel()` is checked with real Combine execution; mutable or
branch-only cancellation stays conservative. A compiler-confirmed `for await` is an async subscription
site, while bare sequences and same-named custom APIs do not become notification connections.
