# Local package compiler observation fixture

Prepared on an isolated branch from `0a1ca641618ee78730c7a52ea41f5b131d86ae66`,
then carried unchanged onto main `4f5c5c591921c270192efead07c2dacf8fdfe9f3`.
Native observation at `8cf46ee975110994baff32595a48b353f6c40322` built both variants
and observed actual compiler-unit/output/object/live-link joins. The diagnostic's
success is separate from the opt-in v2 receipt and consumer checks added afterward.
Default v1 admission continues to refuse packages.

The reported missing-local-package-index-unit problem motivates this generalized
public fixture; it does not reproduce the private 22-project workspace.

`Packages/LocalMath` has one ordinary Swift target, compiler module `ArithmeticCore`,
and a library product named `ArithmeticProduct`. `CoreBlueprint` links that product;
its `CoreKit` function calls `packageValue()`. `ChecksBlueprint` / `ChecksModule` /
`RunnableChecks.xctest` remain three different test target/module/product identities.
`OtherBlueprint` reaches a separate CoreKit function, and `UnbuiltBlueprint` stays
outside the scheme. The package has no external/transitive dependencies, plugins,
macros, binary targets, resources, C/Objective-C sources or package tests.
`Scope` selects both test targets. `ChecksOnly` still builds Other but selects only
Checks, so the compiled-for-Other negative control cannot claim a CoreKit or selected
universe contribution merely because a package unit exists.

The PBX local-package reference, selected target's product dependency and framework
phase productRef are declared inputs, not proof that Xcode built or linked any file.
The package library product's physical form is intentionally unspecified: observation
must discover actual object/library output and linker contribution. Do not invent
`libArithmeticProduct.a` or infer module identity from a product/path name.

See [OBSERVATION-PLAN.md](OBSERVATION-PLAN.md) for the bounded native evidence gate.
No current-main coverage expectation or fixed workflow has been changed for this
preparation. The separate `xcode-local-package-observation.yml` workflow executes
the two native variants and POSIX live stream-overflow controls, retaining bounded
observations or failures. A separate step exercises the v2 producer, CLI, same-session
MCP record mutation refusal, and actual whole-target test execution. These product
checks must pass independently of raw observation; neither proves private-app coverage.

The unpublished diagnostic entry point is
`python3 Scripts/observe-xcode-local-package.py --output /new/path/outside/checkout`.
It builds this exact committed fixture and a second variant where only OtherBlueprint
consumes the package. The opt-in `LocalPackageUnitObservationTests` probe reads
`IndexStoreUnit.outputFile` from the selected toolchain's libIndexStore. The diagnostic
collects compiler/link maps and raw units; its `observations-collected` status does
not certify the pending cross-evidence joins or issue a production scope receipt.
Portable parser checks are `python3 Scripts/verify-local-package-observation.py`;
those checks do not compile Swift or validate Xcode project schema.
