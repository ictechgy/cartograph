---
name: cartograph
description: Use before deleting or editing Swift declarations, for change impact and runtime dependency preflight, when cleaning dead or unused code, and when asked who calls or depends on a declaration. Supports efficient MCP queries and CI checks.
---

# cartograph

`grep` finds text. The compiler index knows which declaration a name resolved to. Use this
tool for questions about Swift symbols, and use `grep` only for things that are genuinely
text — comments, strings, resource names.

## Before the first edit in a change

Start with the declarations or files the user intends to change:

```bash
cartograph impact <name-or-USR> --format json
cartograph impact --file Sources/Feature.swift --format json
```

Choose one selector mode. `selected` is the direct selection; `changeScope` adds members
and extensions when a type was selected. Neither field claims those declarations were
actually edited. `affected` contains potential consumers, with a `via` predecessor toward
a selected seed. A `dispatchContract` explains a possible protocol/override caller; its
depth counts an impact step, not every underlying override edge.

Read `tests`, `entryPoints`, `runtimeReview`, `runtimeDependencies`, `automaticRuntime`,
`observedRuntime`, `selectionIssues`,
`limitations`, and `truncated` with the result. Resolve incomplete inputs and inspect every
applicable runtime boundary. A depth or output cap is explicit; a capped list is not a
complete impact assessment. Query only the remaining questions, using `query --batch` for
several names. Do not query every affected symbol again when its evidence already answers
the question. Do not invoke an empty batch.

For deletions or renames, capture the old graph before editing:

```bash
cartograph snapshot -o .cartograph/before.json
# After the approved edit and a rebuild:
cartograph impact --since origin/main --before .cartograph/before.json --format json
cartograph check --strict
```

Comparisons keep `current` and `before` graphs separate. A missing current declaration can
be explained by its historical callers; an ambiguous selection still needs resolution.
Explicit unknown selectors exit 64; incomplete derived inputs or runtime evidence exit 2.
`--since` selects modeled Swift/Objective-C/Interface Builder and Core Data resource paths
(model contents and `.xccurrentversion`) and lists other changes
in `limitations`. `noChanges` means no modeled source was selected, not that every changed
script, configuration file or resource is harmless. Read `scopeDiff` for edges and
declarations that appeared or disappeared inside the selected change scope — impact
traversal alone cannot surface an edge removed between two changed files. Use full
`check --strict` for CI;
report scoping is not incremental analysis or a proof about everything a PR caused.

## Choose tests and mechanical fixes

After building the production and test targets, use one selector to find test consumers:

```bash
cartograph affected <name-or-USR> --format json
cartograph affected --file Sources/Feature.swift --format json
```

Read `tests`, `selectionIssues`, `limitations`, and `truncated` together. Tests must be
indexed and included by the configured path filters. An empty list means no test consumer
was found in this graph; it is not test coverage or permission to skip validation. Run the
relevant tests and add regression coverage for the behavior being changed.

For unused imports and parameter names, inspect a mechanical edit plan first:

```bash
cartograph fix --format json
# Apply only when these edits are within the user's requested scope:
cartograph fix --apply --format json
```

The default writes nothing. Review `edits`, `skipped`, and `limitations`; application removes
unused imports or internal parameter names while preserving argument labels. It does not
delete declarations or reduce public accessibility. Rebuild after applying and rerun the
relevant analysis and tests; a parsing check alone does not verify behavior. Do not force
skipped edits against a stale index.

`redundant-public` describes references observed within this repository. Before reducing
visibility, check external library consumers and public interface requirements. With
`retain_public: true` the rule stays silent because that public surface is intentional.

## Efficient MCP queries

When a Cartograph MCP server is connected, reuse it instead of launching one process per
question. Its tools are `cartograph_status`, `cartograph_query`, `cartograph_impact`,
`cartograph_check`, and `cartograph_runtime_discover`. Analysis tools return `{session, result}`; inspect the metadata of
the same result instead of issuing an extra status call after every question.

`cartograph_query` accepts a batch of symbols. Keep `symbol count × limit` at or below
1000; split larger batches. `cartograph_check` bounds displayed diagnostics while keeping
full counts and a `truncated` flag. An impact tool can also accept an inline
`runtimeContracts` array as declared evidence. The server refreshes changed analysis
inputs, but never runs a build. After source edits, build the affected targets before
treating the new index as evidence about the edit.

## Verify runtime dependencies

