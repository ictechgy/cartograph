# Target-scope feedback fixture

`AppTests` explicitly depends on `App`. `Tool` is a separately compiled local target.
The native harness filters `Tool.swift` and Git-ignores `Ignored.swift`, although both
are actual SwiftPM target sources. A capture receipt must inventory both without
using Git ignore or the analysis filter as membership evidence.

The receipt classifies these paths outside the explicitly selected test target's
dependency closure. It does not prove an Xcode scheme, runtime loading, or test
coverage. `affected --format xcodebuild` still refuses narrow selectors. A newly
added source, changed manifest/lock, stale capture, shared ownership, external
dependency or unsupported target leaves membership unknown.

This synthetic package does not reproduce the reported private 22-project workspace.
