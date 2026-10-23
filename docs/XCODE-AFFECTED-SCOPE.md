# Captured Xcode affected-test review

`affected --target-scope` also accepts an opt-in Xcode capture. A matching capture can
emit useful `-only-testing:` review candidates even when an unbuilt source belongs
to a target proved outside the selected test universe. The original coverage warnings
remain in JSON and stderr, alongside the excluded paths and their ownership evidence.
Empty output, unknown evidence, or a refusal is never permission to skip tests.

The initial supported boundary is deliberately small: one `.xcodeproj` at the project
root, explicit local Swift source phases, shared schemes, native macOS architecture,
and non-app-hosted XCTest unit-test bundles. It does not establish accuracy on a multi-project
workspace, iOS, generated resources, UI tests, or an unobserved private application.

## Capture and consume

Only build projects you trust. Capture runs `xcodebuild build-for-testing`; it does not
run tests. Unsupported shell scripts, build rules, packages/plugins, external project
references, conditional membership, synchronized groups, source filters, resources,
headers, shared sources, and custom compiler/linker input settings are refused by a
metadata preflight before the build. Output relocation, app hosts/custom bundle loaders,
explicit metadata paths (including local `INFOPLIST_FILE`, entitlements, prefix-header,
and module-map paths), and nonstandard runpaths are also refused. Compiler module
names must be unique across every project target, including unselected targets.
Explicit SDK/developer framework references must
use a supported relative system-framework path, resolve inside the selected Xcode
SDK/developer root, and have bounded captured file bytes and symlink identities.
Absolute, escaping, macro, and external symlink paths are rejected before building.
This is not a sandbox for untrusted build files, or a complete inventory of implicit
compiler/SDK imports.

```sh
python3 Scripts/cartograph-xcode-scope.py \
  --project "$PWD" --xcode-project Example.xcodeproj --scheme ExampleTests \
  --cartograph /path/to/cartograph --output /tmp/example-scope-capture

cartograph affected changedValue --project "$PWD" \
  --index-store /tmp/example-scope-capture/DerivedData/Index.noindex/DataStore \
  --target-scope /tmp/example-scope-capture/target-scope.json --format json

cartograph affected changedValue --project "$PWD" \
  --index-store /tmp/example-scope-capture/DerivedData/Index.noindex/DataStore \
  --target-scope /tmp/example-scope-capture/target-scope.json --format xcodebuild
```

Use the actual `indexStore` path in `capture.json`, and the same optional `--config`
for capture and consumption. For a scheme that uses test plans, supply the explicit
relative plan path with `--test-plan Plans/Unit.xctestplan`. This version requires one
plan configuration with no runtime options or partial selections.

`targetScope.xcode` records the project, scheme, plan, configuration, destination,
architecture, complete selected source universe, blockers, and compiler-module to
verified Xcode target mapping (`selectorTargetByModule`). The `selectorIdentity` is
`xctestrun-blueprint-name`: the `.xctestrun` BlueprintName must match the project and
selected scheme target. `testBundleByModule` separately records the verified product
filename. For example, module `ChecksModule` maps to selector `ChecksBlueprint` and
product `RunnableChecks.xctest`; a product filename is not a selector target name.
Documents without these identity fields still decode but cannot emit verified selectors.
Without a validated class/method selector, the original widening reason remains in
the output and selection covers the whole verified target. Running one test in a small
target does not establish method-level selection precision.
Selectors apply only to this captured build context. Use the
captured `.xctestrun` with `xcodebuild test-without-building` and its recorded destination;
applying the arguments to another scheme, destination, or build is not verified.
Static candidates do not predict failure and do not authorize omitting other tests.

For MCP, copy the receipt JSON into the configured project and pass `targetScope`
to `cartograph_affected`. The server binds it to the prepared generation, verifies the
current receipt and inputs, and checks the generation again before returning. The
cached session fingerprint and public capture fingerprint have distinct encodings;
fresh observations before and after scope consumption bind them to the same prepared
generation without changing either existing fingerprint contract. An
input-fingerprint read failure discards the ready context. The receipt itself must be
inside the configured project; captured build products remain at their original paths.

## Evidence and refusal

The consumer rereads project and scheme/plan membership, source/configuration bytes,
selected compiler modules, `.xctestrun` bundle paths, and the entire captured product
tree's regular-file bytes and symlink destinations. Actual products for the entire
selected target dependency closure must lie in that captured tree; `.xctestrun`
dependency paths must name those products. The standard non-app XCTest runner is
resolved from the selected developer root and its bytes are checked separately.
App-hosted/UI test bundles remain unsupported. Every selected source must be in
the analysis and have a successfully consumed non-system Swift `.record` in the expected
module with a fresh unit timestamp. File-only dependencies, tracked-only/deferred
sources, legacy snapshots, another module's record, and timestamps alone do not satisfy
that requirement. The snapshot preserves `sourceRecordAdmissions` as an optional,
additive field; older snapshots decode but cannot establish this proof.