`impact` automatically follows validated Swift, Interface Builder and active manual Core Data
class connections.
`automaticRuntime` is static evidence; `observedRuntime` comes from an explicitly supplied
execution trace. Retention flags are review hints and do not prove a call occurred.
Inspect unresolved boundaries with `cartograph runtime discover` or the corresponding MCP
tool. Creating a selector token is not invoking its method, and registering an observer is
not delivering an event. Dynamic names, unknown receivers and unsupported patterns remain
unknown even when a report has many resolved entries.
A notification publisher needs a compiler-confirmed `sink`/`onReceive`, or direct
`NotificationCenter.notifications` consumption needs compiler-confirmed `for await`, before it
contributes a potential dependency. SDK-looking names, bare sequences and unsupported
collections remain unknown. Local centers/object filters require the same immutable class
construction. Immutable observer/cancellable aliases, removal and posting in the same branch,
a plain `do` whose `defer` has exited, and direct `AnyCancellable.cancel()` are modeled. Mutable
or reassigned tokens, uncertain branch merges, function-scope `defer`, other centers and custom
cancellation remain potential relationships. Registration is still not callback execution.

Literal KVC key paths use separate read/write operation kinds and resolve all segments or none.
Every intermediate needs an exact annotated final `NSObject` type and unambiguous `@objc`
property; only the final write segment needs a setter. A predicate contributes paths only for
inline or immutable local `NSPredicate(format:)`, complete bounded grammar, literal `%K`
arguments, a typed root, and exact constructor/evaluate compiler proofs. Do not interpret every
returned write target as a setter call: intermediate targets are read dependencies of one path.

Immutable standard `Swift.Dictionary` factory/router registries are supported only for literal
string keys and named top-level function values, with exact compiler references and standard
subscript proof. Immutable aliases may preserve that identity. This does not cover general DI
containers, closures, instance methods, mutable/dynamic maps or external registry frameworks.

Core Data `.xcdatamodeld` always requires a regular `.xccurrentversion`, even with one in-scope
version; it never falls back from a missing, invalid, excluded or nonexistent selection.
Standalone `.xcdatamodel` needs no marker. Manual/category classes use static model evidence.
Class-generated entities need opt-in `runtime prepare-coredata` evidence binding exact generated
source/module/USRs to the main app executable, main-bundle compiled model and container literal.
A proven immutable local `NSPersistentContainer(name:)` → `viewContext` → literal
`NSFetchRequest<NSManagedObject>` chain can then bind the fetch and default subentities. Mutated
request/entity/context state, classes only in dynamic frameworks and unsupported generated shapes
remain unresolved. The evidence augments `runtime discover`, `impact` or `snapshot` only; default
`query`/`dead` stays unchanged, and snapshots preserve verified generated source history.

`--trace` and `--coredata-build-evidence` cannot be combined. For MCP, the server owner may set
one project-contained JSON path with `serve --coredata-build-evidence`; clients cannot replace it,
and result metadata reports `.coreDataBuildEvidence` separately from the base session. The
notification, key-path and registry corpora contain 59, 12 and 7 bounded positive relationships.
These are separate regression sets, not a combined runtime-completeness percentage. Keep every
unresolved boundary in review.

When running an approved macOS debug test executable, automatic collection avoids manually
declaring every observed connection:

```bash
cartograph runtime collect --executable <debug-executable> --output /tmp/runtime-trace.json -- <test-arguments>
cartograph impact <name-or-USR> --trace /tmp/runtime-trace.json --executable <debug-executable> --format json
```

Collection launches that executable and builds its local collector with Clang. The MCP
tools do not launch it. Do not re-sign an app or weaken its entitlements to make collection
work. Injection failures, partial collection, wrong binaries and changed inputs are explicit
failures. For an approved, installed iOS Simulator debug test app, add
`--simulator <booted-device-UUID> --bundle-id <app-bundle-id>` and pass the matching build's
executable. The command refuses already running apps and verifies installed bytes. Default
Simulator exit mode requires `exit(0)`; simctl success alone cannot hide a crash or force-close.
For an approved interactive debug app, `--duration <seconds>` captures a bounded observation
interval and then stops that app. Its v2 `evidenceComplete`/`observationWindow` describe a sealed
interval; `collectionComplete` stays false and application/scenario success remains unverified.
Do not treat a sealed interval as a passed functional test or as coverage of unexecuted paths.
Physical iOS devices remain unsupported. Only instrumented APIs and
executed paths are observed. Trace evidence cannot be combined with `--before`, which may
describe another build.

Where the project has explicit runtime requirements and expected results, include those
contracts in preflight as well:

```bash
cartograph impact <name-or-USR> --runtime-contracts runtime-contracts.json --format json
cartograph runtime plan --contracts runtime-contracts.json --executable <built-executable> --strict -o plan.json
# Run the approved application scenarios, producing observations.json.
cartograph runtime check --contracts runtime-contracts.json --observations observations.json --executable <built-executable> --strict
```

