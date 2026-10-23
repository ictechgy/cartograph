# Native Xcode scope regression fixture

This minimal public fixture exists because scheme identifiers, actual compiler modules,
`.xctestrun` output and executable test bundle names cannot be validated by a mocked graph.
`ChecksBlueprint`, Swift module `ChecksModule`, and bundle `RunnableChecks.xctest` are
intentionally different. The supporting framework uses the same `CoreKit` module and
framework filename so that ordinary framework import resolution remains valid. `UnbuiltBlueprint` owns a Swift file outside the selected scheme.

The native gate captures a fresh build, compares the immutable previous main binary with
the candidate on the same input, verifies stale/membership/product refusals, then executes
the emitted selector against the captured bundle. The test count must be one; an exit 0
with zero tests is not accepted. This fixture does not model a private multi-project app.
