# Development workflow validation

Validation date: 2026-09-14. Development branch: `feature/change-impact-workflow`, based on
`de1bac9`. The changes are unreleased. After this iteration, the user clarified that most runtime dependencies
should be discovered automatically. The second implementation below adds automatic discovery and collection, while broad coverage of
all runtime frameworks is still unmet. This report measures technical behavior in the local
workloads below; it does not establish external adoption or general accuracy across Swift apps.

## Remaining code improvements implemented and verified — 2026-09-14

This is the latest local validation. The six requested improvements are implemented in their documented
supported forms: notification lifetimes, simulator failure paths, scanner responsibilities, generated
Core Data bindings, key paths/predicates, and immutable Swift Dictionary factory/router registries.
The development branch remains uncommitted and unreleased; earlier sections retain historical results.

Notification analysis handles immutable token aliases, same-branch removal, plain-do `defer`, direct
`AnyCancellable.cancel()` and compiler-confirmed direct `for await`. Simulator orchestration separates
process/time/file boundaries, refuses ambiguous PIDs, preserves cleanup failures, and recovers only an
app identified by the private collector and the current bundle PID. Fifteen focused tests and the
actual ten-case UIKit harness passed. Its run recorded 1,633 events and four exact local relationships;
framework startup event counts can vary. The dedicated device was shut down and its unique fixture removed.

Scope/name/receiver binding and syntax vocabulary now live in separate files, alongside the notification
lifetime tracker. The main scanner decreased from its expanded 1,890 lines to 1,137 lines; new scanners
reuse the parsed tree. This is a responsibility split, not a measured performance claim from file size.
Final dogfooding found a predicate wrapper/parser type cycle and a test-only initializer. The parser now
uses the common key-path grammar directly; production initialization uses one path, and fake linked-symbol
defaults were removed from production code and supplied explicitly by the tests instead.

Core Data evidence links the source/current model, compiled main-bundle model, generated sources, exact
module/index declarations and defined Swift/Objective-C symbols in the main executable. The actual CLI
harness checks preparation, discovery, impact, historical snapshots and fixed-path MCP use. Container/
context/request/fetch compiler references must agree with the verified model. Parent-entity fetches
include verified descendants; changed entity/context/request state and unknown escapes remain unresolved.
The tests reject an app with the expected model and index but without the linked generated class.
Classes defined only in dynamic frameworks are outside this version's proven scope.

The MCP server accepts a fixed project-contained evidence JSON at startup. Runtime/impact responses carry
separate `coreDataBuildEvidence` metadata, while `query`, `check` and base session scope remain unchanged.
Changing source, compiled model or the manifest inside the same server produces an error rather than a
cached success; restoring valid inputs recovers the result. Evidence verification does not execute the app.

KVC/predicate paths require all segments to bind through exact compiler types, final NSObject receivers,
explicit Objective-C properties and supported accessors. Only the last segment needs a setter for a write.
The intermediate target list is not a per-property write trace. The registry feature requires standard
Swift Dictionary identity, immutable bindings, literal keys and named function values. Ordinary scalar
dictionaries and unrelated aliases are silent; this is not generic third-party DI framework support.

| Final check | Result |
|---|---|
| Swift tests | **1,206 passed** |
| Unit-only line coverage | **86.53% (24389/28186)** |
| Unit + actual instrumented CLI integrations | **92.89% (26182/28186), 151 production files** |
| Existing runtime compiler/Foundation corpus | **TP59 / FP0 / FN0** |
| Separate key-path/predicate corpus | **TP12 / FP0 / FN0** |
| Separate immutable-registry corpus | **TP7 / FP0 / FN0** |
| Core Data generated-model/app/CLI/MCP assertions | **17 passed** |
| CLI, original false-positive, value-flow/bridge, impact/history, explicit runtime contracts | Passed |
| Self-analysis dead, module cycles, type cycles, rules, combined check | Zero findings |

These are separate bounded datasets, not a combined universal recall metric. Registry local aliases have
unit reference-shape coverage; they are not included in the seven actual compiler cases. Native C/UIKit
execution is not counted as Swift line coverage. Unit-only coverage decreased from the prior 87.54% while
process/SDK code grew; the larger integrated percentage does not hide that remaining unit-test gap.