The producer must report the actual executable's raw SHA-256 and the prepared plan
fingerprint. Never manufacture successful observations or attach a new plan to old test
results. Missing scenarios, stale inputs, a different executable, wrong result tags and
failed calls remain distinct failures. Coverage is only the required scenarios and the
built configuration. Unobserved does not mean unused. These contracts supplement impact
for that invocation; `dead` and `query` do not silently acquire new retention roots.

## Before deleting any declaration

After the impact preflight, run this and read the whole answer:

```bash
cartograph query <name-or-USR>
```

Then apply these rules. They are the point of this skill, and they apply to every
declaration you are about to remove, whether you got it from `query` or from a list
produced by `cartograph dead`.

1. **`state` is not a verdict.** `unreachable` means "not reachable from any retained root",
   which is a fact about the graph. It is not "safe to delete". Nothing in this tool's
   output ever says a declaration is safe to delete, and you must not infer it.

2. **A retained root is an entry point, a test, or a declaration a retention rule kept.**
   Public API is *not* a root unless the project turned it on — `retain_public` defaults to
   off. In a library or framework whose callers live outside this repository, that means the
   entire public surface is reported `unreachable` and deleting on that basis breaks every
   consumer. Check for `retain_public: true` in `.cartograph.yml`, or re-run with
   `--retain-public`, before you believe an `unreachable` verdict about public API.

3. **Read `limitations` in the same response.** It lists the channels this analysis cannot
   see, counted from the project you are in. If it names Objective-C sources, an
   `unreachable` Swift declaration may be called from a `.m` file the analysis never read.
   If it names Interface Builder documents, connections are matched by class name only. If
   it reports `index-staleness`, the index predates recent edits — rebuild first.

   Optional `localFunctionDiagnostics` identifies unrefined local functions by name,
   location, owner, reason, and suggested action. Read `totalCount` and `omittedCount`;
   absence means no detailed evidence was supplied, not proof that analysis is complete.
   Inspect the indicated source or rebuild as needed before relying on missing callers.

   Optional neighbor `referenceEvidence` lists actual relationship sites. The neighbor's
   own `location` is its declaration. Follow each item's `sourceUSR`, `targetUSR`, and
   `viaUSR`: a depth-2 consumer references the intermediate symbol, not the query target
   directly. Read `origin` and `omittedCount`; `unknown`/`graph` or a missing location
   is not a compiler-confirmed call site. Evidence identifies references, not safe edits.

4. **`suppressedByBaseline: true` means the team already decided.** Leave it alone. Do not
   re-litigate a decision that is recorded in the baseline file.

5. **`dependsOn: []` on a type does not mean it depends on nothing.** On a symbol-level
   graph a type's dependencies are held by its members. Follow `members`.

6. **`reason` tells you why something survived.** A value like `interfaceBuilder`,
   `objectiveCAccessible`, `codingKey` or `caseIterableEnumCase` means the compiler index alone
   may miss a runtime or synthesized dependency. Verify the relevant contract and tests before deletion.
   `externalBridge` means Dart, JavaScript or Kotlin calls it across a platform channel,
   according to a retentions file the project supplied (`external_retentions_path` or
   `--external-retentions`); run `cartograph dead --explain <name>` with that file in effect
   and it quotes which file and line does so. Without the file the same declaration comes
   back `unreachable`, which is the index's view, not the whole truth.

## When the rules pass

Passing the rules is not permission. The tool has told you what it can see; it has not told
you the code is unused. So:

- Delete only what the user asked you to delete, and validate the change with the relevant
  build and tests. A clean `query` result does not expand the user-approved scope.
- For a user-approved sweep, assess each finding, make only justified changes within that
  scope, and validate them. Present concrete candidates before expanding an unclear scope.
- If a limitation applies to the declaration in front of you, say so instead of deleting and
  hoping. "This is unreachable, but the project has 12 Objective-C sources this analysis
  does not read" is the useful answer.

## Answers this tool cannot give

- **Objective-C declarations.** Only `.swift` files enter the graph; `bridges` reads `.m`
  files for supported Flutter patterns and React Native export macros. Nothing here tells you
  whether a `.m` declaration is used.
- **Callers in another language.** A Flutter or React Native handler can be called from Dart
  or JavaScript. The Swift index does not record those calls; retention rules may keep the
  handler, but do not establish who called it. If the project has an
  `ios/` folder inside a Flutter or React Native app, or a `.m` file with `RCT_EXPORT_*`,
  treat `unreachable` on a handler as unknown. A retentions file being in effect
  (`limitations` lists `external-retentions`) does not change that for a declaration whose
  `state` is still `unreachable`: the join may have missed it, and `limitations` will say
  why (`external-retentions-unmatched`, `-ambiguous`, `-stale`). Only a `retained` or
  `retainedByMember` state with `reason: externalBridge` means the other side was found
  calling it (or one of its members).
