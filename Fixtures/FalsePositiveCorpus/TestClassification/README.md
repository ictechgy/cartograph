# Test identity and dispatch feedback

This generalizes the reported application debug methods named `test_*` and seven
sibling receiver test candidates. It contains no private application sources.
`verify-test-classification-feedback.py` builds a real SwiftPM test index and
compares the public 0.28.0 executable with the candidate on that same index.

`ExtensionTests.swift` covers the independent review concern that an XCTest method
whose compiler parent is an extension can lose its confirmed identity. The harness
records the observed compiler bit, parent USR and compiler `.extends` relation from
the candidate snapshot. If the toolchain records the nominal class as the parent,
that is reported explicitly; it does not demonstrate the extension-parent failure.
The unrelated `DebugPanel` extension must never become a confirmed test.

These are test review candidates, not execution observations, selected scheme
membership, failure predictions or permission to omit other tests. The seven
sibling dispatch candidates remain because their runtime receivers are unproven.