Three private app scopes were checked again without source changes or app execution: 109/63/68 files,
the same six/zero/two automatic connections, no stale warnings, and nine independently selected source
expectations passed. The first app gained one dynamic UUID-selected callback-registry boundary (25 → 26).
Its target remains unresolved. These nine cases are not a full runtime inventory or adoption evidence.

The final uninstrumented idle benchmark contains **5,073 symbols / 26,984 edges / 161 indexed files**,
three samples of ten queries. CLI median **15.303 s**, MCP **1.810 s (8.45×)**, warm request **180.51 ms**.
Individual checks median **5.395 s**, combined check **1.649 s (3.27×)**. Result equality, stable input/session
generation and the unchanged 250 ms / 2× / 1.2× gates passed. These compare this tool's workflows only.

Final source hashes, metrics and evidence paths are recorded in
`/tmp/cartograph-residual-verification-summary.json`. Coverage is in
`/tmp/cartograph-residual-final-coverage.log`; its final integration pointer is
`/tmp/cartograph-residual-final-integration-path.txt` (`xQL4Va`). Self-analysis, other gates and benchmark
results are `/tmp/cartograph-residual-final-self/result.json`,
`/tmp/cartograph-residual-other-gates/result.json`, and `/tmp/cartograph-residual-benchmark/result.json`.
Simulator evidence is located by `/tmp/cartograph-simulator-failure-validation-path.txt`, including the
tested binary/relevant source hashes and a separate environment cleanup record.

This continuation removed **2.694 GiB of logical generated/temporary file size**. Final results, reproduction
corpora, the current project build and real-app indexes were retained. Exact manifests are
`/tmp/cartograph-residual-cleanup.json`, `/tmp/cartograph-coredata-cleanup-20260914.json`, and
`/tmp/cartograph-coredata-build-cleanup-20260914.json`. Earlier incomplete temporary attempts were removed;
later build/profile cleanup preserves result hashes and logs. Remote CI/release and physical-device
execution were not performed. Arbitrary heap behavior, external registries, all reflection/predicate
forms and unexecuted paths remain outside the supported claims.

## SDK notifications, model versions and coverage reuse — 2026-09-14

This is the latest measured source state. Earlier sections below retain their historical numbers and
limitations. The development changes remain uncommitted and unreleased.

Notification discovery now verifies a bounded table of exact SDK constants, specific AVFoundation
compatibility getters, `NSWorkspace.shared.notificationCenter`, and immutable local center/object
identities in the same straight-line scope. Fresh local registrations must precede their posts.
Actual Foundation probes exposed two false relationships: posting before registration and posting
after removing the directly bound observer token. Both have RED → GREEN regressions. Removal requires
the exact Foundation API, token registration location, same center and ordered source locations.
Token aliases, conditional/deferred removal and Combine cancellation are not definite lifetime evidence.

The expanded compiler/runtime corpus preserves **TP53 / FP0 / FN0**, with **45 automatic connections**
and eight existing compiler relationships. The removal mutation produced FP1 before the fix; two actual
function invocations produced callback counts `0,0`. This is accuracy on a bounded labelled regression
set, not recall across arbitrary runtime mechanisms or applications.

Core Data validation uses real `momc` generation/compilation and in-memory model object creation.
It verifies V2 `category` property generation, V2 → V1 current-version changes, marker impact selection,
captured snapshot comparison and `impact --since`. Inactive models retain migration review reasons.
Invalid/missing/excluded selections and symlink markers produce no class connections; filtering to one
version cannot establish it as current. The scanner follows observed Core Data behavior: `customClass`
is ignored, and generated class mode cannot be inferred from a same-named indexed manual class.
The local Xcode 27 `momc` rejects `codeGenerationType="manual"` with a diagnostic; the CI toolchain with
Swift 6.3.3 returned a nonzero exit without one. The harness records the exit code and output artifact
separately from the product check: Cartograph keeps this unsupported value unresolved.
Bare Swift names and actual Objective-C runtime identities are
distinguished. Category alias mismatch and generated class collisions are compiled negative cases.
The three local app scopes have no Core Data models or direct KVC calls; these are synthetic SDK/runtime
cases, not defects claimed in those applications.