- **Declarations behind an uncompiled `#if` branch.** The index store knows only the configuration
  that was actually built, so a declaration used only from a branch that did not compile looks
  unreached. Do not treat `unreachable` as settled for code inside `#if` until it has been built
  in that configuration.
- **Anything you changed in this session.** The index is written by the compiler at build
  time. If you edited Swift and did not rebuild, the answer describes the code as it was
  before your edit.
- **Whether a rename is safe.** Interface Builder outlets and actions are matched by class
  name, and `@objc` names are strings. Renaming can break the same connections that deleting
  would.

## Answering "who uses X?"

```bash
cartograph query MyType             # direct users and dependencies
cartograph query MyType --depth 2   # two edges out, in both directions
```

Each neighbour carries `edges` — every relation reaching it, such as
`["call", "overrides"]` — plus `module`, `depth` and its declaration site. Note that
`location` is where the neighbour is *declared*, not where it uses your symbol.

A name matching several declarations comes back as `status: "ambiguous"` with candidates.
Each candidate carries its `kind`, `module` and declaration site, because `qualifiedName` is
`Module.name` and leaves out the owning type — asking a real app about `body` returns 127
candidates of which 122 print as the same string. Read the locations, then ask again with
`Container.member` or with a USR. Never guess.

`truncated` says the answer hit `--limit`. Raise the limit or narrow the question; do not
report a truncated list as complete.

## Sweeping a whole project

Every entry in these lists is a declaration, so every rule above applies to every entry.
A long list is not a mandate.

```bash
cartograph dead --report-format json    # every unreachable declaration, with `limitations`
cartograph dead --explain MyType        # why one declaration survived, in prose
cartograph dead --since origin/main     # only what this branch touched
cartograph cycles                       # circular dependencies, with the link to cut
cartograph rules                        # layering violations
```

## Asking about many declarations at once

Do not loop `cartograph query` over a `dead` report. Each run reads the whole index again;
the answers are cheap and the preparation is not. On a 7,466-symbol app, asking about all
43 findings one at a time took 19.6 s and one batch took 0.47 s, with identical answers.

```bash
cartograph dead --report-format json | jq '[.diagnostics[].subject]' > /tmp/requests.json
cartograph query --batch /tmp/requests.json
```

The file is a JSON array of 1 to 1000 names or USRs. Results come back in request order
with duplicates kept, so you can pair the two arrays by index, and each element is exactly
what a single `query` returns — the rules above apply to every element. `ambiguous` is a
normal result. If one name is missing the exit code is 64 but every other answer is still
in the output, and the missing names are listed on stderr — read the output before reacting to
the exit code. A batch also answers every request from one snapshot, so a sweep cannot straddle
a rebuild.

## Do not read the whole graph

`cartograph graph --format json` emits every node and edge — tens of thousands of edges on
a real project. Loading that answers no question you could not answer with `query`, and it
crowds out the context you need to do the actual work. Ask about the symbol you care about.

## Exit codes

`0` success · `1` findings with `--strict` or a threshold exceeded · `2` tool failure, such
as a missing index store · `64` usage error, including a name that matches nothing.

A `64` from `query` means the name does not exist in the index. That is not evidence the
code is unused — the response lists the closest names as `candidates` and stderr repeats them,
so retry with one of those or with a USR, and check whether the target was built.

A `2` that says the index store knows none of this project's declarations means the tool
saw nothing at all. Do not treat it as "nothing is wrong". The message names what it read
and how many source files were in scope; the usual causes are a `--project` pointing at the
wrong directory, an index built for another checkout, and include/exclude patterns that
removed every file. Fix the cause rather than passing `--allow-empty-index`, which silences
the check and makes every later answer a statement about nothing.

## If there is no index store

Look for one before starting a build. An app already built in Xcode has a store under
`~/Library/Developer/Xcode/DerivedData/<name>-<hash>/Index.noindex/DataStore`, and Cartograph
finds it when `--project` points at the directory that holds the `.xcodeproj` or `.xcworkspace`.
In a Flutter or React Native app that is `ios/`, not the repository root, so try
`cartograph query <name> --project ios` before anything else. If the build used
`-derivedDataPath`, pass that directory with `--derived-data <path>`.

Only if none of that finds a store does the project have to be built:

```bash
swift build
xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
```

Then pass `--index-store <path>` if it is not found automatically. A full `xcodebuild` can
take minutes and needs a working signing setup, so ask before starting one.
