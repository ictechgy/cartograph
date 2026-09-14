# Core Data version selection corpus

`Scripts/verify-coredata-versions.py --cartograph <built-binary>` compiles real models with Xcode momc,
generates the V2 properties extension, builds a Swift compiler index and instantiates Core Data objects.
The model's selected version must agree with the class reported by Cartograph. Old versions remain
explicit migration review inputs; choosing the default version does not prove they are never loaded.

The harness switches `.xccurrentversion` without changing Swift sources, checks snapshot comparison and
`impact --since`, then rejects missing/traversing version selections, excluded markers or selected models,
and a marker symlink to an external plist. A filtered single version cannot stand in for the active model.
Invalid `manual` code generation
and the ignored `customClass` attribute are separate execution-backed negatives. Generated class mode
is not inferred from a same-named manual class; it requires generated-source and build-module provenance.

These cases came from the 2026-09-14 local Xcode SDK/momc audit. The three private application scopes
used for notification validation contain no Core Data model, so this corpus is separate synthetic
compiler/runtime evidence, not a reported production application defect.
