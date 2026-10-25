# Captured Xcode affected-test review

`affected --target-scope` also accepts an opt-in Xcode capture. A matching capture can
emit useful `-only-testing:` review candidates even when an unbuilt source belongs
to a target proved outside the selected test universe. The original coverage warnings
remain in JSON and stderr, alongside the excluded paths and their ownership evidence.
Empty output, unknown evidence, or a refusal is never permission to skip tests.

Single-project v1/v2 captures support one root `.xcodeproj`. Workspace v3 captures support
up to 32 explicit local `.xcodeproj` references, cross-project target/product proxies and
shared workspace schemes. Both require explicit Swift source phases, native macOS and
non-app-hosted XCTest bundles. This does not establish accuracy on iOS, generated resources,
UI tests or an unobserved private application.

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

## Explicit multi-project workspace (receipt v3)

```sh
python3 Scripts/cartograph-xcode-scope.py \
  --project "$PWD" --workspace Example.xcworkspace --scheme WorkspaceTests \
  --local-package --cartograph /path/to/cartograph --output /tmp/workspace-capture

cartograph affected changedValue --project "$PWD" \
  --index-store /tmp/workspace-capture/DerivedData/Index.noindex/DataStore \
  --target-scope /tmp/workspace-capture/target-scope.json --format json
```

Use the exact `indexStore` in `capture.json`; append the same `--config` when capturing
and consuming. A workspace uses its own shared scheme directory. Explicit shared test
plans still use `--test-plan`. `.xcworkspacedata` group/container references are resolved
inside the physical project root, with at most 32 projects, 256 entries and group depth 32.
External/absolute paths, nested workspaces, missing projects and XML entities refuse before
`xcodebuild`. Project PBX group depth remains 128; the combined object/target budgets are
50,000/1,000. Project directory/source-root overrides and arbitrary build scripts remain unsupported.
Workspace and scheme XML must be UTF-8 (an explicit UTF-8 declaration is allowed), without
NUL bytes, DTDs or entity declarations. Other encodings, including UTF-16 XML, refuse
before building instead of bypassing the same declaration policy.

PBX IDs are namespaced by `project/path.xcodeproj::ID`. Explicit project references and
target/product proxies must identify a listed project's actual native target and its
declared product. A framework link must be inside the explicit dependency closure.
Compiler modules and target selector names must be unique across the workspace: a duplicate
selector name cannot be safely expressed by `-only-testing:`. Product filenames, compiler
modules and `.xctestrun` BlueprintName identities remain separate. No name-only fallback is used.

`--local-package` admits up to 16 unique finite local packages, up to 16 references in each
project and 256 project/package declarations overall, with the literal manifest and full
subtree/compiler/record/live-link proof described below. Several projects may consume the
same physical package, and one target may consume several distinct packages. Relative PBX
references such as `../Packages/Common` are allowed when resolved from the project's parent
inside the workspace root. Every lexical `..` step must remain inside that root, and the
final path must be canonical: external paths, symlinks, duplicate physical packages in one
project, or duplicate package/product/module names refuse. The package may be outside the
referencing project's directory; it must remain inside the captured workspace root. Every package
needs a positive native consumer inside the selected TestAction closure. A compiled or
merely built package outside that closure cannot silently become an excluded dependency.
Multiple products/targets per package, remote dependencies, plugins, macros, binary targets,
resources and computed manifests remain outside this proof contract.

Each package's `declarations` binds its project-qualified PBX package/product references to
the exact framework-phase consumers. The consumer rereads every declaration, verifies the
complete per-project product sets, and compares their union with the package's consumer/link
set. Shared sources, compiler records and aggregate proof are bound once per physical package.
Older v3 receipts with one `project` field still decode; new shared/multiple declarations
require the updated consumer. An older v3 consumer refuses the new declaration shape.

For Xcode's synthesized dynamic package product, the verified chain may be source object →
relocatable aggregate → package framework → native executable. The intermediate product must
have exactly the aggregate as its explicit object input, positive live link-map ownership,
captured executable/Info.plist bytes, matching `CFBundleExecutable`/`FMWK` metadata and the
observed `@rpath` install name in its standard framework layout. Each native consumer must
both name that product in its actual linker operands and have a positive live owner for it.
The optional product bundle enters the `.xctestrun` dependency closure only through a
proved native consumer in the selected closure. Merely finding a framework under Products
does not admit it. Native/package deployment minimums need not match; the package compiler
and aggregate target triples must agree. This supports that bounded macOS link shape;
iOS app-host/debug-dylib chains remain unsupported by this implementation.