The independent review also found that `coverage.sh --skip-test` could reuse an old merged profile after
source/binary changes. It now rejects newer source, test, fixture, skill, harness, binary and unit-profile
timestamps. Fixture build files follow Git ignore rules instead of a second build-directory list.
Fourteen isolated shell-boundary cases pass; their stub coverage values are never merged into product
coverage. On the real repository, fresh cached reporting exited 0, then rebuilding the CLI caused the
same cached report to exit 2. This is timestamp freshness checking, not protection against forged mtimes.

Final local evidence:

| Check | Result |
|---|---|
| Swift tests | **1,130 passed** |
| Unit-only coverage | **87.54% (20861/23830)** |
| Unit + instrumented CLI integrations | **91.96% (21914/23830), 136 production files** |
| CLI, discovery, Core Data, native collection/window, MCP | Passed |
| Original false-positive, value-flow/bridge, impact/history, explicit runtime contracts | Passed |
| Self-analysis dead, module cycles, type cycles, rules, combined check | Zero findings |
| Independent source-labelled real-app checks | **9/9**: four compiler relationships, five potential registrations/subscriptions |

The three real application scopes contain 109, 63 and 68 files. Automatic connections changed
**3 → 6**, **0 → 0**, and **0 → 2**, respectively, with no stale-input warnings. The middle app gained
an SDK subscription classification without an invented local post edge. Existing constructor injection
and direct enum-router calls were already represented in the compiler graph. The apps were not launched
or modified, and nine selected source expectations are not a complete runtime inventory or execution
coverage. Private app sources are not copied into this repository.

The final uninstrumented, idle-input benchmark covers **4,381 symbols / 23,148 edges / 146 indexed files**,
three samples of ten queries. CLI median **13.927 s**, MCP **1.753 s (7.94×)**, warm request **176.73 ms**.
Individual checks median **4.988 s**, combined check **1.485 s (3.36×)**. Equality, unchanged session/input
generation and the existing 250 ms / 2× / 1.2× gates passed. These compare this tool's workflows on one
local workload, not competing products or general developer productivity.

Evidence: `/tmp/cartograph-sdk-model-final-coverage.log`; the integration directory pointer is
`/tmp/cartograph-sdk-model-final-integration-path.txt`. Additional results are in
`/tmp/cartograph-sdk-model-other-gates/result.json`, `/tmp/cartograph-sdk-model-self/result.json`,
`/tmp/cartograph-sdk-model-benchmark/result.json`, and `/tmp/cartograph-real-app-bindings-final/`.
Coverage reuse regressions are `/tmp/cartograph-coverage-inputs-{red,resources-red,green}.json` and
`/tmp/cartograph-sdk-model-{cached-coverage,rebuilt-coverage-rejected}.log`.

This iteration removed another **3.152 GiB of logical generated file size**, preserving result hashes,
logs, reproduction sources, the current root build and real-app indexes. Exact path/active-handle checks
are recorded in `/tmp/cartograph-cleanup-20260914/coredata-intermediate-builds.json` and
`sdk-model-superseded.json`. The final integration results remain available. CI now includes the Core
Data and coverage-reuse harnesses; remote CI and release execution have not been performed.

Native C execution is checked by separate real execution harnesses, not counted as Swift source
coverage. The earlier ten-case UIKit Simulator evidence is retained; its collector/launch implementation
was unchanged in this iteration. Physical-device collection/validation remains unfinished, as do
arbitrary DI/router/plugin registries, complex KVC/predicates, generated Core Data class provenance,
entity-name fetch binding, broader notification lifetimes and external adoption evidence.

## Observation windows and framework bindings — 2026-09-14

The latest continuation adds three bounded capabilities and fixes concrete false evidence cases:

- **Interactive observation intervals:** `runtime collect --duration` works on macOS and iOS Simulator
  debug apps without adding an exit call. A private nonce/PID request and immutable acknowledgement
  seal a prefix of completed events. The v2 trace separates `evidenceComplete`/`observationWindow` from
  application success and keeps `collectionComplete` false. Late events, foreign requests, public or
  symlink request files, missing seals, invalid counts/hooks, lost metadata and changed inputs are tested.
