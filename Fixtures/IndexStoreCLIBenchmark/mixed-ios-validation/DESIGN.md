# Design and integration contract

## Boundary and intended result

This validation corpus prepares the mixed-iOS portion of `docs/evaluation/indexstore-final-protocol.md`. It cannot satisfy the final independent holdout requirement. Adapter work may use this source freely; after adapter freeze, reserve a separate, never-exposed source-authored mixed iOS fixture. A repair after observing that later final workload promotes it to validation and requires a new holdout. Do not reuse this fixture under a new directory name and call it independent.

There are three distinct claims:

1. **Compiler calls:** exact direct/transitive callers from source-declared callables, including static C/Objective-C/Objective-C++ and Swift calls, on the same completed compiler store. Cartograph is compared with the actual pinned upstream `index-dump` plus its explicitly named external assembler.
2. **Source/header freshness:** whether a reader warns/refuses when sources and header dependencies no longer match the accepted compiler state. Native `index-dump` has no such warning operation. Preserve its `unsupported` status and null precision/recall; test shared external hash validation separately and do not relabel that wrapper as native CLI functionality.
3. **Framework-aware affected tests:** XCTest invokes lifecycle methods even when no test body compiler-calls them. This requires a different source/framework oracle. A conservative test-class answer cannot be called a false positive against a compiler-call-only oracle. Native baseline affected-test selection is unsupported unless a separately specified external implementation is supplied.

## Fixture source and authored calls

BridgeKit includes:

- `Core.m`: `CGBase`, `CGAlternate`, `CGBridge`, and an unused C-function negative.
- `CppBridge.mm`: `cppHelper(int)` calling the C++ header helper; the same-named `cppHelper(long)` is a genuine overload negative. `CGCppBridge` calls only the int overload.
- `ObjCQuote.m`: a real Foundation `NSObject` subclass's `+[CGQuoteEngine quote:]` calls `CGBase`. `+[CGQuoteEngine isolated:]` is a negative. The header supplies a stable Swift import name for each method.
- `CGCore.h`: an Objective-C/C `CGHeaderRoute` and an Objective-C++ `CGHeaderCppRoute` in explicit language-conditional branches. Both initially call `CGBase`. The header-only semantic edit switches both to `CGAlternate` without changing any `.swift`, `.m`, or `.mm` bytes. The branches have distinct source names and declaration anchors; do not flatten the C++ branch into the Objective-C header function.
- A Clang module map and umbrella header import the public C and Objective-C declarations into Swift.

The same physical `Sources/Shared/SharedCalls.swift` is passed to `swiftc` twice, with module names FeatureAlpha and FeatureBeta. No copy or symlink creates a fake shared-source scenario. Its `QuoteSource` protocol extension calls `CGBridge`; `SharedQuote.quote(Int32)` calls the Objective-C class method; `quote(String)` is a negative for the integer route. `SharedQuote.run(Int32)` invokes the integer method and the protocol extension. A sibling method is unrelated.

AppFlow imports both real Swift modules. `checkout` reaches only FeatureAlpha and the Objective-C++ route; `checkoutBeta` reaches FeatureBeta. `overloadControl` invokes the string overload. `directC` calls the C function directly. `retiredRoute`, in its own file, calls `checkout` and is renamed, deleted, and restored during the lifecycle.

The oracle includes all in-scope source callables, including empty initializers and negative bodies. Its 23 edges include constructor calls in AppFlow. Standard-library integer operators and SDK methods such as NSObject machinery are outside the source universe; no path through external code is inferred. Each query excludes its seed, reports shortest reverse distance up to eight hops, and includes all other known source identities as explicit negatives. The ten seeds are fixed in order: CGBase, CGAlternate, the Objective-C/C header helper, CGCppBridge, the Objective-C quote method, FeatureAlpha's integer overload, FeatureBeta's integer overload, FeatureAlpha's protocol extension, FeatureAlpha's string overload, and checkout. The initial CGAlternate answer is deliberately empty.

The oracle is authored from source and explicit compiler-language branches, not from either product's answer set. A prototype raw-compiler diagnostic informed the choice to give the C and C++ helpers separate source declarations rather than require a many-USR source projection. That diagnostic is disclosed and does not make this an independent holdout. The final expected callers contain no learned USRs, output-derived edge exclusions, accepted false positives, or product-specific expected answer lists.

