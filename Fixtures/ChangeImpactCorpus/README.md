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
- A depth or output limit is explicit. Unknown/deleted source selections are incomplete.
- The executable prints `live` and `extension`; the tests exercise those actual results.

Run `python3 Scripts/verify-change-impact.py --cartograph <binary>` from the repository root.