Only `unindexed-sources`, `configured-path-filter`, and `source-discovery-exclusions`
whose relevant paths are all proved outside the selected dependency closure can be
separated for selector review. Unknown ownership, stale inputs, missing/unreadable
selected sources, edge filters, runtime gaps, incomplete test identity, output/depth
truncation, and tests reached outside the captured universe still refuse selection.
Source membership is not dynamic coverage. The receipt is an unsigned producer claim,
not a proof that a trusted build system compiled arbitrary declared bytes correctly.

Limits: 1,000 targets; 10,000 source/configuration files (4 MiB each, 64 MiB total);
50,000 input entries; 8 MiB receipt; 10,000 product entries (128 MiB per regular file,
512 MiB total); 64 explicit system frameworks (10,000 entries and 128 MiB total,
16 MiB per regular file). Scope output is subject to the requested `--limit`: truncating a
membership proof prevents selector emission. Capture has a bounded per-command timeout
and keeps command output and preparation time for review. It uses a fresh output
directory and never cleans another build or checkout.

The prior SwiftPM receipt remains diagnostic only and continues to refuse Xcode
selectors. Existing commands without `--target-scope` keep their compatibility behavior.
No public release or native-platform validation is implied by this source document.

## Finite local package opt-in (receipt v2)

Add `--local-package` to the capture command to request one project-contained ordinary
Swift library. Default capture and v1 receipts retain their package refusal. Existing
readers that do not support v2 refuse it; recapture with a v2-capable producer and use
a matching consumer. The separate SwiftPM diagnostic receipt has not become Xcode proof.

The package manifest must be a fully consumed literal `Package` declaration: one name,
one library product, and one matching Swift target, using tools version 5.9 or 6.0–6.3.
Comments are tokenized without execution; computed expressions, string escapes,
dependencies, plugins, macros, binary targets, resources, Clang sources, package tests,
and configuration variants are unsupported. Every subtree entry is bound, including
empty directories and extensions the normal Swift source inventory would not scan.
Adding an unexpected resource or C/C++ file therefore invalidates the proof. The manifest
is configuration evidence, not a missing compiled Swift declaration; unrelated missing
sources and global configuration blockers remain visible and continue to refuse selectors.

The only admitted generated package metadata is the exact empty directory pair
`.swiftpm` and `.swiftpm/xcode`. A lone directory, metadata files, deeper directories,
and symlinks refuse capture. The producer records `generatedMetadataOrigin` as
`absent`, `preexisting`, or `capture-created`, comparing the complete before/after
inventories and allowing only creation of that empty pair. Every other declaration
and entry must remain identical. The whole post-capture inventory, including these
directories, is checked again during consumption; adding a metadata file or removing
a directory invalidates it. Verified CLI/MCP `targetScope.xcode` carries this origin
as an unsigned producer observation, not independently authenticated history. This
exception does not hide source-discovery warnings or permit generic `.swiftpm` content.
The field is required in the unreleased v2 format; missing or unknown values refuse.

PBX package and product references must agree with explicit framework-phase consumers.
The capture observes actual compiler source lists, output maps, target triples, and
successfully read index records. A raw unit output identity can be virtual: it must
match `index-unit-output-path`, while the distinct `object` entry names the real object.
Repeated Xcode compiler wrappers are deduplicated only when their underlying invocation
and source/output identities agree. Product, compiler-module, and selector names remain
separate. Every declared native consumer must have a positive object → relocatable object
→ native executable live-owner link-map chain, and at least one consumer must belong to
the selected native target closure. Compiled/indexed but unlinked, stripped, ambiguous,
or missing contribution remains unknown; it never classifies a package outside scope.

Compiler/link response files, source/output maps, file lists, link maps, objects, and
backing record bytes are hashed and read again. v2 capture discovers record identities,
binds the complete proof, launches a fresh raw snapshot process, and compares the whole
proof again before writing. v2 CLI/MCP consumption similarly binds proof around fresh
raw analysis and checks it at return; cached MCP graphs cannot certify changed record
bytes just because unit timestamps are unchanged. This opt-in costs extra analysis and
I/O; v1 and ordinary warm-query costs remain separate. Failures invalidate MCP readiness.

Additional v2 limits: 4,096 package entries, depth 128, 256 Swift sources/records, 64 KiB
manifest, 1,024 proof files, 1,000 tokens per observed command. Documents are limited to
8 MiB each / 32 MiB total, objects 64 MiB each / 256 MiB total, records 16 MiB each /
64 MiB total. Nested response files and incomplete link-map parsing refuse proof.
These are review candidates from the exact captured build, not runtime coverage or
permission to skip the rest of a test suite.