## Identity and adapter requirements

A source identity is `context::relative-path:one-based-line:one-based-UTF8-column`, with a full signature and exact source anchor recorded separately. Swift context is the compilation module. FeatureAlpha and FeatureBeta declarations at the same source path/line/column must remain distinct. A basename, display name, owner type, or physical source location alone is insufficient.

BridgeKit is the fixed source/build-target namespace for C-family callables; its external C declarations and definitions must join by compiler identity. Header declaration and Objective-C declaration anchors are listed as aliases for their actual implementation definition. Do not count a header declaration and its definition as two callables. Do not select the first same-named function, collapse Objective-C selectors onto class owners, treat `receivedBy` as a caller, or infer a protocol implementation edge for the explicitly declared extension call.

For `index-dump`:

- Invoke the exact pinned upstream executable; do not substitute an IndexStoreDB API shim.
- Preserve unit identity, module, main file, output path, provider, dependency type, and record provenance. Traverse current unit-to-record and unit-to-unit dependencies from the actual current build outputs, retaining every target context. A dictionary that discards all parent-unit context is insufficient for shared sources.
- Read `.m`, `.mm`, and relevant user header records as well as Swift. A `File` dependency can establish freshness even when no callable record exists.
- Resolve declarations separately from symbol-wide printed occurrence roles. The pinned dumper prints aggregated symbol roles on occurrences; source declaration anchors and compiler identity must distinguish calls from declarations.
- Construct only `calledBy` caller-to-callee edges. Keep unknown/ambiguous/unmapped in-universe identities as hard failures or explicit extra results; never filter them away using the oracle.
- Assemble and reverse-index once per accepted immutable index state, then reuse it for the ten queries. Cache unit/record dumps appropriately. Raw old records are retained by the compiler; do not enumerate arbitrary orphan record files as current input.

For Cartograph, retain the native symbol-level `call` graph and its own native batch answers, then independently map its compiler identities to the same source context contract. If the existing graph does not retain enough header, C++, module, or provenance information, record an unresolved coverage failure. The validation runner must not invent source edges to make it pass.

Both arms may use the same deterministic build manifest and source universe. The normalizer may use source declaration syntax and compile context, but cannot read `oracle.json` expected edges or caller lists to decide which observed nodes/edges to keep. The grader alone reads expected answers. Preserve native outputs, independent binding decisions, normalized answers, errors, and adapter hashes.

## Thirteen-state lifecycle

The physical Project path and physical IndexStore path stay constant. The runner never clears the store between builds, so old units and records remain available to expose stale-record bugs. Every build uses the same toolchain, SDK, target triple, and stable object/module output paths. The rebuild is an explicit full compiler rebuild, not an incremental-build performance claim.

1. Initial full build: `initial` exact caller oracle, no freshness warning.
2. Header-only semantic edit, no compilation: hash-different header; index fingerprint identical to step 1. Must be identified as stale before accepting a current-source answer.
3. Rebuild: `header_edit` oracle. Header-route callers move from CGBase to CGAlternate; unchanged Objective-C and Swift-direct calls to CGBase remain.
4. Rename CGCore.h to RenamedCore.h and update its four imports, no rebuild: header old/new paths and changed include sites must not be accepted as fresh.
5. Rebuild: `header_rename` oracle. New header source identities replace old-path identities; old record artifacts must not leak into current answers.
6. Delete RenamedCore.h without changing imports, no rebuild: missing dependency must be identified.
7. Attempt rebuild: must fail with the missing RenamedCore.h diagnostic. No compiler success or fresh-result score is possible. A timeout or unrelated compiler error is not accepted as this control.
8. Restore all original source bytes and rebuild: `initial` oracle again, stale warnings cleared only after a successful rebuild.
9. Rename Legacy.swift to Relocated.swift, no rebuild: stale/changed inventory, same index bytes.
10. Rebuild: `swift_rename` oracle. Retired-route answers contain only the relocated source identity.
11. Delete Relocated.swift, no rebuild: stale/deleted source detection.
12. Rebuild remaining sources: `swift_delete` oracle. Retired-route callers disappear; old unit/record bytes may remain and must not contribute.
13. Restore all original source bytes and rebuild: `initial` exact caller oracle and original source-manifest hashes.