- **Notification consumers:** compiler-confirmed `sink`/`onReceive` plus matching notification identity,
  default center and nil filter can connect a post to its callback's enclosing declaration. The local
  macOS app gained two such potential connections (1 → 3); the other two apps stayed at zero.
- **Manual Core Data and direct-key KVC:** resource entities link only to uniquely indexed Swift
  NSManagedObject subclasses. Model changes invalidate sessions/traces and survive snapshots.
  KVC links require a final NSObject receiver, explicit @objc property and unambiguous accessor/setter
  evidence. Actual Foundation execution verified accessor priority, Objective-C aliases and read/write
  behavior; readonly and unsupported setter paths remain unresolved. Older v2 declaration snapshots
  default missing `isFinal`/`isSettable` evidence conservatively.

The KVC counterexamples initially produced **four false-positive relationships**, which the expanded
labelled corpus rejected. After correction, the corpus reports **TP43 / FP0 / FN0**, with **35 automatic
connections**. Existing relationships were retained. This is recall on the supported labelled set;
custom DI containers, routers, complex key paths, general predicates and unexecuted paths are not part
of that denominator. The three local apps contain no Core Data models or direct KVC calls, so these
new framework cases were validated against compiler/Foundation fixtures, not misreported as app wins.

A native self-swizzling probe returned from `first` while the old collector incorrectly labelled the
replacement `second` as the callee. The collector now marks uncertain dispatch and omits that callee;
the resolver adds no observed connection from it. The native wire corpus fixes this regression alongside
seal-boundary tests. This does not claim complete detection of arbitrary concurrent runtime mutation.
A separate scanner regression stops literal Swift closure actions, such as `Button(action: { ... })`,
from being counted as unsupported Objective-C selector registration. Untyped action references can
still require review.

Final measured coverage: **1,106 Swift tests passed**, unit-only **87.19% (20351/23342)** and unit plus
instrumented CLI/automatic discovery/macOS collection/window/MCP execution **91.67% (21397/23342)**,
135 production files. UIKit execution is verified separately and is not merged into these percentages.
Coverage is not dependency recall, and additional process integration code does not turn into unit
coverage merely because its real execution harness passes.

The actual UIKit harness passed **10 cases**, including the original exit/failure contracts plus a
sealed window and early exit before sealing. Its exit-mode run contained **1,634 events / four exact
local connections**; counts can vary with framework startup. The timed test records a four-second
interval and verifies the exact `exerciseRuntime → work` connection. A shorter trial correctly excluded
that call when UI startup placed it after the seal; elapsed time was not treated as scenario completion.

Evidence: `/tmp/cartograph-expanded-verified-coverage.log` and the integration directory printed there
(pointer: `/tmp/cartograph-expanded-final-integration-path.txt`),
`/tmp/cartograph-expanded-simulator/result.json`, `/tmp/cartograph-expanded-self/result.json`, and the
real-app root at `/tmp/cartograph-real-app-validation-path.txt` (`runtime-final.json` per app).
Earlier native swizzle before/after evidence is under the directory named by
`/tmp/cartograph-dispatch-change-path.txt`. The optional external Needle probe was not run.

Generated artifacts are being cleaned with exact path ownership and active-handle checks. Superseded
Simulator failures were archived before removal; intermediate profiles/builds were removed while result
JSON hashes, logs and fixture sources were retained. Cleanup manifests are in
`/tmp/cartograph-cleanup-20260914/`. The current project build, real-app indexes and final evidence remain.
A USB-only inventory found no connected iOS device; wireless devices were not queried and physical-device
execution is still unverified. No production application source edits, signing changes, commits or releases were made.
Cleanup manifests record **3.98 GiB of logical generated file size removed**, with final evidence retained.

Final required gates passed: coverage and instrumented CLI contracts, original false-positive fixtures,
value-flow/bridge regressions, impact/history and explicit runtime contracts. Final self-analysis
`dead`, module cycles, type cycles, rules and combined check all returned zero findings
(`/tmp/cartograph-expanded-verified-self/result.json`).

