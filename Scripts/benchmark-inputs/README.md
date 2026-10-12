# SDK and compiler input discovery

These helpers are validation scaffolding. They do not accept an SDK, mutate compiler/index generations,
allocate a final holdout or establish comparative performance. The existing final protocol is unchanged.

## Full content seal

`sdk_content_seal.py` is the separately reviewed helper (source SHA256
`cc289e5e44062b0c41ed998e3ea7ce9c357b4ead4be1fbae778ee5247e7b2195`). It inventories explicitly
named roots, relative entry types, permissions, file content hashes and symlink targets. It refuses
escaping links rather than adding roots. No-follow/nonblocking regular-file reads and full before/after
inventories detect accidental mutation. Strict expected receipts reject duplicate JSON keys, invalid
schema/counts/limits, FIFOs, symlinks and changes during reading. A checksum is integrity, not authority.

Entry, path-byte, content-byte and receipt-size limits fail rather than truncate. Content identity is
separate from receipt metadata and elapsed cost. This is declared-root identity, not complete OS or
loader hermeticity or an adversarial atomic snapshot. The CI step below does not execute this helper.

## Root-selector proposal

`select_sdk_roots.py` receives an explicit JSON request. Full physical SDK and `.xctoolchain` roots are
proposed; selected Swift, Clang and libIndexStore must share that toolchain. Commands preserve selected
driver spelling while guards bind canonical binaries. xcrun is separately hashed, not falsely included
in the toolchain tree. Canonical input/output overlap is rejected before writing, including compiler
aliases outside the physical toolchain and CLI request/runner aliases.

The selector retains SDK path/version/build, Clang resource-directory, Swift target/resource paths and
ordered preprocessor search directories. C, Objective-C, C++ and Objective-C++ are mandatory. Explicit
search flags and a small allowlisted set of language options are supported; other flags are refused.
Ignored nonexistent search directories remain explicit unsealed-absence dependencies. Unexpected
existing paths outside declared immutable/project roots refuse the proposal. No root is auto-added.

Fixed search-override environment keys are removed only in compiler children. The selected
DEVELOPER_DIR is explicit. Inherited environment values are not dumped. Full tool hashes and root
aliases are guarded around completed probes. Completed nonzero outcomes and any failed post-guard
are retained separately. Incomplete attempts preserve exit 125 and record post-guard unavailability
when cleanup is unproved. The existing reviewed runner's process-group fallback does not guarantee
containment of detached macOS descendants.

Every successful result says `awaiting-root-review`, `accepted=false`, `final_protocol_ready=false`.
Actual roots, all cross-root links and ignored absent paths still require review and a separately
frozen full-content seal. Project-generation manifest references are not SDK content seals.

## Native discovery recipe

`Scripts/validate-native-sdk-discovery.py` reads only the already completed mixed-iOS validation's
`restored_rebuilt` generation under `fresh-shared-v2`. Its source, index, outputs, compiler identities,
commands and helper bytes are verified before and after discovery. Exact commands must match the
repository's fixed six-command fixture plan; unexpected flags, paths or toolchains refuse execution.
No source edit, rebuild, module-cache reset or index generation is started.

The explicit request is:

- SDK/target: the accepted setup's iPhoneSimulator SDK path/version/build and target triple
- TOOLCHAIN: the common physical `.xctoolchain` ancestor of the accepted Swift/Clang/libIndexStore
- PROJECT: the restored fixture project, bound to the accepted source-manifest hash
- MODULES: the accepted generation's `Build/modules`, bound to its module-file hash dictionary
- Clang paths: `-I PROJECT/Sources/BridgeKit/include`
- Swift paths: `-I PROJECT/Sources/BridgeKit/include -I MODULES`
- Contexts: C and Objective-C defaults; C++ and Objective-C++ with `-std=c++17`; an additional
  Objective-C `-fobjc-arc` variant, matching the fixture's ARC and non-ARC source contexts
