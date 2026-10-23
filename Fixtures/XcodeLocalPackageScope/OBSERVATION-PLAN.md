# Bounded native observation proposal

Status: diagnostic preparation only, based on the verified PR228/main source tree.
The standalone workflow must collect the runtime observations below before product
implementation. It does not change the v1 receipt contract or its package refusal.
Runtime observation below is not yet collected.

## Capture inputs and process

Use a fresh copy of this public fixture and a dedicated scratch/DerivedData directory
on the same pinned macOS/Xcode CI image. Record commit/tree, Xcode/Swift identities,
destination and architecture, exact argument vectors, elapsed time and exit status.
Before build, hash and inspect the finite fixture's PBX/scheme/plan/manifest/source
inventory; reject any unexpected file, symlink escape or nonlocal package reference.
Only this reviewed manifest is eligible for the diagnostic experiment. A future
production preflight must reject unsupported executable manifest forms before build.

Run ordinary `build-for-testing` with indexing enabled. Request a linker map in the
diagnostic build and record that changed build setting; obtain actual map paths from
resolved settings/build output. This is observation of that exact build context,
not evidence that every normal Xcode build supplies a link map. Do not execute
plugins, downloaded code or an arbitrary project script. A declared dependency
outside the finite local package invalidates this experiment.

## Required observed joins

1. Read actual Xcode compiler invocations/tasks from the bounded build log. Join the
   observed `-module-name`, file-list/source inputs and output-file-map paths to the
   project-contained package. Admit paths only inside the fixture or its dedicated
   build roots. Missing, ambiguous, escaped or truncated evidence is unsupported.
2. Read the compiler-emitted source file list and output map bytes. Record each
   canonical source-to-object mapping and SHA256 of source, map and object bytes.
   Locate these files through observed command operands, never a guessed archive
   filename, manifest target label or separate `swift package describe` result.
3. Read actual index units/records from the same Xcode build. Bind successful record
   read, source/module, owning main unit and observed unit output identity to the
   compiler object map. File-only timestamps and deferred/wrong-module records do
   not satisfy this join. If the current reader cannot expose a necessary unit
   output identity, record that missing observation; do not synthesize it from a
   unit filename.
4. Read the linker command/file list and linker map for the selected CoreKit product.
   An entry in a link map's Object files list is not by itself actual contribution.
   Join the observed linker argv/input list to live symbol/section owner indices,
   following any compiler-generated aggregate object through its observed link
   step. Hash every admitted intermediate and the final CoreKit product. A declared
   PBX dependency alone is insufficient. Archive-versus-object naming is discovered.
   If this join is unavailable, report "compiled; contribution unknown" within this
   bounded first capture. Do not infer runtime executability or complete membership
   from the link map. Compiler dependencies can remain meaningful when dead-stripped
   or inlined; absence of a live output symbol is not proof of no change impact.
5. Keep existing project target/module/test-bundle checks and actual `.xctestrun`
   BlueprintName mapping. The package does not own a test bundle. A `packageValue`
   change should reach the existing test via CoreKit. Test-without-building must
   execute the emitted whole-target selector and report one test, with the other
   target absent; that small target does not prove method-level precision.

## Budgets and artifact boundary

Reuse `benchmark-indexstore-cli.py`'s runtime stream-capped, owned-process-group
supervisor: at most 600 seconds per build, 32 MiB combined retained build output
(16 MiB per stdout/stderr stream, with no allowance transfer) and no shell evaluation.
Overflow stops the owned process group and fails the observation; cleanup status,
retained byte counts and the failure remain in its process receipt. Smaller command
budgets are divided equally in the same way. Read each settings/output-map/
file-list/link-map document with an 8 MiB cap; cap aggregate observed documents at
32 MiB and paths at 256. Bound individual object/product reads at 64 MiB and total
fingerprinted object/product bytes at 256 MiB. Oversize evidence is explicitly
unsupported. These are experiment budgets, not a proposal to loosen current gates.

The live overflow controls distinguish forced cleanup from cooperative termination.
A TERM-ignoring finite child must reach SIGKILL with an empty cleanup-error list and
a reaped root. The original cooperative child must also be rejected for overflow;
on Darwin its later group KILL can record `PermissionError` after TERM. That receipt
remains uncertain and rejected, never promoted to successful cleanup. Both streams'
bounded prefixes and original receipts are retained even when a test fails.

Publish only this synthetic run's small selected metadata, process receipts,
compiler/source/object joins, link-map excerpts with complete input hashes, record
admissions and test execution summary. Include omitted/truncated counts. Do not
upload complete build caches, index stores, environment variables or secrets.
Hashes and paths alone do not replace actual in-process byte/membership checks.
Each observed link map includes at most 64 KiB of raw text alongside its full-file
hash, original/retained byte counts, explicit preview truncation, section headers
and unparsed symbol-row counts. An empty parsed symbol set or a truncated preview
does not establish absence of contribution.

## Follow-up gates before product support

Recheck manifest/source inventory and all observed inputs before/after capture and
at consumption. Same-mtime source/manifest/object edits, added/deleted sources,
wrong package path/product/module, module collisions, missing/stale records and
outside-boundary files must refuse usable selectors. Add negative fixtures for
external/transitive packages, plugins/macros, binary targets, resources, Clang,
shared sources, extra projects and package-owned test targets.

Include a diagnostic variant in which ArithmeticCore is compiled and indexed for
OtherBlueprint but CoreKit has no package import or link contribution. Existing
package records alone must not certify the CoreKit consumer join. Preserve both
the observed compilation and the absent/unknown CoreKit contribution; do not silently
classify this package as unused or outside all selected targets.

Only after these observations are possible should implementation define a new
receipt version with those required joins. Retain v1 behavior; older consumers must
reject the new version. CLI and cached MCP generation/final-fingerprint checks must
agree. Unknown contribution, failed compilation, missing compiler records or
staleness cannot be classified as outside the selected universe.

PBX structure references (schema context, not execution proof):
[Xcodeproj local package reference](https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/project/object/swift_package_local_reference.rb)
and [product dependency](https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/project/object/swift_package_product_dependency.rb).