The final uninstrumented, idle-input benchmark covers **4,327 symbols / 22,807 edges / 145 indexed files**,
three samples of ten queries. CLI median **13.733 s**, MCP **1.747 s (7.86×)**, warm request **174.61 ms**.
Individual checks median **4.995 s**, combined check **1.463 s (3.42×)**. Equality, unchanged session/input
generation, 250 ms warm latency, 2× query speedup and 1.2× check speedup gates all passed. This remains
a comparison of this tool's workflows on a local workload, not a competing-product benchmark.
Raw result: `/tmp/cartograph-expanded-verified-benchmark/result.json`.

## Simulator and local application follow-up — 2026-09-14

This follow-up adds iOS Simulator collection for installed debug scenario apps and recognizes
compiler-confirmed NotificationCenter publisher construction. It retains all 39 previously labelled
static relationships. Publisher construction produces a boundary, not an observed subscription or
callback edge. Physical devices, complete interactive GUI sessions and general framework coverage
remain unfinished.

- **1,077 Swift tests passed.** Unit-only coverage is **87.71% (19600/22347)**; unit plus instrumented
  CLI contract/discovery/macOS collection/MCP execution is **91.87% (20531/22347)**, 132 production files.
  The separate Simulator harness is not merged into these percentages. These are executed source
  lines, not runtime dependency recall. New process integration code remains outside unit coverage.
- The static compiler corpus preserves **TP39 / FP0 / FN0**, **31 automatic connections** and the
  original 39 expected relationships. There are now **64 boundaries**, with one additional publisher
  construction classification. Unsupported patterns remain outside the recall denominator.
- An actual UIKit app on **iOS 27 Simulator / arm64** passed eight execution cases: preserved return
  value, exact compiler identities, exit 7, crash, `_exit(0)`, timeout while ignoring SIGTERM, refusal
  to replace a running session, and installed executable mismatch. One run emitted **1,633 events**
  and **four exact local connections**, including both required `exerciseRuntime -> RuntimeTarget`
  lookup and `exerciseRuntime -> work` invocation edges. Framework startup event counts can vary.
- The simulator controller requires a booted iOS15+ UUID and matching installed executable, checks
  its bytes before/after, and only terminates a leftover process with the collected bundle/PID identity.
  A successful simctl invocation is not app success: explicit app exit code, PID and completed log
  must agree. Other injected DYLD libraries are rejected. Optional launch metadata preserves platform,
  PID, device and bundle identity; complete traces carrying launch metadata require a positive PID.
- Actual UIKit execution exposed valid nil-name lookup failures previously rejected by the parser.
  CLI and artifact reading now preserve these failed lookups; nameless successes are still invalid.
  An invalid public RuntimeTraceReport can no longer expose observed connections.

Three local application builds used isolated scratch/DerivedData directories, existing dependency
caches/local packages, and unsigned Debug configurations. Application source and configuration were
not edited, and the applications were not launched. Their reports used explicit production path
filters; the file counts below describe those selected analysis scopes, not every file in each repo.

| Local workload | Analyzed files | Boundaries before → after | Newly visible publisher sites | Automatic connections before → after |
|---|---:|---:|---:|---:|
| macOS display utility | 109 | 18 → 25 | 7: two lookupOnly, five dynamic | 1 → 1 |
| iOS application A | 63 | 7 → 8 | 1: dynamic | 0 → 0 |
| iOS application B | 68 | 4 → 4 | 0 | 0 → 0 |

The added eight boundaries improve visibility; **they do not add eight resolved dependencies**.
SDK notification constants, custom centers, object-filtered observers and downstream Combine callback
ownership remain unresolved where exact evidence is missing. Application B acquired one newer source
timestamp during validation; the tool reported staleness, then a fresh incremental build removed the
warning without changing its four boundary classifications. No independently labelled complete runtime
inventory exists for these apps, so this exercise cannot report real-app recall or claim adoption.

Reproduction and evidence:

```bash
python3 Scripts/verify-runtime-simulator.py --cartograph <built-cartograph> \
  --simulator <booted-dedicated-test-simulator-UUID>
Scripts/coverage.sh
```

The Simulator fixture uses a unique bundle ID and uninstalls only that fixture. The separately created
validation device was shut down afterwards. User simulator sessions were not modified. Simulator
results are in `/tmp/cartograph-simulator-final/result.json`; its separate environment cleanup record
is `environment-cleanup.json`. Final coverage is `/tmp/cartograph-runtime-followup-final-coverage.log`.
The real-app evidence root is recorded in `/tmp/cartograph-real-app-validation-path.txt`, including
before/after JSON, build logs and `summary.json`. Private application sources are not copied into this
repository. The changes remain uncommitted and unreleased.