v3 inventories allow 20,000 input files / 128 MiB total (4 MiB per file), giving source
and configuration headroom beyond 10,000 sources. The 50,000-entry walk and 8 MiB receipt
limits still apply; unusually long paths or source arrays can reach the receipt limit first.
There is no unlimited-input switch. `capture.json` reports the inventory count and declared
versus observed compiler source-record counts by native module. These are observations,
not definition recall, line coverage, dynamic coverage or proof of safe test omission.
`targetScope.xcode` preserves the workspace/project list and each package's metadata origin.
Original excluded-path warnings, unmodeled paths, stale records and output/depth truncation
continue to block selection when they overlap or cannot be classified against the selected universe.

Build-settings command stdout is retained verbatim. Receipt path operands use physical
filesystem identities. The consumer only admits macOS `/tmp`/`/var/folders` aliases when
realpath proves the exact `/private` form; arbitrary `/private/project` prefixes and
individual file symlinks are not assumed equivalent. The same rule applies to each raw
`.xctestrun` bundle/dependency operand: an outside symlink to a valid product or a dot-segment
alias refuses even when generic realpath would reach the product. Rebuild and recapture when membership
or artifacts change. v1/v2 decoding remains supported; older consumers refuse v3.
Consumers must preserve the workspace identity and use the captured `.xctestrun`; inferring
an execution context from the first project field alone is unsupported.

The native regression constructs a public two-project framework dependency workspace with
two workspace-level packages: both projects consume one shared package and a target in one
project consumes both packages. It checks both affected test targets for a shared-package
change, compares baseline refusal with verified selectors and executes one selected captured
XCTest. CLI/MCP, actual temporary aliases, outside aliases, encoded XML, malformed identities,
intermediate product metadata and changed workspace/project/scheme/product bytes have
positive or refusal controls. It is not a reproduction of the private
22-project workspace, a platform matrix, or a general precision claim.

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

Every xctestrun `DependentProductPaths` entry must belong to a verified native product
in the selected TestAction dependency closure. BuildAction membership alone does not
establish this. In the public fixture, `ChecksOnly` builds Other but does not select it;
Xcode still records `OtherRunnable.xctest` as a dependency, so that scope remains unknown
and emits no selectors. The positive harness uses `Scope`, whose declared universe
contains both test targets, and requires impact candidates to select only Checks.
This is a bounded supported scheme shape, not support for arbitrary extra build-only
products. A verified package aggregate is not itself admitted as an extra test-run
dependency without a native product identity.

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
64 MiB total. All candidate aggregate/intermediate file lists, including nonselected
candidates, share the same document/file accounting. They are read through a bounded
nonblocking descriptor that must be a regular file; FIFOs and changed file roles refuse.
There are at most 256 candidate file lists/build command rows and 256 inputs per file list.
Nested response files and incomplete link-map parsing refuse proof.
These are review candidates from the exact captured build, not runtime coverage or
permission to skip the rest of a test suite.


## iOS Simulator v4 development draft

The v4 source changes remain a **development draft**, not established iOS support.
The corrected sources compile and pass 2,668 Swift tests and instrumented CLI integration;
source coverage is 93.17%. Independent review identified a workspace xcconfig identity
mapping gap, now covered by merge-to-membership regressions with literal includes and
execution/path/cycle rejection controls. A complete native v4 capture and CLI/MCP
consumption remain pending. Earlier generic SDK builds establish only that the public
synthetic app can compile. They do not validate this consumer implementation or prove
that a selected test executes.

The intended opt-in profile is `--workspace Example.xcworkspace --ios-simulator`.
It uses only `generic/platform=iOS Simulator` with `build-for-testing`, does not select or
operate a device, and records no runnable execution context. Its receipt adds native
source-to-current-record/object/link evidence, effective Simulator SDK/deployment targets,
app bundle metadata and actual app-hosted XCTest identities. An Xcode debug-dylib build
binds its code image and generated app stub separately, including their strong load edge.
A lower observed local package deployment minimum is compatible with a higher app minimum;
the receipt does not assume that every module has the same target triple.

The draft models plain regular resource copies and headers as auxiliary inputs, not Swift
definition units. Every declared byte is inventoried and resource-copy hashes must agree.
Transformed resources (storyboards, asset catalogs), generated source membership and arbitrary
xcconfig evaluation remain unsupported. A finite local include closure may contain only
literal Swift/C compilation definitions; custom compiler commands, external includes,
conditional settings, scripts and plugins still fail closed before a build.

None of this establishes actual iOS Simulator execution, `-only-testing` acceptance,
UI-test support, correctness on the private 22-project workspace, or safe omission of tests.
The existing macOS v1/v2/v3 profile keeps its destination, non-app host and input restrictions.
