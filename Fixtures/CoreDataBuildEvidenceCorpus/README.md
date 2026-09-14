# Core Data build-evidence corpus

`Scripts/verify-coredata-build-evidence.py` uses the local Xcode SDK to generate Swift from the V2
model, compile a real `.momd`, build a small `.app`, and run `NSPersistentContainer(name: "Store")`
from its main bundle. It extracts the generated class USR from the compiler symbol graph, then asks
`CoreDataBuildEvidenceStore` to bind that declared mapping to the executable, source model and bundle
resource hashes.

The executable also fetches the same entity through two contexts. One is an immutable local
`NSPersistentContainer(name:)` → `viewContext` chain and becomes a source-to-class dependency when the
evidence is supplied. The other context crosses a function parameter and remains unresolved even though
the fixture executes it successfully. This keeps interprocedural context identity outside the supported
claim instead of joining on the repeated entity string.

The negative cases change the generated source and executable after evidence creation, put both
`Store.mom` and `Store.momd` in the main bundle, replace the selected source version without rebuilding,
point the compiled model through a symlink outside the bundle, and supply an app executable that does
not define the generated class. Every case must fail closed. The main-executable witness requires its
defined Swift metadata/descriptor symbols and, for an Objective-C alias, the Objective-C class symbol.
Classes supplied only by a dynamically loaded framework remain unsupported without explicit link-chain
evidence. A linked symbol proves declaration presence in that executable, not successful application behavior. The
mapping is still only declared evidence: the analysis layer must independently prove that its file,
module, USR, freshness and generated class shape agree with the current compiler index.
Manual/category models prepare without generated sources; class-generated entities require one exact
generated class file and module each.

This corpus is synthetic because the three locally inspected applications do not contain Core Data
models. It validates the Xcode 27 beta `momc`, Core Data runtime and compiler behavior without launching
an arbitrary application, using signing material, or scanning DerivedData.