All required local gates passed after the final change: coverage and instrumented CLI contracts,
original false-positive fixtures, value-flow/bridge probes, impact/history and explicit runtime
contract harnesses, plus self-analysis dead/module cycles/type cycles/rules/combined check (zero findings).
The optional external Needle probe was not run because no Needle source was supplied.

Final idle-input benchmark: **4,193 symbols / 22,023 edges / 142 indexed files**, three samples of ten
queries. CLI median **13.663 s** versus MCP **1.822 s (7.50×)**; warm MCP median **182.07 ms**.
Four individual checks median **5.704 s** versus combined **1.862 s (3.06×)**. The unchanged latency,
speedup, result equality and input-generation stability gates all passed. This compares this tool's
workflows on one local workload; it is not a competitor or general user-productivity benchmark.
Raw evidence: `/tmp/cartograph-runtime-followup-benchmark/result.json` and
`/tmp/cartograph-runtime-followup-self/result.json`.

## Automatic runtime discovery update — 2026-09-14

The second implementation adds automatic source/resource discovery and opt-in native execution
collection. Contract files are no longer required to find supported runtime relationships. This is
an improvement in the supported workflows; broad discovery across all Swift frameworks remains
unproven. In particular, the macOS collector does not launch iOS device/simulator apps, and custom
DI containers, Core Data models, URL routers, Combine streams, predicates and other framework
registries remain outside the claimed resolved set.

Evidence at the end of that earlier iteration:

- **1,068 Swift tests passed.** Unit-only line coverage is **88.73% (19496/21972)**. Including actual
  instrumented CLI contract/discovery/collection/MCP execution is **92.82% (20394/21972)** over the
  same 131 production files. No production files were excluded to meet the gate. The previous
  90.20% was a unit-only measurement of the smaller first implementation; it is not directly
  comparable to the new combined percentage. The native collector's compiled Objective-C behavior
  is verified by execution cases, not by treating its embedded Swift source string as native coverage.
- The independently labelled runtime corpus contains **39 expected relationships**, including
  compiler-known selector references. **TP 39 / FP 0 / FN 0**; 63 recognized boundaries, 31 new
  automatic connections, 8 existing compiler-reference findings. Separate classification tests
  cover dynamic names, unrelated centers/object filters, non-ObjC/generic/tuple methods, shadowed
  APIs and unknown receivers. Swift omits some local-function index references; those are reported
  as unindexed, not falsely resolved. Unsupported patterns are listed outside this denominator.
- Fresh before/after builds verify stale sources and v2 historical runtime evidence after deletion
  and rename. Interface Builder cases keep the correct controller for same-named actions/outlets.
- Native collection records **19 events and 6 exact local connections** in its application corpus.
  This includes dynamically assembled lookup names, class/instance selectors, two-argument methods,
  void/primitive returns and notification registration. Child-only events are excluded; app output
  and exit behavior match the baseline. Injection failure, timeout, app exit failure, source/index
  changes and binary changes produce partial evidence and exit 2. Incomplete/stale trace evidence
  contributes no observed connections.
- Original CLI contracts, original false-positive corpus, value-flow/bridge regressions, historical
  impact and explicit runtime contract harnesses passed. Self-analysis dead/module cycles/type
  cycles/rules/combined check all reported zero findings. One configured-source-scope limitation
  remains intentional.
- Five read-only MCP tools pass the live session/invalidation harness. Runtime collection is an
  explicit CLI action and is not exposed as an automatically executable MCP tool.

Final workload: **4,143 symbols, 21,767 edges, 141 indexed source files**, macOS arm64/Swift 6.4,
Debug binary, three samples of ten queries. CLI median **13.353 s** versus MCP **1.704 s (7.83×)**;
warm MCP request median **170.58 ms**. Four separate checks median **4.765 s** versus combined
**1.422 s (3.35×)**. All sample result-equality and session fingerprint/generation gates passed.
These timings exclude building the application and do not compare against a competing product.

Reproduction additions:

