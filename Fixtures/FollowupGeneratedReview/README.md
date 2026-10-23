# Generated-header review controls

This synthetic compiler fixture represents feedback C-P1-7: generated declarations can dominate a
finding list, while human-maintained design tokens must remain visible. It contains no private
application code and makes no claim about that application's findings.

`GeneratedSourceReviewCompilerTests` compiles these four files with the installed Swift compiler,
loads that fresh IndexStore, and compares the complete unused-function set and graph before and
after optional header review. Expected unused functions are `filenameUnused()`, `generatedUnused()`,
and `manualToken()`. The real `liveGenerated()` → `usedToken()` edge must survive.

Only `Generated.swift` contains an explicit marker. `DesignTokens.swift` is human managed.
`NeedleGenerated.swift` deliberately has a tempting filename without a marker. The official Needle
sample at revision `c6a3b2c5f4bb60da4ab9ee97fea38cdf45cd4bcc`,
`Sample/MVC/TicTacToe/Sources/NeedleGenerated.swift`, likewise has copyright/imports instead of an
explicit generated header; a filename is insufficient evidence. This fixture does not run Needle.

Native gate: `swift test --filter GeneratedSourceReviewCompilerTests`. The test invokes `xcrun swiftc`
only on its own temporary copies and does not execute a package manifest or a generated application.
The unit suites also cover marker text inside strings/after code, unsupported block/doc comments,
UTF-8/read errors, source changes, bounded prefix/file/total reads, and preservation of all original
diagnostics. A marker is a source assertion, not proof of current generator or index provenance.
