# Change impact corpus

This is a synthetic acceptance fixture for the requested pre-edit workflow, not a reported
customer defect. Its real compiler index distinguishes protocol requirements, sibling witnesses,
extension members, consumers in another module, an executable entry point, and swift-testing tests.
It exists because a hand-written graph cannot prove which edges the Swift compiler emits.

Expected behavior:

- Changing `LiveStore.read` identifies `render`, `renderLive` and `rendersLiveStore` as potential
  consumers through the protocol requirement; it does not identify `SpareStore.read` or
  `unrelatedUtility` as consumers.
- Selecting the `LiveStore` type or its source file also includes `extensionOnly`, and therefore
  `renderExtension` and `rendersExtension`.
- Changing `RuntimeController` or its `RuntimeScreen.xib` resource selects exactly
  `resolvesRuntimeController`, through `NSClassFromString`'s literal Objective-C name. The test
  actually resolves the class at runtime without a source reference to the class. This synthetic
  regression reproduces the observed `affected`/`impact` wiring discrepancy; unrelated store tests
  must remain absent, and the supplemental relation must remain `automaticRuntime`.
- Changing `lifecycleValue` selects `LifecycleSetupTests` through its implicit `setUp` execution,
  plus `LifecycleDirectTests.testDirect` through its compiler call. It must not select
  `LifecycleUnrelatedTests`: its unused helper is not a lifecycle hook. This synthetic regression
  reproduces the repository audit's mixed lifecycle/direct-caller omission.
- Mixed indexed Swift and JSON fixture edits refuse partial `xcodebuild` selectors; JSON-only edits
  preserve the successful empty-selector (run every test) contract.
- The verifier adds a tiny `ReleaseStatus: Equatable` source to its temporary copy, then builds
  `a,b` and `a,b,c` with separate real compiler stores. It changes only the enum inventory between
  those two generated source versions. The supplied CLI must persist the capable baseline and
  report exactly three current decision candidates: `switch default`, literal `Array.contains`,
  and direct negated membership. Exact enum/case identities, compiler target identities and source
  locations are checked in JSON; text must expose all three kinds. Comparing the baseline against
  itself must report no additions or candidates. The existing RenderTests/RuntimeTests Swift Testing
  macros remain explicitly unexpanded: their two exact located coverage issues and overall partial
  status must survive JSON/text, while the enum inventory and all three decision attributions are
  complete. No issue is silently filtered out. This is a synthetic regression for the requested
  implicit enum-expansion review, not evidence that any candidate is a runtime bug. The release
  workflow runs this same check with the unpacked universal executable.
- A depth or output limit is explicit. Unknown/deleted source selections are incomplete.
- The executable prints `live` and `extension`; the tests exercise those actual results.

Run `python3 Scripts/verify-change-impact.py --cartograph <binary>` from the repository root.