```bash
Scripts/coverage.sh  # unit percentage plus instrumented integration coverage
python3 Scripts/verify-runtime-discovery.py --cartograph <built-cartograph>
python3 Scripts/verify-runtime-collection.py --cartograph <built-cartograph>
python3 Scripts/benchmark-workflows.py --cartograph <built-cartograph> --project . --samples 3
```

Raw local evidence: `/tmp/cartograph-discovery-corpus-second/result.json`,
`/tmp/cartograph-runtime-coverage-integrated.log`, `/tmp/cartograph-runtime-final-benchmark/result.json`,
and the `cartograph-coverage-integration.*` directory printed by the coverage run. The CLI collector
and discovery harnesses retain their own logs and partial-output cases there. No commit, push,
release, re-signing of user applications or global configuration change was performed.

## What the first implementation covers

| Requirement | Implemented behavior | Scope of the evidence |
|---|---|---|
| Before-edit impact | `impact` follows direct/transitive consumers, projects protocol/override callers, expands selected types and extensions, and reports tests, entry points and runtime review facts. `snapshot`/`--before` preserve deleted/renamed declarations. | Pure graphs and a real multi-module compiler fixture. Historical/current graphs stay separate. Potential impact is not a deletion verdict. |
| Efficient AI access | Updated generated skill and four stdio MCP tools reuse preparation, batch queries, refresh changed inputs, and bound payloads with explicit omission/error information. | Modern and legacy protocol tests plus a live server before/after build. The server does not build targets or discover external consumers. |
| Runtime dependencies | Explicit contracts resolve their endpoints; plans bind source/index/graph/configuration and executable SHA-256. Checks distinguish observed, failed, missing, ambiguous and stale evidence. | Real Foundation selector/class lookup scenarios, including a change that compiles but fails execution. Application teams must supply their own tests and observation producers. |
| CI cost | `check` runs dead code, module cycles, type cycles and layer rules after one preparation. MCP sessions cache digests only behind filesystem identity/change checks. | Matched CLI/MCP responses and combined/individual diagnostics on the same input. `--since` is a report scope, not incremental analysis. |

## Reproduction

Run after building the development branch. Keep the project and compiler index idle during the
benchmark, and put benchmark output outside the project:

```bash
Scripts/coverage.sh
swift build
CARTOGRAPH="$(swift build --show-bin-path)/cartograph"
Scripts/verify-cli-contract.sh "$CARTOGRAPH"
Scripts/verify-fixtures.sh "$CARTOGRAPH"
python3 Scripts/verify-analysis-blindspots.py "$CARTOGRAPH"
python3 Scripts/verify-change-impact.py --cartograph "$CARTOGRAPH"
python3 Scripts/verify-runtime-contracts.py --cartograph "$CARTOGRAPH"
python3 Scripts/verify-mcp.py --cartograph "$CARTOGRAPH"
"$CARTOGRAPH" dead --strict
"$CARTOGRAPH" cycles --strict
"$CARTOGRAPH" cycles --level type --strict
"$CARTOGRAPH" rules --strict
"$CARTOGRAPH" check --strict
python3 Scripts/benchmark-workflows.py --cartograph "$CARTOGRAPH" --project . --samples 3
```

The benchmark requires at least three samples, CLI/MCP query result equality on every sample,
a stable session fingerprint/generation, query speedup of at least 2×, warm MCP request median
at most 250 ms, combined check speedup of at least 1.2×, and equal diagnostic multisets. It records
startup/preparation separately and compares repeated complete four-command workflows with repeated
combined checks. A failed speed gate does not suppress the remaining timing measurements.

## Failures the verification caught

- A compiler-emitted protocol-owner call incorrectly propagated an implementation change to sibling
  conformers; the real-index corpus exposed it.
- Type and extension names were incorrectly treated as ambiguous in impact selection/comparison.
- Historical comparison hid current source/index limitations; its status could also say no changes
  while runtime evidence was unresolved.
- Warm MCP requests hashed all input contents, and a second metadata refresh could label an old
  result with a new generation. The first measured query speedup was only 1.78×, below the goal.
- Content-only fingerprinting missed source timestamp changes that affect freshness reports.
- Swift `dynamic` was incorrectly accepted as Objective-C selector evidence. Native runtime probes
  reproduced the distinction from `@objc`/`@objcMembers`.
