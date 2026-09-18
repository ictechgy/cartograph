# Cartograph

**A queryable dependency graph for Swift and iOS codebases.**

[한국어 문서](README.ko.md)

Cartograph reads the index store your compiler already produces and turns it into a graph you can
ask questions of. Unused code, circular dependencies, architecture metrics and layering rules are
not four separate tools — they are four queries over one graph.

```console
$ cartograph cycles --strict
Sources/Features/Home/HomeCoordinator.swift:14:1: error: Circular dependency: App.Home → App.Session → App.Home
    weakest link: App.Session → App.Home (reference, 2 references)

cycles: 1 error — module graph · 9 nodes · 36 edges
```

---

## Why another tool

[Periphery](https://github.com/peripheryapp/periphery) was the best unused-code detector Swift had,
and its archived source is still the best documentation of the problem. That repository is archived
under MIT; current development is a separate [commercial product](https://periphery.pro) with its own
terms. Cartograph is MIT-licensed and has no paid license or account requirement, including for
commercial projects. Cartograph is not a fork or a feature-for-feature claim about Periphery; it uses
the compiler graph for a broader set of questions.

Periphery's product sentence was *"find unused declarations."* The graph was a private means to that
end. Cartograph's is *"here is your dependency graph"* — and dead code is the first query on it.

What that buys you:

| | Periphery (archived OSS) | Cartograph |
|---|---|---|
| Dead code | ✅ the product | ✅ reachability from tagged roots |
| Why is this retained? | not answerable | `dead --explain` prints the reason or the path |
| Circular dependencies | — | ✅ with the weakest link to cut |
| Architecture metrics | — | ✅ Ca, Ce, instability, abstractness, distance |
| Layering rules in CI | — | ✅ ArchUnit-style rules in YAML |
| Who uses this symbol? | not answerable | `query` answers both directions as JSON |
| What will this change affect? | — | `impact` finds direct and transitive consumers before editing |
| How does a value reach this function? | not answerable | `dataflow` returns bounded interprocedural contexts as JSON |
| Callers in Dart or JavaScript | invisible | `bridges` exports the Swift side of a platform channel; `--external-retentions` reads the join back |
| Runtime or dispatch-only risk | — | `impact` marks runtime review targets and dispatch contracts |
| Graph export | — | ✅ DOT, Mermaid, JSON, self-contained HTML |
| SARIF for code scanning | — | ✅ |
| `@objc` retained by default | ❌ opt-in | ✅ on by default |

The retention rules — the genuinely hard-won knowledge about what *looks* unused but must not be
deleted — are absorbed wholesale. See [Retention rules](#retention-rules).

## Install

Requires macOS 14+ and a Swift toolchain (Xcode or the Command Line Tools) at run time —
Cartograph loads `libIndexStore` from it. Development uses Swift 6.4; CI selects the newest Xcode
installed on its runner and verifies the compiler-backed fixtures for that toolchain.
The tool process and `libIndexStore` must share an architecture. With an arm64-only toolchain on
Apple Silicon, run Cartograph natively; forcing its Intel slice through Rosetta cannot load that library.
Swift 5 language-mode projects are supported: build them with your Swift 6 toolchain (Swift 5 mode
is a compiler option, and the index it writes is read the same way) and analyze as usual.

**Homebrew** — a prebuilt universal binary, installs in seconds:

```bash
brew install ictechgy/tap/cartograph
```

**Mint** — builds from source, no tap to add:

```bash
mint install ictechgy/cartograph@0.17.0
```

**No install at all** — for a Swift package, add Cartograph as a dependency and use the command
plugin. Everyone on the team and CI then runs the same version:

```swift
// Package.swift
.package(url: "https://github.com/ictechgy/cartograph", revision: "0.17.0"),
```

```bash
swift package cartograph dead --strict
swift package cartograph graph --format mermaid > graph.mmd
```

It has to be `revision:`, not `from:`. Cartograph depends on `indexstore-db`, which publishes no
semantic-version tags and is pinned to a release branch, and SwiftPM refuses to resolve a
stable-version dependency whose own dependency is unstable:

```
error: … package 'cartograph' is required using a stable-version but 'cartograph'
depends on an unstable-version package 'indexstore-db'.
```

`revision:` takes the tag name, so the pin still reads as a version and still has to be raised by
hand at each release. The plugin declares no write permission, so it never prompts; redirect stdout
to save output.

**From source:**

```bash
git clone https://github.com/ictechgy/cartograph
cd cartograph
swift build -c release
cp "$(swift build -c release --show-bin-path)/cartograph" /usr/local/bin/
```

## Quick start

Cartograph never drives your build. It reads an index store your compiler already wrote, so it
cannot disagree with what actually compiled — and it does not fight Xcode over DerivedData.

**Swift Package Manager**

```bash
swift build          # SwiftPM writes an index store as a side effect
cartograph graph     # found automatically
```

> `-Xswiftc -index-store-path` is honored by SwiftPM's native build system but **ignored** by the
> Xcode-based one that became the default in Swift 6.4 — there the store goes to
> `<scratch path>/out` regardless. Rely on auto-detection, or pass `--index-store .build/out`.

**Xcode project or workspace**

```bash
xcodebuild build -scheme MyApp \
  COMPILER_INDEX_STORE_ENABLE=YES \
  -derivedDataPath DerivedData
cartograph graph --index-store DerivedData/Index.noindex/DataStore
```

Omit `--index-store` and Cartograph looks in the usual places — `.build/index/store`,
`.build/debug/index/store`, `.build/out`, and `~/Library/Developer/Xcode/DerivedData`.

Under DerivedData, Xcode names the directory `<name>-<hash>` after **the document it opened**, not
after the folder that holds it. So Cartograph tries every name the project root offers: each
`.xcodeproj` and `.xcworkspace` directly inside it, plus the folder's own name. That is what makes
`cartograph dead` work from a Flutter or React Native `ios/` directory, where the folder is `ios`
and the project is `Runner.xcodeproj`. Only the root is scanned, so a `Pods/Pods.xcodeproj` never
becomes a name.

A name-matched directory whose `info.plist` points back at this project through `WorkspacePath`
wins outright, and one that names a different workspace is never used. Among the candidates that
remain, Cartograph takes the most recently written one, because a stale index fails quietly rather
than loudly. The exception is ambiguity: if two or more name-matched directories are left and none
proves ownership through `WorkspacePath`, Cartograph lists them instead of guessing — the same
rule that makes `query` return candidates instead of a guess.
Recent SwiftPM writes an index automatically, so for a Swift package
`cartograph graph` alone usually works.

> **An index is only written when something compiles.** Building an already up-to-date package
> produces no new index data. In CI that is fine — a fresh checkout always compiles.
>
> **Index stores keep stale units.** Renaming or deleting a file leaves its old records behind, so
> a deleted type can linger as a phantom node. Build into a fresh scratch path
> (`swift build --scratch-path .build-fresh`) when a result looks impossible.

Then:

```bash
cartograph init          # write a commented .cartograph.yml
```

## Commands

### `graph` — render the dependency graph

```bash
cartograph graph --level module --format dot   -o graph.dot
cartograph graph --level type   --format mermaid            # paste into a PR description
cartograph graph --level symbol --format json  -o graph.json
cartograph graph --level module --format html  -o graph.html
```

Four resolutions: `module`, `file`, `type`, `symbol`. The HTML export is a single self-contained
file with no CDN references — it opens on an air-gapped machine and passes a security review.

### `cycles` — find circular dependencies

```bash
cartograph cycles --level module --strict
```

Reports a representative shortest cycle for each strongly connected component, plus the edge with
the fewest references as the cheapest one to cut. A component of twenty mutually tangled types is
technically accurate and practically useless; one concrete cycle you can act on is not.

`--explain <node>` answers the follow-up: which cycles this one node takes part in, and where to
cut each of them.

```console
$ cartograph cycles --level type --explain Alpha
App.Alpha is part of 1 cycle(s):
  App.Beta → App.Gamma → App.Alpha → App.Beta
      weakest link: App.Gamma → App.Alpha (call, 1 references)
```

### `dead` — find unused declarations

```bash
cartograph dead --report-format xcode
cartograph dead --explain UserRepository
```

Dead code is defined as *unreachable from a retained root*, not *zero references*. A cluster of
declarations that only reference each other has plenty of references and is still dead.

`dead` also reports parameters a live function's body never reads, as warnings under the
`unused-parameter` rule:

```console
Sources/Net/Client.swift:42:30: warning: parameter 'retry' of 'Net.Client.fetch(_:retry:)' is never used
```

The index does not record references to local symbols, so usage is proven by scanning the
function body itself. A parameter is reported only when its function is reachable; parameters of
protocol requirements (which have no body) and parameters in files that could not be scanned are
never reported. `unused-parameter` warnings are not counted toward `--strict` — the fix is a `_`
name, not a deletion.

`dead` also reports properties that are assigned but never read, as warnings under the
`assign-only` rule:

```console
Sources/Net/Client.swift:17:9: warning: property 'cacheKey' of 'Net.Client' is assigned but never read
```

The index records a read/write role on every property reference, so this check needs no source
scan. A property is reported only when it is reachable and every observed access is a write —
memberwise-initializer argument labels count as writes. Protocol requirements and witnesses are
excluded (reads through the protocol record on the requirement symbol), as are overrides,
runtime-managed declarations (`@NSManaged`, `@Observable`), Objective-C- and Interface
Builder-exposed members, implicit declarations, and stored properties of types whose synthesized
`Equatable`/`Hashable`/`Codable` conformances read them without leaving index evidence. Accesses
with ambiguous direction — `&x`, dynamic dispatch, macro-expanded or implicit references —
suppress the finding rather than guess. Like `unused-parameter`, these warnings are not counted
toward `--strict`: the fix may be an observation point, not a deletion.

`dead` also reports `import` declarations the file's references never use, as warnings under the
`unused-import` rule:

```console
Sources/Net/Client.swift:3:1: warning: import 'Combine' is never used
```

A Swift USR encodes its owning module, so the set of modules a file actually references is
recovered from the index; the `c:@M@M` marker an `import` itself leaves behind never counts as
usage. Because usage can also arrive through a re-export, reporting is deliberately
conservative: an import is reported only when the file's usage evidence is complete — no
unattributable references (clang/Objective-C USRs carry no module) and no referenced module the
file never imported. Conditional (`#if`) imports, re-exporting imports (`@_exported`,
`public import`), and imports marked `// cartograph:ignore` are never reported. Scoped imports
like `import struct Foundation.Bundle` are judged by their head module — a use of anything in
`Foundation` counts as use of the import — and the diagnostic spells the full form. Like the
other warning rules, `unused-import` does not count toward `--strict`.

`dead` also reports `cartograph:ignore` comments that suppress nothing, as warnings under the
`superfluous-ignore` rule:

```console
Sources/Net/Client.swift:41:1: warning: ignore comment on 'Net.Client' and 2 declaration(s) it covers is superfluous — removing it would report nothing
```

A comment on a declaration that ordinary references already keep alive does no work, yet leaves
the false impression that the code is dead. The check is counterfactual: the analysis re-runs
reachability with only that comment removed, and the comment is reported only when no new
finding appears — so a comment on genuinely dead code keeps suppressing it, and a comment whose
removal would expose an unreachable declaration is never flagged. Dead-code is not the only
counterfactual: test-only, assign-only-property and unused-import findings count too. A
declaration-level comment covers its whole member subtree — a member it ignores is folded into
that comment's judgement rather than treated as a comment of its own, while a member carrying
its own comment is judged separately. Since a retained member keeps its containing type alive,
an unreferenced type's own comment can be judged superfluous when a member's comment is doing
the retaining. A file-level `cartograph:ignore:all` comment is judged as
one file-scope unit and reported once; comments on individual declarations are judged
independently, even when every declaration in a file carries one. Like the other warning rules,
`superfluous-ignore` does not count toward `--strict`.

`--report-test-only` answers a different question: which production declarations are reached
**only** from tests or previews. They are not dead — deleting one breaks a test — but a team wants
to know that tests are the sole caller. Reported as `info`, so they never fail a build.

```console
$ cartograph dead --report-test-only
Sources/Models/Policy.swift:31:9: info: property 'App.isDenied' is reached only from tests or previews
```

Declarations inside test targets are excluded: a module that contains *test* declarations is a test
target, so its own helpers are not the answer to this question. Previews do not count for that
judgement — a `#Preview` lives in the production module beside the view it previews, so treating it
as a marker would drop the whole app module from the analysis.

`--explain` answers the question Periphery could not:

```console
$ cartograph dead --explain HomeViewController
Presentation.HomeViewController is retained because it is connectable from Interface Builder.

$ cartograph dead --explain UserRepository
Data.UserRepository is reachable:
  Presentation.HomeView → Domain.UserService → Data.UserRepository
```

### `query` — ask about one declaration

```bash
cartograph query UserService
cartograph query 's:3App11UserServiceC' --depth 2 --limit 20
cartograph query --batch requests.json
```

Three questions about one symbol — who uses it, what it uses, and whether it is reachable from a
retained root — answered as JSON on stdout. The other commands sweep the whole project and report
findings; this one answers a question you already have.

```console
$ cartograph query UserService
{
  "level" : "symbol",
  "limitations" : [
    "objective-c-sources: 12 file(s) are not analysed, so a Swift declaration used only from Objective-C looks unreached",
    "index-staleness: 3 of 214 source file(s) changed after the file's index unit was written, so a call added since the last build is not here yet"
  ],
  "requested" : "UserService",
  "result" : {
    "dependsOn" : [
      { "qualifiedName" : "Data.UserRepository", "module" : "Data", "kind" : "class",
        "edges" : [ "call", "reference" ], "depth" : 1, ... }
    ],
    "members" : [
      { "qualifiedName" : "Domain.fetch(id:)", "edges" : [ "member" ], "depth" : 1, ... }
    ],
    "reachability" : {
      "path" : [ "Presentation.HomeView", "Domain.UserService" ],
      "state" : "reachable",
      "suppressedByBaseline" : false
    },
    "truncated" : { "dependsOn" : false, "members" : false, "usedBy" : false },
    "usedBy" : [
      { "qualifiedName" : "Presentation.HomeView", "module" : "Presentation", "kind" : "struct",
        "edges" : [ "call" ], "depth" : 1, ... }
    ]
  },
  "status" : "found"
}
```

Five things this output does deliberately:

- **It never says a declaration is safe to delete.** `state` is a fact about the graph —
  `retained`, `retainedByMember`, `reachable`, `unreachable`. Whether that means deletable is a
  judgement, and the retention reason is given as a value (`"reason": "interfaceBuilder"`) so the
  caller can make it.
- **Every answer carries what the analysis cannot see**, including `notFound` — asking about a name
  that is declared in Objective-C and being told only "no such thing" would hide the difference
  between absent and invisible. `limitations` is counted from *your* project, within the same
  include/exclude scope the graph uses, so it stays quiet when there is nothing to warn about. It
  reports Objective-C sources, Interface Builder documents, sources edited since their own index
  unit was written, a package that exports library products while `retain_public` is off, a path
  filter narrower than the defaults, or an edge-kind filter — any of which could be the reason
  `usedBy` is empty. The default excludes alone do not count: they are a noise guard, not a
  narrowing you chose, and a warning that fires on every project is not read. File-level
  timestamps prevent a build of another target from hiding an edited file. `unindexed-sources`
  counts files without a known index unit; `missing-sources` counts indexed files that disappeared.
  `unreadable-sources` reports other read failures: declarations in those files are kept with
  reason `sourceUnavailable` until source access is restored and the analysis is rerun. These
  limits also appear in `dead` reports and on the other discovery gates: `cycles` and `rules`
  carry them in every format they emit, and `metrics` carries the same `limitations` key in its
  JSON and prints `Limitation:` lines under the table. A gate that passes while the analysis was
  blind is the one thing a gate must never do.
- **A baseline the team already accepted is marked as such** (`suppressedByBaseline`), so nobody
  re-litigates a decision that was already made. It is only set when the declaration would actually
  have been reported.
- **A neighbour carries every relation that reaches it**, not one of them. A subclass that both
  calls and overrides comes back as `"edges": ["call", "overrides"]`; reporting one would let you
  delete on half the picture.
- **A name matching several declarations returns the candidates, not a guess.** Ask again with a
  USR, or with `Container.member`.

```console
$ cartograph query Client
{
  "candidates" : [
    {
      "container" : "Network", "kind" : "class", "module" : "Network",
      "location" : { "column" : 7, "line" : 12, "path" : "/p/Network/Client.swift" },
      "qualifiedName" : "Network.Client", "usr" : "s:7Network6ClientC"
    },
    {
      "kind" : "class", "module" : "Storage", "qualifiedName" : "Storage.Client",
      "location" : { "column" : 7, "line" : 4, "path" : "/p/Storage/Client.swift" },
      "usr" : "s:7Storage6ClientC"
    }
  ],
  "level" : "symbol",
  "limitations" : [ ... ],
  "requested" : "Client",
  "status" : "ambiguous"
}
```

A candidate carries its `kind`, `module` and declaration site because `qualifiedName` is
`Module.name` and leaves out the owning type. Asking a real app about `body` returns 127
candidates of which 122 print as the same string, `HealthMap.body`; the location is what tells
them apart. You can then ask again with `Container.member` — `cartograph query
PersistentMapTabHost.body` — instead of copying a USR. Nesting works to any depth
(`Outer.Inner.leaf`), the outermost part may be the module, and an intermediate container may be
left out; if that still matches several declarations you get `ambiguous` again rather than a
guess. The container may be the type that an extension extends, so a member declared in an
extension answers to its type's name. `container` is there so the answer is self-sufficient:
typing `qualifiedName` back re-ambiguates at 122, while `container` plus the member name resolves
to exactly one. Candidates come in file and line order, because the location column is what a
reader scans. `dead --explain` prints the first 20 and says how many it left out.

`members` and `declaredIn` carry containment, which is not use. A type's own dependencies live in
its members on a symbol-level graph, so `dependsOn: []` on a class is normal and does not mean the
class depends on nothing — follow `members`.

`--depth` follows more than one edge in each direction and `--limit` caps how many neighbours come
back; `depth` on each neighbour says how far it was, and `truncated` tells you when the cap bit.
Reachability is always computed on the symbol-level graph — `query` takes no `--level` — so `level`
in the response always reads `"symbol"`. A neighbour's `location` is where it is *declared*, not where it uses
the subject. Fields with no value are omitted rather than set to null: `declaredIn` on a top-level
declaration, `reason` on one that is not retained, `path` on one that is not reached, and `result`
or `candidates` depending on `status`.

Optional `referenceEvidence` on `usedBy`/`dependsOn` neighbors supplies actual reference locations,
edge endpoints, the intermediate `viaUSR`, and provenance. It preserves all shortest-hop evidence;
an indirect neighbor is not presented as directly referencing the subject. Missing locations remain
absent. Evidence is limited to 20 records per neighbor and 200 per result, with `totalCount` and
`omittedCount` separate from neighbor truncation.

Optional `localFunctionDiagnostics` identifies unrefined local functions by name, declaration
location, owner, reason, and suggested action. All query statuses include it when details exist,
with at most 50 items and explicit total/omitted counts. Absent optional evidence means the producer
did not supply it; it does not prove completeness. See the [full contract](docs/QUERY-EVIDENCE.md).

An unknown name exits 64, so a typo in a script does not pass silently as "nothing uses it".

#### `--batch` — ask about many declarations from one index read

```bash
cartograph query --batch requests.json
```

`requests.json` is a JSON array of 1 to 1000 names or USRs, at most 1 MiB. Sweeping a `dead` report
one name at a time costs a process and an index read per name; the answers are cheap and the
preparation is not. On a 7,466-symbol app, asking about all 43 findings took 19.6 s one at a time
and 0.47 s in one batch, with identical answers.

```console
$ cartograph dead --report-format json | jq '[.diagnostics[].subject]' > requests.json
$ cartograph query --batch requests.json
{
  "format" : "symbol-query-batch",
  "results" : [ { "level" : "symbol", "requested" : "s:3App4FooV", "status" : "found", ... } ],
  "version" : 1
}
```

Results come back in request order with duplicates kept, so the caller can pair the two arrays by
index. Each element is exactly what a single `query` returns. An `ambiguous` name is a normal
result, not a failure. A `notFound` result carries `candidates` too — the closest names in the
graph, each with its `qualifiedName`, USR and location — so a typo can be retried without another
grep, and the single-query form echoes the requested name (and those suggestions) on stderr. If any
name is not found the exit code is 64, but **every** result is still
returned — one typo does not cost you the other forty-two answers. A malformed requests file is
rejected before the index is opened and exits 64, not 2, because it is an argument problem rather
than a failure to analyze. The names that were not found are listed on stderr, so a failed sweep
does not send you back to diff the JSON.

A batch answers every request from one snapshot. A sweep run one name at a time can straddle a
rebuild and answer half its questions from a different index.

This is the `symbol-query-batch` v1 format that dartograph writes, so an agent learns one response
shape rather than one per language.

`dead --report-format json` carries the same `limitations` list, so a sweep that starts from the
unused list sees what the graph could not, without a `query` per entry. So do `cycles`, `rules` and
`metrics` — they are CI gates too. Formats a CI job reads carry the list the same way: `text` counts them in the summary line and prints a `limitations:` block after it, `xcode`
emits a location-less `note:`, `github-actions` emits a `::notice` with no file so it lands on the
run summary, and `sarif` puts them in `runs[].invocations[].toolExecutionNotifications`. None of
that changes the exit code or the finding count. `checkstyle` is the exception: its schema has no
slot that is not a file's error, and adding one would raise the finding count its consumers show,
so pair it with one of the others when you need the limitations.

### `impact` — review change impact before editing

```bash
cartograph impact UserService
cartograph impact UserService --depth 3 --limit 500 --format json
cartograph impact --file Sources/Features/Home.swift --file Sources/Router.swift
cartograph impact --since origin/main --format json
cartograph impact UserService --before .cartograph/before.json --format json
```

Choose exactly one selector: one or more declarations, one or more `--file` paths, or
`--since <revision>`. File paths are resolved from the current working directory. The Git form
includes committed and uncommitted tracked changes and untracked files; deleted paths and both
sides of a rename are retained as seeds so an index that only contains the post-change tree cannot
turn a deletion into `noChanges`.
Modeled paths include Swift/Objective-C sources, Interface Builder documents, Core Data model
contents and `.xccurrentversion`; other changed files remain listed in `limitations`.

The graph still follows consumers in the whole project. `selected` contains the declarations matched
by the direct selector; `changeScope` expands a selected type to its semantic members and extension
members. Neither field means that those declarations were actually edited. `affected` reports
direct and transitive consumers outside that scope. Its `via` field names the predecessor toward the
selected scope, not necessarily the original seed. `depth` is the semantic impact step and can
collapse an override or protocol dispatch chain. Each entry carries every relevant edge. An optional
`dispatchContract` identifies the contract used for a dispatch projection; it is not an ordinary
call and does not prove that the runtime call occurred.

JSON output is a `change-impact` v1 document. Read `status`, `selected`, `changeScope`, `affected`,
`tests`, `entryPoints`, `runtimeReview`, `summary`, `selectionIssues`, `limitations`, and `truncated`
together. `selected` is the direct selector match; `changeScope` expands selected types to their
semantic members and extension members. Neither means that those declarations were actually edited.
`runtimeReview` keeps Objective-C, Interface Builder, dynamic dispatch, external bridge,
property-wrapper, Codable, preview, and other runtime-managed paths visible for manual or runtime
verification. It is evidence about possible impact, never a deletion approval or proof that runtime
coverage is complete. `--limit` bounds each output section, including selected/change-scope symbols,
files, modules and selection issues; summary totals remain available for the omitted entries.
`truncated.sections` identifies exactly which sections were capped, while depth truncation remains
separate.

An unresolved symbol or selected source file makes the document `status: "incomplete"` and exits 64
after printing the partial result. Rebuild the relevant target or inspect the pre-change index for
deleted and renamed declarations. A revision with no changed paths returns `status: "noChanges"`
with empty selection arrays. `impact` is a fact report, so it rejects `--strict`, `--report-format`, and
`--level`; `--format` accepts `text` (the default) or `json`, `--depth` accepts 1 through 128,
and `--limit` accepts 1 through 10000. `--runtime-contracts <path>` adds declared runtime
dependencies after validating the contract document; these declarations are evidence for this
impact run only and do not mutate the dead-code/query graph or retention policy.

With `--before <analysis-snapshot>`, current and historical graphs are analyzed separately and
reported under `current` and `before`. Deleted declarations can resolve from the old snapshot and
new declarations from the current snapshot. If an explicit input is missing in both snapshots, or
ambiguous in either, the comparison stays unresolved. An unresolved explicit input exits 64;
Git-derived selections and unresolved runtime evidence are incomplete analysis (exit 2). No path
or consumer is synthesized by unioning the two graphs.

Because impact only walks consumers of the changed set, an edge that disappeared between two
changed files never shows up in `affected` — both endpoints sit inside the change scope. The
`scopeDiff` section closes that gap by diffing the subgraph induced on the union of both change
scopes: `addedSymbols`/`removedSymbols` list declarations that exist in only one snapshot's scope,
and `addedEdges`/`removedEdges` list edge triples (source, target, kind) that exist in only one
graph. Edge kinds the other graph's filter could not have contained are not reported, and a filter
mismatch is called out in `limitations`. Each list is capped by `--limit`; the `*Count` fields and
`scopeDiff.truncated` keep the uncapped truth.

Nested runtime review evidence and contract ID lists also obey the output limit. Omitted entries
carry `externalEvidenceCount`/`externalEvidenceOmitted` or
`runtimeContractsCount`/`runtimeContractsOmitted`; caller omissions add to the producer's existing
`callersOmitted`. `truncated.sections` names `runtimeEvidence` or `runtimeContracts` when applicable.

### `snapshot` — capture an analysis input

```bash
cartograph snapshot --revision before-change -o .cartograph/before.json
cartograph snapshot --runtime-contracts runtime-contracts.json -o .cartograph/before.json
```

The v2 snapshot stores automatic runtime facts and their captured freshness, plus the enriched compiler index, edge selection, measured limitations, external
retentions and optional runtime contract declarations. `--revision` is a label supplied by you; it
does not query Git or a network. Historical source files are never read again. A snapshot always
uses the symbol graph and JSON output, so `--level`, `--report-format`, `--strict`, `--since` and
`--baseline` are rejected.

Older v1 snapshots remain readable and explicitly report missing automatic runtime evidence.
Snapshots are limited to 128 MiB and omit runtime `expectedValue` fields. If a current runtime
contract still requires a deleted target, historical callers do not cancel that broken contract.

### `check` — run the CI checks in one context

```bash
cartograph check --strict
cartograph check --since origin/main --strict
cartograph check --report-format json
```

`check` loads one analysis context and runs dead code, module cycles, type cycles and rules at the
configured rules level. Type cycles are always checked even when the module graph is clean.
`--since` remains a finding-location lens for this command; it is not incremental analysis. The
JSON document contains each check summary, one sorted diagnostic list, shared limitations and all
threshold failures.
Use `check --strict` without `--since` for the complete CI gate. Scoped cycle diagnostics include
a component when any participant's file changed, but scoped diagnostics do not prove every effect
of a PR was checked.

### `serve` — provide the agent tools over MCP

```json
{
  "mcpServers": {
    "cartograph": {
      "command": "cartograph",
      "args": ["serve", "--project", "."]
    }
  }
}
```

`serve` uses stdio and has no network or server-initiated requests. It supports modern
`2026-07-28` requests with per-request `_meta` protocol and client-capabilities fields, plus the
legacy initialization versions supported by the protocol. The session is created lazily, so
discover and tool listing work before a project is built. `cartograph_status`, `cartograph_query`,
`cartograph_impact`, `cartograph_check` and `cartograph_runtime_discover` return `{ "session": ..., "result": ... }` envelopes
(status returns metadata directly), and refresh automatically when indexed inputs change. Input
fingerprints are automatically re-verified at most once per second; calls inside that window
are answered by the last verified generation. `--session-freshness-interval <seconds>` tunes the window
(`0` re-verifies every request, values outside `[0, 86400]` are rejected). Pass
`refresh: true` to `cartograph_status` to bypass the
window and re-verify inputs immediately after an edit; subsequent tool calls then answer from
the refreshed generation. The server never starts a build. Query responses cap the shared `symbols × limit` budget at 1000;
MCP batches additionally share 200 reference-evidence and 50 local-diagnostic records across
all results, retaining each result's total and omitted counts. Re-query a symbol for more detail.
Check accepts a limit and reports full finding counts even when diagnostics are clipped.
Requests are limited to 1 MiB and encoded responses to 4 MiB. An oversized response returns an
explicit error asking for a smaller scope or limit; it is never silently cut. Runtime contract
labels allow 256 UTF-8 bytes and symbol/value strings 4096 bytes; byte limits also apply to
non-ASCII strings. Empty expected values are allowed.

Warm sessions cache file digests after checking device/inode, size, nanosecond modification and
change times, permissions and resolved path. Filesystems without these stamps are rehashed.
Sources and index-unit timestamps also participate in the input fingerprint so freshness reports
are refreshed. File enumeration still occurs; this is cached preparation, not incremental graph
analysis or an automatic compiler build.

### `runtime` — discover connections and collect execution evidence

```bash
cartograph runtime discover
cartograph impact ScreenController --format json
```

Discovery needs no contract file. It combines exact compiler references with Swift syntax and
Interface Builder object connections: class/protocol names, selectors, `perform`, target/action,
timers, notification observers/posts, and storyboard/XIB classes, actions and outlets. Immutable
names and simple string construction are followed; dynamic or ambiguous boundaries remain visible.
The report distinguishes resolved relationships, existing compiler references, selector tokens,
shadowed APIs, stale inputs and unresolved boundaries. The word `analyzed` does not mean every
runtime path is known. `--strict` fails when reported boundaries need review.
Notification names can match literals, proven local constants and a bounded set of SDK constants whose
exact compiler USRs are backed by installed SDK declarations. Arbitrary SDK-looking members and names
passed through collections remain unresolved. The default center and
`NSWorkspace.shared.notificationCenter` have stable identities. A locally constructed center or nonnil
object filter is joined only when the same immutable class construction is used in one straight-line
lexical scope and registration precedes posting; a property or parameter USR is not object identity.
Immutable observer-token aliases, removal and posting in the same branch, and a plain `do` whose `defer`
has exited are modeled. Direct `AnyCancellable.cancel()` ends a proven publisher subscription. Mutable or
reassigned tokens, uncertain branch merges, function-scope `defer`, other centers and custom cancellation
remain potential relationships. Registration and subscription are still not callback execution.

A notification publisher needs compiler-confirmed `sink`/`onReceive` consumption. A direct
`NotificationCenter.notifications` sequence needs compiler-confirmed `for await`; bare sequences remain
review inputs. Both require compatible name, center and object evidence.

Literal KVC keys can reference explicit `@objc` properties on final `NSObject` subclasses when accessor
dispatch is unambiguous. Dotted paths use distinct `keyPathRead`/`keyPathWrite` operations and resolve all
segments or none, up to 16. Every intermediate property needs an exact annotated final `NSObject` type;
only the final write segment needs a setter. All returned targets are dependencies of one path, so an
intermediate target in a write result is not a claim that its setter ran. Inline or immutable-local
`NSPredicate(format:)` contributes paths only when the bounded grammar consumes the whole format, `%K`
uses a literal string at the same argument position, the evaluated root is typed, and compiler references
confirm both predicate construction and `evaluate(with:)`. Collection operators, `SUBQUERY`, dynamic
formats and custom lookalikes remain unresolved.

Immutable standard `Swift.Dictionary` factory/router registries are supported for literal string keys
whose values are named top-level functions. Immutable aliases may preserve the same registry identity;
the compiler must confirm the declaration, value reference and standard `Dictionary` subscript. This is
not a general dependency-injection rule: closures, instance methods, mutable/dynamic maps, duplicate keys,
custom dictionary types and external registry frameworks remain unresolved.

Manual Core Data model entities can reference uniquely indexed Swift `NSManagedObject` subclasses.
For `.xcdatamodeld`, `.xccurrentversion` always selects the active model, even when only one model contents
file is in scope. The marker must be a regular, non-symlink binary or UTF-8 XML plist of at most 64 KiB;
missing, invalid, excluded or nonexistent selection never falls back. Standalone `.xcdatamodel` needs no
marker, while inactive versions stay visible for migration review. `category` generation can
join an existing Swift class only when its Swift and Objective-C runtime names agree. Generated classes,
`customClass` fallback, unsupported `manual` strings, ambiguous modules and entity-name fetch strings are
not guessed. Model contents and `.xccurrentversion` participate in session fingerprints, snapshots,
`impact --file`, `impact --since` and historical rebasing.

Class-generated entities require explicit current-build evidence. Prepare it from the selected source
model, literal container name, main app executable, exact generated class files and module:

```bash
cartograph runtime prepare-coredata --model Model.xcdatamodeld --container Store \
  --executable Build/MyApp.app/Contents/MacOS/MyApp \
  --generated-source Generated/Record+CoreDataClass.swift --module MyApp \
  -o .cartograph/coredata-build-evidence.json
cartograph runtime discover --coredata-build-evidence .cartograph/coredata-build-evidence.json
```

The `coredata-build-evidence` v1 document fingerprints the source model, selected version, current-version
marker, main-bundle compiled model, bundle, executable and generated sources. Generated USRs must belong to
the exact file/module and `/usr/bin/nm` must find their Swift metadata symbols defined by the main
executable; a class only in a dynamically loaded framework is unsupported without link-chain evidence.
With this opt-in evidence,
an immutable local `NSPersistentContainer(name:)` → `viewContext` → literal
`NSFetchRequest<NSManagedObject>` chain can connect a fetch to the verified entity and its default
subentities. Mutated request/entity/context state remains unresolved.

The same evidence option is accepted by current-build `impact` and `snapshot`; snapshots preserve verified
generated sources for historical comparison. It cannot be combined with `--trace`, and it does not change
the default `query` or `dead` graph. An MCP server may fix one project-contained JSON path with
`cartograph serve --coredata-build-evidence <path>`. Clients cannot replace that path, and
`coreDataBuildEvidence` metadata is reported separately from the base session.

`impact` automatically follows validated static runtime connections and reports their provenance
under `automaticRuntime`. Resource file selections include the Swift declarations their connections
reference. Unknown names and receivers remain limitations rather than invented edges.

For a **macOS debug executable**, collect actual events without manually authoring contracts:

```bash
cartograph runtime collect --executable .build/debug/MyApp --output /tmp/runtime-trace.json -- app-arguments
cartograph runtime discover --trace /tmp/runtime-trace.json --executable .build/debug/MyApp
cartograph impact ScreenController --trace /tmp/runtime-trace.json --executable .build/debug/MyApp --format json
```

`collect` builds a local native collector with the installed Clang toolchain and launches the supplied
executable. It records Foundation class/protocol/selector lookup, three `performSelector` variants,
and selector-based notification registration; application arguments and return payloads are not
recorded. App stdout/stderr go to stderr. Events from inherited child processes are excluded.
Lookup, registration and normally returned invocation are different evidence. A selector token does
not prove a method ran, and registration does not prove delivery.

The trace is tied to current source/index inputs and executable bytes. Missing injection, timeout,
app failure, dropped/corrupt events or changed inputs produce an explicit partial result (exit 2).
The collector does not re-sign an app or change entitlements. Hardened apps may reject injection.
An installed **iOS 15+ Simulator debug test app** can also be collected:

```bash
cartograph runtime collect --simulator <booted-device-UUID> --bundle-id <app-bundle-id> \
  --executable <matching-build/MyApp.app/MyApp> --output /tmp/simulator-trace.json -- test-arguments
```

The device UUID is explicit; the command does not boot devices or install apps. It refuses an already
running app and verifies that the installed executable matches `--executable` before and after the run.
In the default exit mode, use a test app that calls `exit(0)` after its scenario. Its exit code and completed
collector log must both be present: `simctl` can report success after an app crash. Force-closing an
interactive app, `_exit`, a crash or timeout produces a partial trace. Physical iOS devices and arbitrary
API instrumentation remain outside this collector's scope.

For an interactive debug app, add `--duration 30` to observe an interval after collector activation,
seal the trace, and stop the launched app. This works for macOS and Simulator apps without adding
an exit call. The v2 trace keeps `collectionComplete: false` and reports `evidenceComplete` plus an
`observationWindow`: a sealed interval is usable evidence, but does not verify application or scenario
success. Early exit, a missing seal, lost events, or changed inputs remain incomplete. Calls returning
after the seal are outside the interval. `--timeout` still bounds capture and must exceed the duration.
Existing DYLD injection libraries are rejected because competing hooks can hide events. Traces retain
the launch platform, process ID and, for Simulator runs, the device UUID and bundle ID.
Only executed paths and instrumented APIs are observed. Trace evidence is kept separate under
`observedRuntime`, and it cannot be mixed with `impact --before` from a different build.

Teams can still define explicit requirements and expected results when they need scenario assertions:

```bash
cartograph runtime plan --contracts runtime-contracts.json --executable .build/debug/MyApp --strict
cartograph runtime check --contracts runtime-contracts.json --observations runtime-observations.json \
  --executable .build/debug/MyApp --strict
```

See [runtime discovery, collection and contracts](docs/RUNTIME-CONTRACTS.md), the
[notification/runtime corpus](Fixtures/RuntimeDiscoveryCorpus/README.md), the
[key-path corpus](Fixtures/RuntimeKeyPathCorpus/README.md), and the
[immutable-registry corpus](Fixtures/RuntimeRegistryCorpus/README.md). They currently contain 59, 12 and
7 supported positive relationships respectively. These are separate bounded regression sets, not a
combined runtime-completeness percentage or a claim that every runtime mechanism is known.

### `dataflow` — trace values across function boundaries

```bash
cartograph dataflow UserService.fetch
cartograph dataflow Worker.run --max-contexts 1024 --max-iterations 20000
cartograph dataflow 'Worker.run()' --call-depth 4
```

`dataflow` answers a different question from `query`. The symbol graph and its `dependsOn` edges keep
their meaning; this command builds a separate, bounded value graph for one function and always emits
JSON. The response includes context summaries, argument-to-parameter and return-to-call links,
callbacks, `inout` writes, and field aliases. A value that crosses an unsupported or ambiguous external
call remains unknown, as does a stale declaration or a result cut off by a context, iteration, value,
or heap budget. A missing function is an explicit `notFound` result with exit code 64; a function with
no known entry context gets an explicit requested context with unknown inputs and external state.

`selectedContexts` identifies the requested function's contexts inside the evidence graph. Each context
includes memory effects before and after the call. Unsupported dynamic class dispatch, mutable value
types, inherited initialization, observers/macros, and unresolved literal types stay unknown. The
`bridges` command uses a computed string only when all analyzed contexts at that source expression
agree; a wrapper called with different names remains dynamic in bridge-facts v1. See the
[measured scope and comparison](docs/scans/2026-09-value-flow-comparison.md).

The defaults are 512 contexts, 10,000 iterations, 32 values per node, 10,000 heap cells, and call-string
depth 2. `--call-depth` accepts 1 through 8. The command rejects `--level`, `--since`, `--report-format`
and `--strict`: value analysis has its own context graph, answers one subject, and is JSON-only. The
same policy holds across the CLI — a command that cannot honor a flag rejects it with exit code 64
rather than silently ignoring it: `query` refuses `--report-format` and `--strict` (the answer is
always JSON, and it answers facts, not findings), and `graph` and `bridges` refuse `--report-format`
(the document format is `--format` there) and `--strict`.

### `bridges` — export native bridge evidence

```bash
cartograph bridges                       # bridge-facts JSON on stdout
cartograph bridges --format text         # one line per fact, for a quick look
cartograph bridges --target flutter      # split one mechanism from a mixed project
cartograph dead --external-retentions .isthmus/retentions.cartograph.json
```

A Flutter method-call handler or a React Native module is called from Dart or JavaScript, which
the compiler index cannot see, so it is reported unreachable. The only thing that links the two
sides is a string: the channel name in `FlutterMethodChannel(name:)`, the `case "takePhoto":` in
the handler, the `@objc(CalendarManager)` on a class, the `RCT_EXPORT_METHOD(addEvent:)` in a
`.m` file. `bridges` reads those literals out of the sources with SwiftSyntax (and scanners for
Objective-C Flutter handlers and React Native export macros), attaches the USR the index has for
the enclosing declaration, and writes the
`bridge-facts` exchange format that [isthmus](../isthmus) joins with the other platform's facts.

The exported `project` is the root's POSIX `realpath`, resolving symlinks so `/tmp` and
`/private/tmp` identify the same project across producers. An unresolvable root is an error.
Fact locations remain relative to the project. Consumers still require exact `project` equality;
normalization does not combine different plugin or monorepo roots.

The v1 extension in 0.9.0 adds optional `limitationScopes`, each binding a `limitationIndex`
to an exact `channels` array. This is an upper bound on the entire gap, never a list of names
merely found in unread code. External-object or factory-supplied Swift handlers produce a scoped
`opaque-handler-bodies` gap only when every affected registration channel is known. Any unknown
channel leaves that gap unscoped; unscoped gaps continue to apply to the whole target.

Swift bridge-name resolution follows immutable `let` aliases and parentheses within one file
(up to 64 steps), joins `+` concatenation when both sides resolve (a resolved head alone stays
as the name's prefix), resolves a property only ever assigned its initializer's parameter
(`self.x = arg`) through `Type(label:)` call sites, and attributes a handler's `call`-unchanged
one-hop forward (`Task { await handleAsync(call, …) }`) to the registered channel. Mutable
strings, unknown shadowing bindings, other operators, interpolation, disagreeing call sites and
cross-file values remain dynamic. See the [constant/Needle/storyboard checks](docs/scans/2026-09-analysis-blindspots.md).

When a dynamic Swift name comes from a fresh indexed source, `bridges` also runs the bounded
interprocedural value-flow analysis and applies a name only when every analyzed context agrees on
the same exact string. Supported argument, return, callback and memory paths can therefore resolve
names across functions; disagreement, unknown values, unsupported syntax, stale sources and an
exhausted analysis budget remain `dynamic`. See the [interprocedural analysis check](docs/scans/2026-09-interprocedural-flow.md)
for runtime comparisons and scope.

`cartograph bridges --messages --target flutter` is a bridge-facts v2 extension for Flutter
`BasicMessageChannel` and Pigeon handlers. It emits `message-handle` facts
without a synthetic method, plus a closure range and the call/reference symbols observed at those
source locations in the compiler index. The existing enclosing setup symbol remains in every fact;
when the range and index evidence are incomplete, consumers must keep the broad setup impact and
report the gap. Dispatch candidates are included only for actual index `overrides` relationships.
The current scope was verified against the public `url_launcher_macos@3.2.2` generated Swift source;
it is not a published compatibility promise for every Pigeon form.

Objective-C Flutter scanning supports direct channel construction, inline handler blocks and
same-file registrar/delegate `handleMethodCall:result:` implementations, including file-local
immutable `NSString *const` names. Positive `isEqualToString:` branches become facts with
`sourceLanguage: "objective-c"` and an actual Clang `c:` USR when the index uniquely identifies the enclosing declaration.
When it cannot — no index for that file, a stale line, or an ambiguous match — the fact still carries the syntactic
qualified name (`Plugin.handleMethodCall:result:`) as a name-only symbol, mirroring Swift facts. The name is deterministic
from the source; a wrong USR is worse than none, and USRs are never guessed. Conditional or macro-dependent
files, rebinding and unsupported delegation remain uncertain. The general `objective-c-sources`
gap stays unscoped even when some literals were extracted. See the [bounded scan results](docs/scans/2026-09-objc-flutter.md).

Deploy an isthmus version supporting this extension before deploying the new producer. Old v1
consumers keep the broad limitation behavior; old isthmus cannot distinguish ObjC graph scope and may fail
on missing symbols or emit Clang retentions that the Swift graph cannot apply. New isthmus keeps their join evidence, omits them from Swift-only
retentions, and reports `omittedObjectiveCHandlers`; cartograph exposes that count as a limitation.
Unmarked Swift handlers without a symbol still fail retention generation.

```console
$ cartograph bridges
{
  "facts" : [
    {
      "channel" : "com.example/camera",
      "dynamic" : false,
      "kind" : "method-handle",
      "location" : { "column" : 18, "line" : 26, "path" : "CameraPlugin.swift" },
      "method" : "takePhoto",
      "symbol" : { "qualifiedName" : "CameraPlugin.handle", "usr" : "s:3App12CameraPlugin…" }
    }
  ],
  "format" : "bridge-facts",
  "generatedAt" : "2026-09-04T00:00:00.000Z",
  "limitations" : [ ],
  "platform" : "swift",
  "project" : "/app/ios",
  "target" : "flutter",
  "tool" : { "name" : "cartograph", "version" : "0.17.0" },
  "version" : 1
}
```

It states facts, not verdicts: it does not know whether anything on the other side calls the
handler. A name that is not a literal is kept with its source expression and `dynamic: true`
rather than dropped, so the consumer can count what it could not join. One level of constant is
followed (`static let name = "…"` used as `FlutterMethodChannel(name: Self.name)`); anything deeper
is `dynamic`. A `case "…"` outside a handler closure counts only inside a function that takes a
`FlutterMethodCall`; it is attributed to the file's single channel when there is exactly one, and
to `null` otherwise. Creating a channel without attaching a handler is not a fact. `limitations`
counts the dynamic names, the unattributed and inferred channels, the Swift handlers with no USR (Swift
not rebuilt since the edit; Objective-C handlers with a name-only symbol are counted under
`objective-c-handlers` instead), the `@objc(Name)` classes assumed to be React Native modules, the
`FlutterEventChannel`s and Pigeon `BasicMessageChannel`s this format does not cover, the
Objective-C handlers that cannot be retained through a retentions file, and a project that mixes
Flutter and React Native.

Fact locations are project-relative and `generatedAt` is normalized to UTC milliseconds. When a
project contains more than one bridge mechanism, pass `--target flutter` or
`--target react-native` before feeding the document to isthmus v0.1. The targeted document reports
the number of omitted facts under the `target-filter` limitation.

Within `--target react-native`, Expo Modules are marked with `mechanism: "expo"` on the
name-boundary facts (`module-export`, `component-export`); omitted means core React Native.
A `Module` subclass is recognized by its `definition()` builder (`Name`, `View`,
`Function`/`AsyncFunction`, …) or the `@ExpoModule`/`@JS` macros, gated on
`import ExpoModulesCore` so lookalike names elsewhere stay silent. The module name follows
Expo's rules — `Name(...)`/the macro argument, otherwise the class name — and a `View`
definition exports a component under the module name, which is what
`requireNativeViewManager(moduleName)` looks up. `method-handle` facts carry no `mechanism`
per the exchange contract. A module that defines several `View`s is represented by the first
one — secondary views are only reachable through `requireNativeViewManager(module, viewName)`
and are not separate name-boundary facts.

isthmus hands back `external-retentions`: for each Swift declaration it found a caller for, the USR
and the evidence. `--external-retentions <path>` (or `external_retentions_path` in the
configuration) turns each into a retained root with reason `externalBridge`, and `--explain` quotes
the evidence rather than pointing at the file:

```console
$ cartograph dead --external-retentions .isthmus/retentions.cartograph.json --explain CameraPlugin
App.CameraPlugin is retained because its member App.init(messenger:) is called from another platform across a bridge, per the external retentions file.
  evidence: dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'
```

When the other side calls from several locations, `evidence` carries every call site in `callers` (plus
`callersOmitted` for what the producer's cap left out) and `--explain` lists them, keeping the line short
with a `+N more` marker; a single-caller document renders exactly as before.

A path that is configured but missing is a tool failure (exit 2), not a silent no-op: someone who
supplied the file expects it to be applied. `query` lists the file's provenance under
`limitations`, along with how many of its retentions name no declaration in the index — a renamed
handler shows up there before it shows up as a bug.

### `skill` — teach a coding agent to use this

```bash
cartograph skill
```

Writes `.claude/skills/cartograph/SKILL.md` into the project. The same file is in
[`Skills/cartograph/SKILL.md`](Skills/cartograph/SKILL.md) if you would rather read it first; a test
fails if the two ever drift, so what you review is what gets installed. `--project ~` installs it
for every project instead of one.

Most of the skill is not about which command to run. An agent turns a verdict into an edit without
pausing, so the file spends its length on what an answer does *not* prove: that `unreachable` is a
fact about the graph rather than permission to delete, that `limitations` must be read in the same
breath, that `suppressedByBaseline` means the team already decided, and that dumping
`graph --format json` into a context window answers nothing `query` could not.

### `metrics` — architecture metrics

```bash
cartograph metrics --level module
```

Robert C. Martin's package metrics, computed on your graph. Run against this repository:

```
NODE                   Ca  Ce     I     A     D           ZONE
---------------------  --  --  ----  ----  ----  -------------
CartographCore          8   0  0.00  0.04  0.96   zone-of-pain
CartographAnalysis      2   1  0.33  0.00  0.67   zone-of-pain
CartographConfig        1   1  0.50  0.00  0.50   zone-of-pain
CartographIndexStore    1   1  0.50  0.00  0.50   zone-of-pain
CartographSyntax        1   1  0.50  0.00  0.50   zone-of-pain
CartographExport        1   2  0.67  0.06  0.27  main-sequence
CartographKit           1   5  0.83  0.00  0.17  main-sequence
CartographTestSupport   0   1  1.00  0.00  0.00  main-sequence
cartograph              0   3  1.00  0.00  0.00  main-sequence
```

`CartographCore` sitting deep in the zone of pain is honest: it is a concrete domain model that
everything depends on. The metric is a question to answer, not a rule to obey.

### `rules` — enforce architecture in CI

```yaml
# .cartograph.yml
layers:
  - name: Presentation
    match: ["Features/**", "*ViewController"]
  - name: Domain
    match: ["Domain/**"]
  - name: Data
    match: ["Data/**", "*Repository"]

rules:
  - name: Presentation must not reach the data layer directly
    from: Presentation
    deny: [Data]
  - from: Domain
    allow: []          # the domain layer depends on nothing
```

```bash
cartograph rules --strict
```

Layers are matched against node name, module name **and** file path, because teams define layers
sometimes by directory and sometimes by naming convention. Nodes that match no layer are reported
as `info` — if you do not know what your rules fail to cover, a passing run means very little.

`--explain <node>` shows which layer a node landed in, which pattern put it there, and which rules
start from that layer — the questions you actually ask while debugging a configuration.

```console
$ cartograph rules --explain CartographKit
CartographKit is in layer 'Assembly'.
  matched: CartographKit against 'CartographKit'
  rules from 'Assembly':
    the assembly layer does not know about the interface
```

### `baseline` — adopt on an existing codebase

```bash
cartograph baseline --write .cartograph-baseline.json
```

Records today's findings so only *new* ones fail the build. Fingerprints are USR-based, so moving
code up and down a file does not resurrect a suppressed finding.

Where the file is written is always an explicit decision: `--write`, or the project root default
(`.cartograph-baseline.json`) when the configuration sets no `baseline_path`. The `baseline_path`
configuration key names where suppression findings are *read* from, never where a baseline is
written — a key in the analyzed repository's config must not be able to point a write at an
arbitrary path, and if `baseline_path` is set while `--write` is missing, `baseline` exits 64 and
says so rather than guessing.

### `--since` — review only what a pull request touched

```bash
cartograph dead --since origin/main --strict
```

Reports only findings **located in** modeled source files changed since a git revision — Swift,
Objective-C and Interface Builder suffixes — including committed changes, uncommitted changes to
tracked files, and new files you have not added yet. Other changed paths are listed as limitations
when they cannot be modeled. The graph is still built from the whole project, because reachability
computed on a partial graph is simply wrong; only the report narrows.

It answers "what did this change touch", not "what did this change cause". If your commit deletes
the last call to a symbol declared in a file you did not touch, that symbol becomes dead but its
finding sits in the untouched file and is not reported. The baseline catches that case on the next
full run; `--since` is a lens, not a proof. `baseline` therefore refuses `--since`: a partial record
would later make every out-of-scope finding look new. `query` refuses it too: one declaration is not
a finding list, so the lens has nothing to attach to. The same goes for `graph` (the whole project,
not a report), `bridges` (a partial export would read as missing handlers downstream) and the
`--explain` answers (one subject, like `query`). Only `dead`, `cycles`, `metrics` and `rules` over
the finding list honor `--since` as a report filter. `impact --since` uses changed paths as analysis
seeds and follows consumers in the whole graph, including deleted and renamed paths; it is a
different operation from filtering diagnostic locations.

`baseline` and `--since` answer different questions and compose: the baseline is the CI ratchet
that keeps today's debt from growing, `--since` is the pull-request lens. In CI, check out with full
history (`fetch-depth: 0`), or the revision will not resolve. A `noChanges` impact result means no
modeled source path was selected; it is not evidence that all changed files are safe.

## Configuration

`.cartograph.yml` in the project root. Run `cartograph init` for a commented template.
Command-line options always win over the file. The `level` key is read only by the commands that
render at a resolution (`graph`, `cycles`, `metrics`, `rules`); for the rest it is inert — `dead`
and `query` always work at symbol level, while `dataflow` uses its own value context graph — just
like the `--level` flag, which those commands refuse outright.

```yaml
level: module
include: ["Sources/**"]
exclude: ["**/.build/**", "**/*.generated.swift"]

retention:
  retain_public: false            # turn on for libraries
  retain_objc_accessible: true    # on by default; see below
  retain_interface_builder: true
  retain_tests: true
  retain_previews: true
  retain_codable_properties: true
  retain_raw_representable_enum_cases: true
  retained_names: ["*.shared"]
  retained_files: ["Sources/Generated/**"]

thresholds:
  max_cycles: 0
  max_unused_symbols: 0
  max_rule_violations: 0
  max_instability: 0.9
  max_distance: 0.8

baseline_path: .cartograph-baseline.json    # where --baseline READS suppression findings;
                                            # `cartograph baseline` writes only via --write or the
                                            # project-root default, never to this key
external_retentions_path: .isthmus/retentions.cartograph.json   # from isthmus, see `bridges`
derived_data_path: DerivedData    # where CI put -derivedDataPath
report_format: text               # text json xcode checkstyle github-actions sarif
graph_format: dot                 # dot mermaid json html
strict: false
```

Unknown keys are reported as warnings, not errors. A typo should tell you what was ignored, not
stop your build.

## Retention rules

The index store only records what the compiler saw. Runtime selectors, synthesized `Codable`,
Interface Builder connections and raw-value enum construction are all invisible to it. These rules
fill that gap, and every one of them records *why* so `--explain` can answer for it.

| Kept | Reason |
|---|---|
| `@main`, `@UIApplicationMain`, `@NSApplicationMain` and the type's `main()` | entry point |
| `XCTestCase` subclasses and no-argument `test…()` methods | XCTest |
| `@Test`, `@Suite` | swift-testing |
| `public` / `open` when `retain_public` | public API |
| `@objc`, `@objcMembers` (cascading to members), Clang `c:` USRs | Objective-C runtime |
| `@IBOutlet`, `@IBAction`, `@IBInspectable`, `@IBSegueAction` | Interface Builder |
| Types named by `customClass` in a `.xib` or `.storyboard` | only Interface Builder references them |
| Cases of raw-value enums | `init(rawValue:)` is dynamic |
| `CodingKeys` cases | synthesized `Codable` |
| `wrappedValue`, `projectedValue` on `@propertyWrapper` types | wrapper contract |
| `build*` on `@resultBuilder` types | builder contract |
| Stored properties of `Codable` types | synthesized coding leaves no reference |
| Members that override or satisfy a declaration outside the analyzed code | the framework calls them — the owning type is not kept by this rule |
| `subscript(dynamicMember:)`, `@_dynamicReplacement`, `dynamic` | dynamic dispatch |
| Compiler-synthesized declarations | you cannot delete them — they do not keep their type alive either |
| `// cartograph:ignore`, `// cartograph:ignore:all` | you said so |
| `retained_names`, `retained_files` globs | you said so |
| Declarations whose source cannot be read (permissions or I/O failure) | retention annotations are unknown (`sourceUnavailable`); restore access and rerun |
| Declarations named in `--external-retentions` | another platform calls them across a bridge; `--explain` quotes the evidence |

**`retain_objc_accessible` defaults to on.** Periphery defaulted it off, which made mixed-language
UIKit projects its largest source of false positives. A dead-code tool nobody trusts is worse than
no tool, so Cartograph errs toward keeping code.

Protocol requirements are handled by walking override relations in reverse: if a requirement is
called, every implementation of it is reachable — but only once the implementing type itself is
reachable, so a type that is never constructed does not resurrect everything it calls. Without the
first half of that rule, every type behind a protocol looks dead; without the second half, dead code
hides behind unused conformances. Both halves were found by running the tool on itself and by
adversarial review.

A direct call to a concrete implementation does not establish use of its protocol requirement.
Actual requirement calls still activate eligible implementations and protocol-extension defaults;
requirement refinement and class override chains remain traversable. Framework contracts outside
the selected graph remain conservative.

The compiler's broad `dynamic` occurrence role is distinct from Swift's explicit `dynamic` modifier.
Cartograph refines that role only with a unique exact source identifier match and understood
attributes. Explicit `dynamic`, dynamic replacement, Objective-C exposure, and unknown macro/source
contexts remain protected. Uncalled ordinary extension helpers can therefore be reported without
turning off those safeguards.

With `--retain-public`, protocol requirements and enum cases inherit their enclosing declaration's
access, and explicitly access-qualified extensions supply their members' default access. Ordinary
members of a public class or struct still default to internal. Individual extension members can
override the extension's default access.

### Known limitations

- **Local-function refinement requires source and index evidence.** For fresh source, Cartograph
  can recover named locals inside functions, methods, initializers, and deinitializers when an
  unambiguous lexical call or function-value reference chain starts at the exact indexed owner.
  `query`/`impact` then show the local as the direct consumer and the outer function at its actual
  transitive depth. Closures keep their nearest named owner. Synthetic local keys use
  `cartograph:local-function:` in the existing `usr` field; these are Cartograph keys, not compiler
  USRs, and change when the local declaration's line/column changes. They can be queried again.
  Uncalled or recursive-only locals, shadowed/overloaded names, unsupported macros/conditional
  compilation, and stale or undated files retain the compiler's outer projection. Their observed
  count is reported as `local-function-projection`; inspect source for exact ownership in those
  cases. Property/subscript accessors are not refined. Custom edge filters excluding calls,
  references, or containment disable refinement. Default type/file/module rollups stay unchanged; symbol graphs can now
  show actual recursion between promoted locals.

- **File-level freshness is not build-configuration completeness.** A file's latest index unit
  prevents unrelated targets from hiding its edits, but does not prove that every configuration
  containing that same file has been rebuilt. Files without a known unit are reported separately.

- **`#Preview` macro bodies.** Types used only inside a `#Preview` block are kept only when the
  compiler recorded the reference during macro expansion. `PreviewProvider` conformances are
  detected directly; `#Preview` is not.
- **Interface Builder connections are not matched individually.** Every `@IBOutlet` and `@IBAction`
  is kept when `retain_interface_builder` is on, whether or not a xib actually connects it, so
  disconnected outlets are not reported. Custom classes *are* matched by name.
- **Objective-C sources are not analyzed by the symbol graph.** `.m` and `.h` files are invisible to
  the graph; Swift declarations they reach are covered by `retain_objc_accessible`, which is on by
  default. `bridges` separately scans `.m` files for Flutter channel/handler patterns and React Native
  export macros, but that fact scan does not make Objective-C declarations graph nodes.
- **Callers in another language are known only through isthmus.** `bridges` exports what Swift
  declares; whether Dart or JavaScript actually calls it is a join this tool does not perform.
- **A property that is only ever assigned counts as used.** The graph has one `reference` edge
  kind and does not carry the index's read/write distinction, so `counter.neverRead = 1` looks
  exactly like reading it. In a four-line package where `bump()` assigns `neverRead` and nothing
  ever reads it, `dead` reports nothing and `query` answers `reachable`, used by `bump()`. Deleting
  such a property is safe and this tool will not suggest it. Telling the two apart needs read and
  write edge kinds, which the graph does not have yet.
- **`#if` branches that did not compile do not exist.** The index store only knows the
  configuration you built.

## CI

Exit codes let a script tell "your code has problems" from "the tool did not run":

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Findings with `--strict`, or a configured threshold exceeded |
| `2` | Tool failure — no index store, an index that knows nothing about this project, unreadable index, invalid configuration |
| `64` | Usage error — unknown option, unknown subcommand, invalid value, or a flag combination the command cannot honor |

```yaml
- run: swift build
- run: cartograph check --strict --report-format github-actions
```

For GitHub code scanning, emit SARIF:

```yaml
- run: cartograph dead --report-format sarif -o cartograph.sarif
- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: cartograph.sarif
```

The stdio and workflow harnesses keep their raw evidence outside the analyzed source tree:

```bash
Scripts/verify-mcp.py --cartograph .build/debug/cartograph
Scripts/benchmark-workflows.py --cartograph .build/debug/cartograph --project .
```

They fail on a timeout, malformed protocol output or a correctness mismatch; a reported speed
measurement is not treated as a pass unless its comparison is also valid.
See [workflow validation](docs/WORKFLOW-VALIDATION.md) for the acceptance workloads, measurements
and their limits.

## Architecture

Dependencies flow one way only:

```
CartographCore  ←  Config · Syntax · Analysis · Export · IndexStore  ←  Kit  ←  CLI
```

| Module | Responsibility |
|---|---|
| `CartographCore` | Graph model, index abstraction, configuration types. No external dependencies. |
| `CartographConfig` | `.cartograph.yml` loading (Yams). |
| `CartographSyntax` | Accessibility and attributes via SwiftSyntax. |
| `CartographAnalysis` | Cycles, reachability, retention, metrics, layer rules, baseline. |
| `CartographExport` | Graph renderers and diagnostic reporters. |
| `CartographIndexStore` | The only module that touches IndexStoreDB. |
| `CartographKit` | Pipeline assembly. Ships as a library so you can embed it. |
| `cartograph` | Argument parsing and exit codes. |

The domain and the algorithms do not know IndexStoreDB exists. That is what makes the enforced 90%
line coverage gate reachable without a single fixture Xcode project: analysis runs on hand-written
snapshots.
The coverage gate combines unit tests with instrumented CLI integration harnesses and reports the
unit-only percentage separately. Discovery recall is measured against labelled dependency cases,
not inferred from line coverage.

`CartographKit` is a public library product — you can embed the pipeline instead of shelling out.
Its query API returns values, not rendered text:

```swift
import CartographKit

let service = CartographService(configuration: configuration)
let context = try service.loadContext()          // reads the index once

let (graph, cycles) = service.cycles(in: context)
let (_, unused) = service.unusedCode(in: context)
let (_, metrics, _) = service.metrics(in: context)
```

Baselines, thresholds and output formatting are CI policy and live in the separate command API
(`detectCycles()`, `detectUnusedCode()`, …), so a programmatic caller never has to parse a table.

## Project language

Documentation and user-facing output are in English. Source comments are in Korean, which is the
maintainer's working language; identifiers are always English. Pull requests may be written in
either language.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Agents working in this repository should read
[AGENTS.md](AGENTS.md) first.

## License

MIT. See [LICENSE](LICENSE).

Cartograph is an independent project. It is not affiliated with Periphery or Apple.
