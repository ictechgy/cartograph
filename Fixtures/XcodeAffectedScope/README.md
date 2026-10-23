# Native Xcode scope regression fixture

This minimal public fixture exists because scheme identifiers, actual compiler modules,
`.xctestrun` output and executable test bundle names cannot be validated by a mocked graph.
`ChecksBlueprint`, Swift module `ChecksModule`, and bundle `RunnableChecks.xctest` are
intentionally different. The supporting framework uses the same `CoreKit` module and
framework filename so that ordinary framework import resolution remains valid. `UnbuiltBlueprint` owns a Swift file outside the selected scheme.

The selector must use the verified `ChecksBlueprint` target name; `RunnableChecks`
is the bundle product name. Xcode 26.6 rejected the initial product-name selector
with exit 70, even though capture, CLI/MCP review and refusal controls had passed.
That observed failure remains distinct from the subsequent selector execution check.
The compiler's ObjC-style test USR has no validated parent/method selector in this
fixture, so selection deliberately widens to the whole `ChecksBlueprint` target.
One executed test reflects this target containing one test; it does not demonstrate
method-level precision. The separate `OtherRunnable` bundle is outside the emitted
selection, while both test targets and their source records remain in the proved universe.

The native gate captures a fresh build, compares the immutable previous main binary with
the candidate on the same input, verifies stale/membership/product refusals, then executes
the emitted selector against the captured bundle. The test count must be one; an exit 0
with zero tests is not accepted. This fixture does not model a private multi-project app.