- MCP lifecycle shapes, large responses and nested external evidence needed explicit bounds.
- Self-analysis found an unused MCP helper and a type cycle between runtime CLI commands.

Each correction has focused regression coverage or an executable CLI/compiler fixture. The small
runtime fixture is not comprehensive runtime dependency discovery. The existing value-flow and
cross-language bridge corpus remains a separate regression check.

## Final measurements

All first-iteration acceptance gates passed on the measured source state; this does not establish
broad automatic runtime dependency discovery. The measured graph contained 3,370 symbols,
17,636 edges and 127 indexed source files. The repository configuration includes `Sources/**` and
excludes tests/fixtures from the analyzed graph; that scope limitation remained in every response.
The test coverage denominator separately excludes test-support code.

Environment: macOS 26.6.2, arm64, Apple Swift 6.4 (`swiftlang-6.4.0.27.1`). Debug build, same binary
and project/index for both paths, three samples, ten distinct USRs per query sample. These are
local workload measurements, not universal latency guarantees or measurements of a full Xcode build.

| Measurement | Separate CLI calls | Reused/combined path | Result |
|---|---:|---:|---:|
| Ten queries, median | 12.114 s | MCP 1.737 s | 6.97× faster |
| One warm MCP request, median over 30 requests | — | 173.48 ms | ≤250 ms gate passed |
| Dead + module cycles + type cycles + rules, median | 4.359 s | `check` 1.270 s | 3.43× faster |
| Initial MCP preparation, including discovery/status/lazy first query | — | 2.075 s | Measured separately |

Raw query samples (seconds): CLI `[12.052, 12.114, 12.271]`, MCP `[1.727, 1.737, 1.750]`.
Raw check samples (seconds): individual `[4.381, 4.359, 4.338]`, combined `[1.255, 1.270, 1.289]`.
Every CLI/MCP query sample matched, combined and individual diagnostic multisets matched, and the
session generation/fingerprint stayed unchanged through both measurements. Self-analysis had no
findings in this workload; positive diagnostic behavior is covered by the dedicated tests/fixtures.
The initial full-content-hashing implementation failed the 2× query goal at 1.78×; final speed ratios
above compare final CLI and MCP paths on the same inputs, rather than treating that older run as an
unchanged-source before/after experiment.

Final tests: **991 passed**, **90.20% line coverage (15909/17637), 118 production source files**.
CLI contracts, the original real-index corpus, value-flow/bridge regressions, the new change-impact
and historical-snapshot corpus, real Foundation runtime contracts, and live modern/legacy MCP all
passed. Dead-code, module-cycle, type-cycle and layer-rule self-analysis plus combined `check`
reported zero findings. The optional external Needle probe in the blindspot harness was not run;
it requires a separately supplied project and is not included in these claims.

The real-index impact corpus verified seven witness dependents and thirteen container dependents,
including extension callers in another module, tests, entry points and explicit truncation. A
fresh post-edit build preserved the deleted `legacy` member's historical `renderLegacy` caller and
the renamed extension member's historical consumers. The runtime corpus verified two successful
Foundation contracts, then rejected empty observations, a broken selector that still compiled,
stale plans, an old executable attached to a new plan, and a removed target.

Measured session input fingerprint: `9e57c9813e27d84475dc7c2eb666d9906b6ff4347a7ec1bc71c1431d37d2b7e2`.
Measured executable SHA-256: `693b5273f6d47975da42ba67bf3a3968e16189d47400fb486dee14f749539e8f`.

Raw session evidence is local and temporary: `/tmp/cartograph-workflow-final-measurement/result.json`,
`/tmp/cartograph-workflow-final-coverage.log`, and `/tmp/cartograph-workflow-*.log`. The commands above
produce fresh evidence. CI now runs the impact/snapshot, runtime-contract and MCP harnesses alongside
the existing checks. Both README languages, the generated skill and sibling handoff notices were
updated. No commit, push or release was performed.

The next product validation is external: measure task completion time, missed dependencies and
false alarms on maintained application repositories. These technical results support trying the
workflow; they do not establish that users will adopt it or that all runtime dependencies are known.