- Additional immutable roots: none; this corpus does not enable XCTest platform search flags

There are ten probes: three SDK queries, Clang resources, Swift target info and five language variants.
These are search-path/resource probes, not a re-execution of semantic compilation. Full original
compiler commands are retained separately. The selector and wrapper do not prove that these paths
form a complete dynamic-loader or OS dependency closure.

The selector child has a180-second wrapper deadline, each probe a60-second deadline, and the
outer supervisor a240-second deadline. Post-completion diagnostic text
reads are bounded to 4 MiB; whole-log identity is streamed separately with a 1 GiB per-file ceiling.
Oversized/nontext diagnostics do not erase the original process exit or elapsed cost. Hash-limit or
read-mutation failures retain a typed unavailable identity, never a partial hash. Publication-time
log identities are separate observations; a later readable log cannot upgrade the original unavailable
identity or make the publication successful. Original process exit and cost remain visible. These are not live output quotas. All failed work and full discovery/guard costs
are retained, with identical full elapsed cost assigned to both arms for future accounting. No timing
correction or cost subtraction is made. A failed or incomplete discovery cannot promote input state.

CI runs this diagnostic after all compiler/measurement work. A separate bounded supervisor records
original exit/completion, full elapsed cost, wrapper/runner and argv hashes, cleanup status and original
stdout/stderr byte hashes outside the discovery output. Pre-record malformed/missing input or overlap
refusals therefore remain durable without publishing raw console text. The supervisor preserves125.

Publication checks the explicit lifecycle and original attempt argv before creating staging. SDK,
toolchain and lifecycle destinations, including lexical/physical aliases, are refused. If the lifecycle
cannot supply its setup, only the explicitly selected CI scratch root's fixed sdk-discovery-public,
sdk-discovery-raw and sdk-discovery-attempt siblings are allowed; arbitrary destinations refuse.
Publication prepares a fixed-schema/hash-only attempt envelope in that separate safe directory.
Only a completely normalized discovery subtree is atomically added; blocked/missing inputs retain
explicit status and a red exit. A ready flag means the safe envelope is complete, not that discovery
succeeded. The upload may therefore preserve a failed attempt without exposing partial/raw files. It uploads no binary indexes, SDK files, toolchain executables, full environment
or raw fallback. Missing/pre-record/private evidence remains unavailable; a green normalization step
alone does not establish a valid root proposal. Moving `macos-latest`/newest-Xcode remains diagnostic.

## Offline controls

```sh
python3 -m unittest discover -s Scripts/benchmark-inputs -v
python3 Scripts/verify-sdk-discovery-contract.py
```

The first command covers32 seal and52 selector controls. Wrapper controls verify actual compiler
recipe binding, pre/post generation guards, nested125, source/index mutations, conservative acceptance,
normalized failure retention and credential-screen refusal. Actual Apple discovery failures are retained below. Actual root/link review, full content sealing, actual-arm calibration, independent
holdouts and the preregistered20-session performance gate remain open.

## First Apple discovery and bounded path diagnostics

Native run 38230196392 retains the first failure: all five initial probes and their terminal guards
passed, then Apple Swift 6.3.3's additional paths.sdkPath field was rejected. The original output is
retained byte-for-byte after public path normalization in fixtures/apple-swift-target-info-6.3.3.json.
The optional sdkPath field is now accepted only as a string resolving to the exact selected SDK.
Other unknown path fields, malformed values and a different SDK still fail.

A structurally valid but uncovered path now retains bounded metadata: printed path category, terminal
existence/type, component/link layout and canonical resolution outcome. No contents are read and no
root is added. All otherwise successful fixed probes continue to collect their path observations;
failed/incomplete probes still stop immediately. A proposal with any unresolved effective path remains
exit 1, accepted=false and final_protocol_ready=false. Metadata is capped at 128 observed bindings,
64 components per path and 1 MiB for the retained unresolved list; exceeding a limit fails rather than
publishing a truncated success. Original probe stdout/stderr remains retained.