For unbuilt/failed states, do not grade old compiler calls as if they described current source. Require explicit stale/refusal handling for the native capability that claims it, and an external integrity gate for both arms. Record native unsupported baseline functionality without fabricated false negatives. Freshness checks must cover the actually changed `.h` file and missing dependency paths; a generic constant warning or a warning about some unrelated Swift file is not sufficient evidence.

Every successfully compared state must have real completed index units, header compile dependencies, both shared Swift module contexts, and the expected current source inventory. The implemented build-only scaffold verifies compiler exit status, expected object files, a nonempty unit store, and header dependency files; it does not yet parse native units to prove per-output current-unit association, both native module contexts, or SDK/target metadata. It emits `native_unit_provenance_gate: not-run` without a hook. Those additional gates are mandatory work in the observation hook before reporting a passing comparison. Verify actual iOS target and SDK evidence in compiler metadata; an iOS-sounding directory name is insufficient. Failed builds cannot become accepted states. Source-only stages prove index bytes unchanged. Full restoration proves byte equality, but new compiler record bytes/timestamps need not be identical.

## Observation hook and scoring

`--hook-json hook.json` accepts an argv array, not shell syntax. The runner calls it with `--state /absolute/state.json` after every state and before proceeding. The hook owns actual CLI acquisition/verification, matching-library checks, both independent observations, normalized evidence, scoring, and raw diagnostic capture. It must return nonzero on any required gate failure. Source and store hashes are checked after the hook; mutation fails immediately. With no hook, the runner explicitly reports product checks as not run.

An indexed-state observation accepted by `score_calls.py` contains:

    {"arm":"actual-index-dump-plus-external-assembly",
     "operation":"compiler-callers","capability":"supported",
     "fresh":true,"complete":true,"unresolved":[],
     "queries":[{"id":"q01","seed":"<source identity>","max_depth":8,
       "direct":["<source identity>"],
       "transitive":[{"id":"<source identity>","minimum_depth":1}]}]}

There must be exactly ten query entries. The scorer rejects truncation/ambiguity, duplicate identities, missing queries, stale input, wrong seeds/depths, and unknown extra answers. Both source-ID sets and shortest depths must agree. Empty-set precision/recall remain null; exact agreement is still tested. A native-baseline observation may instead report `capability: unsupported`; it is unscored with null metrics. This does not excuse the comparable external-assembly arm from implementing callers.

The scaffold does not pretend to have a mixed-language adapter already. The existing runners require extension before their outputs can feed this hook. Do not label a build-only pilot as a passing Cartograph versus IndexStoreDB comparison.

## Framework contract

`--with-tests` compiles real XCTest sources into the shared iOS store using the selected platform's `Developer/Library/Frameworks` and `Developer/usr/lib`. Primary caller queries still have the fixed `Sources/**` universe; the test-selection check separately includes `Tests/**` and uses `framework-oracle.json`.

`QuoteTests.setUpWithError` compiler-calls checkout. Neither test body calls that lifecycle method. XCTest nevertheless runs setup before both QuoteTests tests. Therefore both tests are selected by the framework oracle, including `testUnrelatedBody`; `OtherTests.testUnrelated` is negative. Compiler callers and affected tests are not the same set. This draft neither links a test bundle nor runs a simulator, so it makes no XCTest runtime-pass claim. A future runtime gate needs its own build/bundle command and actual execution logs.

## Existing-code inventory and required work

Read-only inventory against the current PR166 worktree:

- `Tests/CartographIndexStoreTests/RawIndexStoreReaderTests.swift`: `makeFixture` invokes xcrun swiftc twice on one Shared.swift with different module names; `makeManySharedRecordsFixture` uses an output-file map. `makeObjectiveCFixture` invokes xcrun clang with a real header and SDK file dependency.
- The reader's `objectiveCFileDependencyKeepsSystemDate` validates raw dependency dates. `objectiveCFileRootsMatchDatabaseProvider` explicitly expects the `.h` date to be absent at the provider level. This is a concrete header-freshness coverage risk, not evidence that header warnings work.
- `Sources/CartographIndexStore/RawIndexStoreReader.swift`: iterates record/file dependencies and preserves `(unit, record)` occurrence provenance, but receives an allowed-path set. Native source inventory and header inclusion must be checked end to end.
- `Fixtures/FalsePositiveCorpus/Sources/CorpusObjC`: real Foundation Objective-C indexing and framework-registration syntax; package is macOS, not an iOS cross-language build.
- Upstream `Sources/ISDBTestSupport/INPUTS/MixedLangTarget`: an existing `.swift/.c/.m/.cpp/.mm` and bridging-header build pattern. This draft uses a module map plus direct iOS compiler targets instead of its test build infrastructure.
- `Scripts/benchmark-indexstore-cli.py`: selectors and compile path are flat Swift-only; baseline record dictionaries discard unit/module context. It cannot be pointed at this fixture unchanged.
- `Scripts/benchmark-indexstore-project.py`: useful source-normalization, role caution, strict ambiguity checks, and actual CLI evidence preservation; its callable declaration recognizer and target manifest are Swift-specific. C-family declarations, header aliases, Objective-C selectors, and duplicate source/module contexts need an independently tested generic extension.
- `docs/evaluation/indexstore-final-protocol.md`: this remains validation. Missing iOS execution or unsupported contexts cannot be silently removed. Native unsupported operations never become zero-recall scores.

Recommended integration order: build-only iOS pilot; implement and mutation-test generic mixed-language identity/record handling on validation sources; wire the hook and run all exact caller/freshness gates; inspect optional framework contract separately; freeze adapters/toolchain/oracles; only then author/expose fresh final holdouts.

## Build commands and official references

The direct-compiler route avoids depending on SwiftPM's selected backend honoring `-Xswiftc -index-store-path`, a documented trap in this repository. Each Clang compile uses explicit `-target`, `-isysroot`, `-index-store-path`, `-MD/-MF`, and a stable `-o`. Swift compilation uses explicit `-target`, `-sdk`, `-module-name`, `-index-store-path`, `-output-file-map`, `-emit-object`, and `-emit-module`. Both pass exactly one shared store path. Clang uses real Apple Foundation headers for the Objective-C class. No fake Foundation shim is used in the iOS fixture or portable check.

Verified primary sources:

- Apple, [Configuring command-line tools settings](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings): selecting an already installed Xcode with per-command DEVELOPER_DIR avoids system-wide selection changes.
- Apple, [Building from the Command Line with Xcode FAQ](https://developer.apple.com/library/archive/technotes/tn2339/_index.html): Xcode CLI discovery and SDK inspection.
- Apple, [Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/): full Xcode bundles the tools; the standalone Command Line Tools package is not equivalent iOS SDK coverage.
- Swift project, [driver option definitions](https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/Option/Options.td): `sdk`, `target`, module/output-map emission, `index-store-path`, and `index-unit-output-path` contracts. The selected executable's help/version are additionally recorded by real execution.
- LLVM, [Clang command guide](https://clang.llvm.org/docs/CommandGuide/clang.html) and [driver argument reference](https://clang.llvm.org/docs/ClangCommandLineReference.html): target, Objective-C/Objective-C++ language selection, and SDK/include controls. The installed Swift toolchain Clang's `-cc1 --help` additionally confirms `-index-store-path`; actual portable object/index emission is preserved here.

These references establish command intent, not proof that this exact fixture compiles against the runner's iOS SDK. That proof remains a real macOS execution gate.

## Reporting and final protocol

This draft emits no speedup threshold or superiority verdict. If pilot costs are collected, preserve all compiler setup/build, reader discovery/setup, parse/assembly, refresh, and query costs; label them descriptive validation. Charge shared build costs equally to each composed arm. Use equivalent graph/session reuse, balanced order, fresh private reader state, immutable source/index fingerprints, and preserve failed rounds. Do not call uncontrolled OS caches cold or `wait4` peak RSS aggregate process-tree memory.

The final preregistration remains unchanged: twenty independent paired sessions, ten initial and ten post-edit queries, paired-median composed-cost improvement at least 20%, paired 95% bootstrap ratio interval below one, every correctness/freshness/rename/delete/restoration gate exact, and explicit memory/startup tradeoffs. A secondary already-built success cannot replace a failed primary result. The moving macos-latest pilot is diagnostic; the final runner/toolchain regime must be pinned before seeing holdout outcomes.
