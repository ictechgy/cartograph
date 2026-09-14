# Runtime contract corpus

This synthetic acceptance fixture uses the real Foundation/Objective-C runtime on macOS.
It is not a customer incident, a Flutter SDK stub, or a claim to cover every runtime mechanism.

`dispatchScreen` calls `ProbeScreen.open` through `NSSelectorFromString` and `perform`.
`lookupScreen` resolves the exported Objective-C class name through `NSClassFromString`.
The executable hashes its own bytes and emits that executableFingerprint alongside the plan
fingerprint supplied by runtime plan.

`Scripts/verify-runtime-contracts.py` works in a temporary copy. It proves that:

- Both dynamic operations run successfully and their observations validate.
- Replacing the selector string with a missing selector still compiles, but the real runtime
  operation fails and `runtime check --strict` exits 1.
- Observations from before that edit are stale and exit 2.
- Copying the new plan fingerprint onto observations from the old binary is still stale and exits 2.
- An empty observation list is unverified and exits 1 with `--strict`.
- Removing the target method produces a missing-target contract failure even though dynamic
  dispatch still compiles.

The test observes only these explicit scenarios. Missing observations do not prove unused code.