Apple's output places /usr/lib/swift in runtimeLibraryPaths, while runtimeLibraryImportPaths names
toolchain/SDK module directories. The upstream Swift 6.3.3 implementation separately appends the Darwin
OS library location to runtime paths and constructs Swift-module import directories from toolchain
and SDK paths. See [the official implementation](https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/lib/Frontend/CompilerInvocation.cpp#L185-L267).
These labels distinguish reported path roles; they do not prove actual file access or a complete
runtime-loader closure for Apple's compiler binary. The actual host path existence/link layout still
requires the next native diagnostic. It remains outside declared roots and blocks final acceptance;
no runtime-root expansion or omission from the final input contract is authorized by this repair.

## Receipt-bound libc++ path normalization

Runs 38233336308 and 38236591686 retain completed SDK child exit1 but only two safe public
envelopes each. Detailed discovery is unavailable. The strict scanner reports hash-bound blockers
in setup/discovery/probes/clang-cxx.stderr, with suffixes /include/c++/v1 and /v1 respectively.
Neither suffix reveals its preceding raw path, the selector failure, or actual root/link layout.

A synthetic multi-path control covers both libc++ candidate families in the
[official LLVM Darwin driver](https://clang.llvm.org/doxygen/Darwin_8cpp_source.html): the compiler
folder's ../include/c++/v1 and the selected sysroot's usr/include/c++/v1. It includes ignored-directory
messages, quoted frontend arguments and ordered search-list entries together. This is a source-based
normalization control, not recovered Apple output or proof of Apple's exact driver implementation.

Publication derives CLANG_CXX_HEADERS from the exact selected Clang path/current compiler hash and
SDK_CXX_HEADERS from the exact selected SDK in both the sealed lifecycle and selector request.
Each full lexical prefix and its canonical form maps to the same family token. The selected SDK
itself may be an alias; the fixed header suffix must resolve to the corresponding canonical root
without further symlink traversal. Current root metadata detects replacement during staging; it is
not a content seal. All bindings and aliases are rechecked before the normalized tree is promoted.
No compiler search result is used to discover or automatically admit another prefix.

Only these two fixed full candidate families are mapped. Arbitrary parent segments, adjacent private
paths, credentials and nonmatching suffixes still block; the general privacy scanner is unchanged.
Raw hashes, ordered observations and distinct family tokens are retained. Missing directories can
be normalized without claiming that they exist. A fresh native attempt must verify publication;
previous unavailable details remain unavailable. SDK contents and any additional effective root
still require their separate review and seal before final comparison use.

## Selected compiler spelling in search diagnostics

Run 38240360620 publishes the full normalized SDK diagnostic (36 files and two envelopes). Eight
probes completed normally with passed terminal guards before C++ search parsing failed with
invalid-absolute-path. Its exact normalized Clang text and original/raw hash binding are retained in
fixtures/apple-clang-cxx-21.*. Expanding its tokens into synthetic fixture paths reproduces the
selected compiler's usr/bin/../include/c++/v1 refusal; this does not reconstruct private native prefixes.

Only that exact selected-compiler alias is now interpreted as its canonical in-toolchain path.
The parsed item preserves reported_path separately; ordinary clean_path still rejects parent segments.
The alias cannot add another root, another compiler or a suffix/parent escape. Canonical confinement
and all traversed directory identities (device/inode/mode, symlink targets and exact missing-prefix
states) are bound before the first probe and checked before/after each terminal probe and at completion.
Directory identity is not directory-content sealing; unrelated sibling writes do not prove path changes.
Existing header symlinks that change the canonical target are refused, including in-root redirects.

The native diagnostic directly observes /usr/lib/swift as a directory used for Swift runtime-library
search, with no content read. It remains an unresolved effective path. This observation establishes
neither executable loader closure nor SDK/root acceptance. The next attempt must still retain that
unresolved status and any further compiler context rather than silently broadening the root set.
