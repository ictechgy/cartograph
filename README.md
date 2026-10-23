# Cartograph

<img src="icon.png" alt="cartograph's swift mascot" width="112" height="112" align="right">

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

Compiler-backed queries preserve every compilation target when a source file is shared. Analysis reuses one project file inventory per load, and ambiguous or missing-symbol queries avoid work needed only for found declarations. Baseline errors, measured limitations, and found-reference evidence remain unchanged.

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
| Which tables does this code touch? | invisible | `schema` exports `relation-use` facts for isthmus to join with the SQL catalog |
| Which server routes does the app call? | invisible | `routes` exports `route-call` facts (URLSession, URLComponents, Alamofire and Moya without declarations) for isthmus to join with server routes and OpenAPI operations |
| Runtime or dispatch-only risk | — | `impact` marks runtime review targets and dispatch contracts |
| Graph export | — | ✅ DOT, Mermaid, JSON, self-contained HTML |
| SARIF for code scanning | — | ✅ |
| `@objc` retained by default | ❌ opt-in | ✅ on by default |

The retention rules — the genuinely hard-won knowledge about what *looks* unused but must not be
deleted — are absorbed wholesale. See [Retention rules](#retention-rules).

## Install

Check [GitHub Releases](https://github.com/ictechgy/cartograph/releases) for published CLI versions
and available binary assets. The versioned install examples below pin published
[**0.28.0**](https://github.com/ictechgy/cartograph/releases/tag/0.28.0) for reproducibility;
change the pin only to a published version you have verified. A source checkout's `--version` reports
its source version and does not establish release availability. Version 0.25.1 was prepared in source
but never published; see [CHANGELOG.md](CHANGELOG.md) for the incorporated changes.

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

The [tap formula](https://github.com/ictechgy/homebrew-tap/blob/main/Formula/cartograph.rb) is updated
separately from GitHub Releases. Its [0.28.0 update](https://github.com/ictechgy/homebrew-tap/pull/63)
passed public archive installation and formula tests on macOS arm64. Verify `cartograph --version`
after installing or upgrading; a published release and tap update do not upgrade your local binary.

**Mint** — builds from source, no tap to add:

```bash
mint install ictechgy/cartograph@0.28.0
```

**No install at all** — for a Swift package, add Cartograph as a dependency and use the command
plugin. Everyone on the team and CI then runs the same version:

```swift
// Package.swift
.package(url: "https://github.com/ictechgy/cartograph", revision: "0.28.0"),
```

```bash
swift package cartograph dead --strict
swift package cartograph graph --format mermaid > graph.mmd
```

It has to be `revision:`, not `from:`. Cartograph depends on `indexstore-db`, which publishes no
semantic-version tags and is pinned to a commit on its `release/6.4.1` branch, and SwiftPM refuses
to resolve a stable-version dependency whose own dependency is unstable:

```
error: … package 'cartograph' is required using a stable-version but 'cartograph'
depends on an unstable-version package 'indexstore-db'.
```

`revision:` takes the tag name, so the pin still reads as a version and still has to be raised by
hand at each release. The plugin declares no write permission, so it never prompts; redirect stdout
to save output. Commands that write files themselves — `--output`/`-o`, `baseline`, `fix --apply`,
`skill` and `init` — cannot write inside the package directory unless that run allows it:
`swift package --allow-writing-to-package-directory cartograph baseline`. SwiftPM also reports every
plugin failure as exit code 1, so this path tells success from failure only; see [CI](#ci).

Because the `indexstore-db` pin is a commit, not a branch, every project on the same Cartograph tag
builds the `indexstore-db` that tag was tested with, with or without its own `Package.resolved`.
`swift-lmdb`, which `indexstore-db` itself requires by its `release/6.4.x` branch, still resolves to
that branch's head; commit your `Package.resolved` to hold it. SwiftPM cannot resolve one package
required at two different revisions, so a graph in which another dependency asks for `indexstore-db`
by a branch or by another commit fails with "indexstore-db is required using two different
revision-based requirements".

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
cartograph graph --level symbol --format json --evidence -o graph-with-evidence.json
cartograph graph --level symbol --format json --edge-kind call --include-self-loops -o calls.json
cartograph graph --level module --format html  -o graph.html
```

Four resolutions: `module`, `file`, `type`, `symbol`. The HTML export is a single self-contained
file with no CDN references — it opens on an air-gapped machine and passes a security review.

Graphs omit self-loops by default, including recursive calls, to preserve the existing diagram contract.
`--include-self-loops` explicitly retains indexed self-reference edges and requires `--level symbol`;
combine it with `--edge-kind call` for recursive call edges and `--evidence` for their source occurrences.
It does not change default `cycles`, query seed exclusion, or module/file/type roll-ups, and cannot be
combined with `--declaration-projection`. It does not recover calls missing from the compiler index.

`--evidence` adds all indexed reference occurrences supporting the final graph edges, with relative
file/line/column when available, original USRs, origin and position. It has no query evidence cap.
Roll-up and graph filters still apply; generated member edges receive no invented occurrence.
Separate `moduleImports` are declaration facts, and source/index `inventory` preserves unknown
versus known-empty coverage. Unlocated and omitted records are counted. An import-topology
limitation identifies recorded imports that are absent from the graph's import edges. This optional
JSON output still buffers a complete String; it is not a streaming export.

`graph --level symbol --format json --declaration-projection --primary-module Main` writes a separate
`cartograph-declaration-projection` v1 artifact. It keeps the raw graph and every variant's USR,
module, access and attributes, alongside a projection with an explicitly selected representative.
Only exact normalized declaration location/name/kind and bounded lexical parent correspondence are
merged. Missing or ambiguous groups remain raw. The output reports conditional-compilation uncertainty;
lexical correspondence does not prove semantic equivalence or source freshness. Query/analysis IDs
remain unchanged. This option and `--evidence` select different artifacts.

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

With `--since`, a component's cycle is reported when any node of that strongly connected component
has a declaration in a changed file — the rule `check` uses — even if the representative cycle
passes only through files the change did not touch. A module cycle is therefore reported only when
one of the component's modules has a changed file.

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

`dead` also reports public declarations whose references all come from their own module, as
warnings under the `redundant-public` rule:

```console
Sources/Net/Client.swift:12:12: warning: class 'Net.Client' is referenced only within its own module (3 references) — it could be internal
```

A public declaration the module itself is the only user of does not need to be public. The check
asks two conservative questions. Does any reference come from another module? A reference whose
source module cannot be proven to be the declaring module suppresses the finding. Is the
declaration mentioned in the interface of another public declaration? A type mention in a
signature, superclass clause, generic constraint or default argument keeps the target public,
while a use inside a function or accessor body does not — syntax analysis classifies every
reference, and a reference whose position cannot be determined counts as an interface mention.
Overrides, protocol requirements, protocol witnesses, enum cases, and declarations already marked
`@objc`/`@objcMembers`/`@IBOutlet`/`dynamic`/`@NSManaged` are never reported. A declaration with
no references at all is left alone too: `unused-symbol` answers the unused question separately.
With `retain_public` enabled the rule stays silent — that setting declares the public surface
intentional, and a module reading its own public API would otherwise flood the report; run the
default mode (where `retain_public` is off) to ask this question. Members are judged individually,
so a public method only the module calls is reported even when its class is used across modules.
Only the modules in the index are evidence — a consumer outside the workspace is invisible, so
read the finding as a question, not a verdict. Like the other warning rules, `redundant-public`
does not count toward `--strict`.

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

### `fix` — plan and apply mechanical edits

Parse checks do not prove type correctness or build compatibility. Review the diff and rebuild
all relevant targets after `--apply`. Writes are atomic per file, not across the edit set;
this command does not run a verification command or roll back failed builds.

```bash
cartograph fix                      # print the plan; writes nothing
cartograph fix --apply              # write the fixes
cartograph fix --since origin/main  # only findings in changed files
```

Two warning classes are mechanically fixable, and only those two: `unused-import` removes the
import declaration, and `unused-parameter` drops the parameter's internal name while keeping its
argument label (`func f(retry:)` becomes `func f(retry _:)` — the label is never dropped).
Everything else that `dead` reports needs a human decision.

The default is a dry run. Every edit is looked up in the current source rather than applied by
position: the declaration at the recorded location must still match, an import line must not carry
other code, and the rewritten file must re-parse before anything is written. Anything that fails
those checks is reported as skipped with a reason instead of guessed at. Writes are atomic per
file, and findings already accepted in the baseline (`baseline` records both classes) or outside
`--since` are left alone. Without `--apply`, `--strict` fails while the plan is non-empty; with
`--apply` it fails only when an edit had to be skipped.

```console
$ cartograph fix
Sources/Net/Client.swift:3:1: import 'Combine' is never used
Sources/Net/Client.swift:42:30: parameter 'retry' of 'Net.Client.fetch(_:retry:)' is never used
2 fix(es) in 1 file(s) — dry run; pass --apply to write
```

Run it on a fresh build: the plan comes from the same index `dead` reads, and a stale index makes
edits get skipped rather than misplaced. `--format json` returns the `mechanical-fixes` document
with each edit's file, position, rule and replacement text.

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
    "objective-c-sources: 12 file(s); the graph uses available Clang index evidence, while runtime dispatch and unindexed source paths may be absent",
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
  unit was written, a package that exports library products while `retain_public` is off, directory
  symlinks that lead outside the project root and were not followed, a path filter narrower than the
  defaults, or an edge-kind filter — any of which could be the reason `usedBy` is empty. The default
  excludes alone do not count: they are a noise guard, not a
  narrowing you chose, and a warning that fires on every project is not read. File-level
  timestamps use the oldest observed covering unit, so rebuilding only one context of a shared
  source cannot hide another context's stale facts. Scoped project-header dependencies and deleted
  source paths are tracked even without graph declarations. `unindexed-sources` counts files without
  a known covering unit; `missing-sources` counts indexed files that disappeared. These diagnostics
  identify sorted project-relative paths with escaped control characters. Each diagnostic displays
  at most 64 paths and an 8 KiB UTF-8 JSON path array; `omitted-paths` explicitly counts any omitted
  paths while the aggregate file counts stay exact. The snapshot's optional
  `oldestIndexedFileDates` preserves this evidence separately from the latest-date `indexedFileDates`
  API; older snapshots/providers fall back to the latter and cannot prove multi-context freshness.
  This covers observed units, not unbuilt configurations. Obsolete units can keep warnings active
  after a rename or incremental rebuild; create a fresh index to remove them.
  The normal Clang-enabled pipeline also reads existing project `.h` record dependencies within
  the configured project/path scope. All observed unit/record contexts must read successfully;
  a failed context aborts the snapshot rather than returning partial header coverage. External,
  excluded and deleted headers are not admitted as project declarations. Raw and database-backed
  readers use the same record pass. Optional `admittedHeaderPaths` records actual header-record
  admission independently of dates and survives snapshot capture/rebase. Snapshot merges conservatively
  keep only headers admitted by every input; an incomplete input cannot be hidden by another reader. Legacy or unknown
  admission, system-marked contexts filtered by the default graph, any observed file-only context
  without a successfully read record for that same header in that same unit,
  and unindexed headers retain the separate
  `header-projection` limitation, which blocks narrowed tests and closed-world completeness.
  A record in another unit cannot establish coverage for a file-only context.
  Freshness/runtime limitations still apply to admitted headers; unbuilt configurations remain unknown.
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

<!-- dead-to-batch-example -->
```bash
sweep_dir="$(mktemp -d "${TMPDIR:-/tmp}/cartograph-sweep.XXXXXX")" &&
cartograph dead --report-format json > "$sweep_dir/dead.json" &&
jq '[.diagnostics[] | select(.ruleIdentifier == "unused-symbol") | .subject]' \
  "$sweep_dir/dead.json" > "$sweep_dir/requests.json" &&
if jq -e 'length == 0' "$sweep_dir/requests.json" >/dev/null; then
    echo "No unused-symbol findings to query."
elif jq -e 'length <= 1000' "$sweep_dir/requests.json" >/dev/null; then
    cartograph query --batch "$sweep_dir/requests.json"
else
    echo "Split $sweep_dir/requests.json into batches of at most 1000 requests before querying." >&2
    exit 64
fi
```

Select only `unused-symbol` diagnostics: `unused-import` and `superfluous-ignore` subjects
identify imports or ignore comments, not declarations that `query` can resolve. A clean report
skips the query because an empty request array is invalid. Above 1000 findings, split the full
array into nonempty JSON arrays of at most 1000 requests and 1 MiB each, then query each file;
do not truncate the findings. Each batch reads its own snapshot.

For a nonempty report, the batch response looks like this:

```console
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

For a SwiftPM package at a Git repository root, capture the actual patch with two fresh builds:

```bash
python3 /path/to/cartograph/Scripts/cartograph-git-impact.py --project . --base origin/main --head HEAD
python3 /path/to/cartograph/Scripts/cartograph-git-impact.py --project . --base HEAD --working-tree
```

The helper is included in the release archive and source checkout. It uses the installed `cartograph`
unless `--cartograph /path/to/binary` is supplied. `--base` is an exact commit comparison, unlike
`--since`'s merge-base selection. It retains isolated worktrees, both snapshots, build logs and
`impact.json` in a new external directory (`--output` can name one). It never switches the caller's
checkout. Working-tree mode includes staged, unstaged and untracked files; ignored files, symlinks,
submodules and non-root/Xcode packages need the manual capture workflow. Dependency lockfiles must
already be resolved: a source-tree change during build fails capture instead of claiming freshness.
Building executes package build tools; only use the helper on code you trust to build.

After the 0.29 Homebrew formula update, its helper is available at
`$(brew --prefix cartograph)/libexec/cartograph-git-impact.py`; invoke it with Python 3.10+.
Older formulas install only the binary; use the matching release archive/source helper in that case.

`changeInput` reports exact revisions, all changed paths, unmodeled paths, source SHA-256 identities,
source stability during each fresh build, and input preparation, build, analysis and total seconds.
Changes compare the captured endpoints' bytes and executable mode, including untracked restorations.
Identities cover tracked and nonignored untracked regular files; ignored inputs, external dependencies,
the toolchain and environment are not content-bound by the helper. File seeds select every
declaration in the file, so candidate counts are conservative. Configuration-only changes remain
incomplete; empty results and statically connected tests do not establish safety, predict failures,
or authorize skipping tests. The general `impact --since` mode still uses only the current graph
unless `--before` is supplied. JSON's additive `input` field identifies each side, `unknown`/`stale`
freshness, selection precision and budgets; old snapshots without a fingerprint remain unknown.
The helper passes its exact file selection with `impact --files-from <json-array-file>`; an empty
array preserves an empty patch. This additive selector accepts at most 10000 paths and 1 MiB,
and is mutually exclusive with declaration arguments, `--file`, and `--since`.
The helper prints the retained report path even when analysis is incomplete, then exits 2;
`changeInput.analysisExitCode` preserves the native analyzer's status.

MCP `cartograph_impact` also accepts `before: ".cartograph/before.json"` with `symbols` or `files`.
The snapshot must be a JSON file inside the configured project. Its historical identity is retained
beside the session's current input fingerprint; the two graphs are never merged for traversal.

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

#### Enum expansion review (since 0.27.0)

`impact --before` adds `enumChangeReview` to JSON and text for selected enum expansions.
It locates compiler-attributed `default`/`@unknown default` switches and finite array-literal
`contains` or direct negation that may deserve review when new cases reach them. Findings carry
case identities, source locations and unresolved coverage; they are review candidates, not proof
of a behavioral bug. Custom equality can affect membership outcomes.

Capture a capable pre-change baseline with enum-aware Cartograph, then rebuild the current index
with comparable targets and configuration. Legacy snapshots decode but cannot supply missing enum
inventories. Syntax cache schema 15 refreshes old cached facts automatically; it cannot upgrade a
saved baseline. Equality/inequality, if/guard case, filters and dynamic collections remain outside
this first slice. See [Enum expansion review and migration](docs/ENUM-CHANGE-REVIEW.md).
No new strict failure category is introduced.

#### Multi-root traversal for isthmus (`--format language-traversal`)

```bash
cartograph impact 's:3App6ClientC6logoutyyF' 's:3App6ClientC5fetchyyF' --format language-traversal
cartograph impact 's:3App6ClientC5fetchyyF' --format language-traversal --direction dependencies
cartograph impact --format language-traversal --roots-from routes.json   # roots from a file (or - for stdin)
```

This form emits one [`language-traversal` v1](../isthmus/docs/LANGUAGE-TRAVERSAL.md) document for
`isthmus trace`. Every declaration argument is a root, in input order; pass the `symbol.usr` values
that `routes` and `bridges` facts carry, because root ids and reached `symbol.usr` values are the
index USRs, byte for byte. Each reached declaration lists **every** root that reaches it
(`roots`, ascending, at most 64 with `rootsTruncated`), so one run replaces one `change-impact` run
per root without losing which route reached which view. `depth` is the distance to the nearest
root; a root reached from another root is listed without its own index, with its depth measured
from the other roots. `via` is a shortest-path witness. `--direction dependents` (the default)
follows consumers exactly like `change-impact`; `--direction dependencies` follows the inverse
relation (callees, and from a contract call to its implementations). `qualifiedName` includes the
enclosing type (`ProfileView.body`, not `Module.body`).

Evidence tiers (`evidence`, on every reached declaration) are per-root lower bounds:

| Tier | Swift edges |
|---|---|
| `direct` | compiler index edges only (calls, references, conformance, inheritance, extension, a declared override) |
| `bound` | also a protocol-requirement dispatch whose only implementation, and only conforming type, is proven across the whole index |
| `candidate` | also an override or protocol dispatch that may reach another implementation, or an automatically discovered runtime connection |

`bound` needs a closed world, so any limitation that says the index does not cover the whole
project (unindexed, stale, missing or unreadable sources, path or edge filters, Objective-C
sources, an exported library, directory symlinks outside the root that were not followed)
downgrades such hops to `candidate` and adds `dispatch-bound-unproven`. The document does not
declare `dispatch` and never carries
`unresolvedCalls`: the Swift index does not record calls through closures held in parameters or
local variables, so cartograph cannot claim complete unresolved-call reporting, and isthmus reads the
missing field as unknown. Declarations an external framework or the runtime invokes — SwiftUI
`body`, `@main`, `@objc`/Interface Builder hooks, external protocol witnesses — are named under
`runtime-invoked-entry-points` in the dependents direction; the traversal stops there because the
program has no caller, and no caller is invented. Roots are not expanded to their members
(`container-roots-not-expanded` says when a type was given). An unresolved root keeps its text as
`id` without `symbol`, adds `root-not-found:` and `truncated`, and exits 64 after printing.
`--limit` defaults to 100000 (the contract maximum) and `--generated-at` fixes the timestamp for
byte-identical output. `revision` is `--revision <rev>` when given; otherwise it is the git `HEAD`
commit only when the project directory has no uncommitted or untracked changes, and it is omitted
when the tree is dirty, contains a submodule, or is not a repository — a `HEAD` recorded over edited
sources would make isthmus treat a stale analysis as current. These lookups disable the repository's
git filters and never fetch missing objects (see Known limitations), so a file a filter normalized,
such as Git LFS, reads as dirty and omits the revision too, as does a partial clone missing an
object the check needs; pass `--revision` explicitly in those cases.
`graphRevision` is `sha256:` over the symbol graph's node ids and
kinds, its edges, the automatic runtime connections and the closed-world decision (locations
excluded), so dependents and dependencies documents over the same graph agree. `project` is the
project's real path, as in `routes` and `bridges`. Roots and `--revision` containing control
characters are rejected with exit 64 because isthmus rejects such ids. Files, `--since`, `--before` and runtime evidence inputs are
`change-impact` inputs and are rejected here.

`--roots-from <file|->` reads more roots from a file, or from stdin with `-`, so thousands of
route-call symbols do not hit the argument-length limit. It accepts the same inputs as kartograph's
`--roots-from` — a JSON string array, or a bridge-facts document whose facts' `symbol.usr` become
roots in document order (facts without a `symbol.usr` are skipped and counted in a stderr note) —
plus a plain line format: one root per line, LF or CRLF, surrounding spaces trimmed, blank lines and
lines starting with `#` skipped. A first non-blank character of `[` or `{` selects JSON; USRs never
start with either. File roots follow the positional roots, exact duplicates are dropped, the input
may be at most 16 MiB and the combined list at most 10000 roots. The file is read and checked before
the index is opened, and every problem — a missing or unreadable file, invalid JSON, non-UTF-8 text,
an oversized input, an empty or whitespace-only root, a control character (tabs and lone CRs are not
trimmed, so they are rejected rather than silently repaired), or no roots at all — is a usage error
(exit 64). `--roots-from` is only accepted with `--format language-traversal`, like kartograph.

### `affected` — which tests reach a change

```bash
cartograph affected --since origin/main            # tests that reach this branch's change
cartograph affected UserService                    # tests that reach one declaration
cartograph affected --file Sources/Net/Client.swift --format json
```

CI's recurring question is narrower than impact: *which tests should run for this change?* This
command starts from the same seeds as `impact` — a declaration, one or more files, or `--since` —
and follows consumers until test declarations (XCTest or swift-testing) are found, reporting each
test's distance and the path that reached it:

```console
$ cartograph affected UserService
affected: 2 test declaration(s) reach this change — 11 affected symbol(s), 1 test file(s), 3 in change scope
  Tests/UserServiceTests.swift:42 App.UserServiceTests.testSelectsData() (depth 2 via App.Loader, dependent [call])
  Tests/UserServiceTests.swift:77 App.UserServiceTests.testRefresh() (depth 3 via App.Loader, dependent [call])
```

A test file the change touched is listed at depth 0 as `changed`. When no test declaration reaches
the change the command says so explicitly — an empty list is a statement about the graph, not proof
that existing tests cover the behavior, and every response carries that sentence plus the analysis
limitations. Selection, container expansion, dispatch projection, automatically discovered runtime
connections and depth limits use the same rules as the default `impact` command. A changed XIB,
storyboard or supported Core Data resource selects its bound Swift declarations before following
consumers. `affected` does not accept `impact`'s optional contract or trace files.

Automatically discovered relationships remain `automaticRuntime`, never compiler calls or observed
execution. A test directly reached through one carries optional `runtimeEvidence` (and
`runtimeEvidenceOmitted` when capped). `--limit` caps every displayed selection, test and summary
list; unresolved-input candidates share one document-wide budget. `summary` retains uncapped
counts and `truncated.sections` names every omitted section.

`--format xcodebuild` turns the answer into `-only-testing:` arguments, one per line, ready for a
script:

```bash
xcodebuild test -scheme App $(cartograph affected --since origin/main --format xcodebuild)
```

```console
$ cartograph affected negate --format xcodebuild
-only-testing:CalcTests/AddTests/testNegate
```

A wrong class or method is worse than none — given an unknown class, xcodebuild runs zero tests and
reports success (measured with Xcode 27.0) — so narrowing requires exact compiler XCTest ancestry and method provenance as well as graph checks. A
test class is narrowed to `Module/Class`, and a test method to `Module/Class/method`, only when the
class is a top-level XCTest class with no subclass (a subclass runs the inherited test under its own
name, which the base-class identifier skips) whose Objective-C runtime name is its source name, and
the method is a parameterless `test…` method with the compiler test bit. A class must own or inherit at least
one such verified method. Syntax-only and legacy markers retain candidates but do not prove selectors. Every other reached test
selects its whole test module: swift-testing functions, whose identifier format has varied between
Xcode releases, nested classes, and classes renamed with `@objc(…)`. Standard error says how many
tests were widened this way, followed by the analysis limitations. A graph narrowed by `edge_kinds`
or path filters cannot establish all affected test modules, so it refuses selection entirely.

XCTest setup/teardown dependencies select the executing class, including inherited hooks and
classes in other test modules. Inherited test methods also retain descendant execution. These
links carry `automaticRuntime` evidence with `xctest-lifecycle:` or `xctest-inherited-test:` IDs;
they are static execution contracts, not observed calls. Ordinary unused helpers do not promote
their owning class, and membership edges remain distinct from usage.

The `uncertain-test-identity` limitation explains widened candidates. `test-target-assumption` makes
explicit that framework identity does not establish test-target membership: ordinary libraries can
also contain XCTest subclasses. The module name stands in for the xcodebuild test target name. They match for SwiftPM test targets
and for Xcode targets whose names are valid identifiers; a target named `My App Tests` has the
module `My_App_Tests`. Unlike an unknown class, an unknown target is a loud failure — xcodebuild
stops with "isn't a member of the specified test plan or scheme" — so such a project sees the
mismatch rather than a silently empty run; use the JSON output there. When the list is truncated by `--limit` or
`--depth`, or an input is unresolved, the command prints no arguments and exits 2 (unresolved named
declarations still exit 64). Missing/unreadable sources, stale or absent index units, an empty index,
narrowing path/edge filters, and directory symlinks outside the root that were not followed also
print no selectors and exit 2. Freshness and readability
checks cover Swift, Objective-C/Objective-C++ implementations, and project headers; an unindexed
header is an uncertainty, not proof that its consumers are absent. Mixed modeled and unmodeled
changes (for example a Swift edit plus a JSON fixture or build configuration) refuse partial
selectors with exit 2. If only unmodeled files changed, the empty all-tests fallback remains exit 0. These checks apply even when a
skipped source produced no runtime facts. Unresolved, stale or unsupported automatic runtime analysis
likewise refuses selection: additional tests may reach the change through those paths. With no
`-only-testing:` argument xcodebuild runs every test. Inspect `runtime discover` and rebuild before
narrowing the run. When there are no such gaps, no reached test prints nothing and exits 0; check
`summary.testCount` in the JSON if skipping the test run is the intent.

### `snapshot` — capture an analysis input

```bash
cartograph snapshot --revision before-change -o .cartograph/before.json
cartograph snapshot --runtime-contracts runtime-contracts.json -o .cartograph/before.json
```

The v2 snapshot stores automatic runtime facts and their captured freshness, plus the enriched compiler index, edge selection, measured limitations, external
retentions and optional runtime contract declarations. An explicit `--revision` remains a user label.
When omitted, a clean Git HEAD is recorded when available; dirty or unknown state has no revision.
The additive `inputFingerprint` identifies source/configuration/index content at capture time, with
before/after stability checks. Externally supplied Kit contexts (including Core Data evidence contexts)
omit that fingerprint and record an input-identity limitation because their load generation is unknown.
Neither the revision nor fingerprint proves that the compiler read
those exact source bytes; index freshness limitations remain. Historical source files are never read again. A snapshot always
uses the symbol graph and JSON output, so `--level`, `--report-format`, `--strict`, `--since` and
`--baseline` are rejected.

Older v1 snapshots remain readable and explicitly report missing automatic runtime evidence.
The default snapshot limit remains 128 MiB. For larger projects, set `--snapshot-max-mib 512`
on both `snapshot` and `impact --before` (accepted range: 1–1024 MiB); the Git capture helper
forwards the same option to both captures and the comparison. MCP `cartograph_impact` accepts
`snapshotMaxMiB` with `before`, with the same range and default. The limit counts the entire
uncompressed JSON file, including its trailing newline. Reads stop at limit + 1 bytes before
decoding; oversized, truncated, corrupt and compressed inputs are rejected. There is no automatic
decompression. Encoding and decoding still materialize the JSON and graph in memory, so this is
a file-size budget, **not an RSS limit**; raising it can require several times the file size in RAM.
The library keeps `decode(from:)` at the default and adds `decode(from:maximumBytes:)` and
`encoded(maximumBytes:)` for the same bounded policy. Runtime `expectedValue` fields remain omitted. If a current runtime
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
`cartograph_impact`, `cartograph_affected`, `cartograph_check` and `cartograph_runtime_discover` return `{ "session": ..., "result": ... }` envelopes
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

Within one generation the analysis limitations, the `cartograph_check` result and the test
lifecycle and name/file indexes behind `cartograph_impact` and `cartograph_affected` are computed
once and reused. Every response therefore carries the limitations counted for its generation, the
same list as its `session` envelope, so an edit made inside the freshness window shows up as
`index-staleness` once the session re-verifies, or right after `refresh: true`. The index store's
own modification time is the exception: the input fingerprint does not cover it, so when it moves
within a generation (an entry added at the store root, or a rebuild inside the freshness window),
responses count their limitations again and can differ from the envelope, for example by an
`index-staleness` or `external-retentions-stale` entry, until the next generation.

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
trace_dir="$(mktemp -d "${TMPDIR:-/tmp}/cartograph-trace.XXXXXX")"
cartograph runtime collect --executable .build/debug/MyApp --output "$trace_dir/runtime-trace.json" -- app-arguments
cartograph runtime discover --trace "$trace_dir/runtime-trace.json" --executable .build/debug/MyApp
cartograph impact ScreenController --trace "$trace_dir/runtime-trace.json" --executable .build/debug/MyApp --format json
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
trace_dir="$(mktemp -d "${TMPDIR:-/tmp}/cartograph-trace.XXXXXX")"
cartograph runtime collect --simulator <booted-device-UUID> --bundle-id <app-bundle-id> \
  --executable <matching-build/MyApp.app/MyApp> --output "$trace_dir/simulator-trace.json" -- test-arguments
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

`generatedAt` records document extraction time, not source modification or index build time.
The shared v1/v2 contract also permits `sourceModifiedAt` for the newest observed source mtime;
cartograph does not collect that inventory and omits the optional field. Neither timestamp proves
that the compiler index matches the current sources. Keep index freshness evidence and limitations
when joining documents. [Kartograph versions through 0.12.0](https://github.com/ictechgy/kartograph/blob/v0.12.0/index/src/main/kotlin/dev/kartograph/index/BridgeFactScanner.kt) used source mtime for their default
`generatedAt`, so a large cross-producer time difference alone is not evidence of an old build.

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

Cartograph 0.20.0 includes available indexed Clang declarations in the analysis graph. Pair it
with isthmus 0.8.0+: matched Objective-C handlers require actual Clang USRs for retention export;
name-only or missing identities fail with code 2 instead of producing a partial retention document.
Legacy `omittedObjectiveCHandlers` counts remain readable as limitations, but new isthmus output
does not silently omit matched Objective-C handlers. Missing Swift handler symbols also fail.

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
  "tool" : { "name" : "cartograph", "version" : "0.25.0" },
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

Development scope (unreleased): optional upstream provenance on external-retentions v0 is preserved
through analysis and snapshots, including zero-entry and unmatched documents. Old documents explicitly
report unavailable context; unknown provenance versions retain matching roots and report unsupported
context. A newer conversion timestamp never clears upstream stale-source warnings. The input file is
bounded to 16 MiB; provenance is limited to 256 source headers, 4,096 limitations and 1 MiB canonical
UTF-8, with strict scalar Unicode, integer-literal tokens, duplicate-key rejection and depth 64. Invalid
or oversized input fails instead of yielding an empty success. Display is capped at 64 records and
8,192 escaped UTF-8 bytes with exact omitted counts; snapshots retain the full admitted context in a
separate compact JSON field. This preserves byte-distinct Unicode keys that Foundation keyed Codable
would otherwise coalesce. Raw snapshot context is revalidated on restore, and conflicting duplicate
representations fail. Embedders must load provenance-bearing retention documents through
`ExternalRetentionStore.load(from:)` and snapshots through `AnalysisSnapshotDocument.decode(from:)`;
plain `JSONDecoder` remains supported for legacy documents and snapshots without provenance. Capture timestamps use
an explicit portable profile: real Gregorian dates, lower/upper-case t/z, hour/offset-hour 00–23,
minute/offset-minute 00–59 and seconds 00–59, with arbitrary fraction digits preserved. Leap seconds
(:60) are unsupported, rather than normalized. None of this establishes deletion safety or cancels a matched retention.

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

### `schema` — export database relation references

```bash
cartograph schema                        # persistence bridge-facts JSON on stdout
cartograph schema --format text          # one line per fact, for a quick look
```

A Swift file that runs `sqlite3_prepare_v2(db, "DELETE FROM sessions …")` references a table the
compiler index knows nothing about — the name only ever exists inside a string literal. `schema`
reads those literals out of the sources and writes `relation-use` facts in the same `bridge-facts`
exchange format, with `target: "persistence"`, so [isthmus](../isthmus) can join them against the
`relation-decl` facts schemagraph produces from the live catalog: code that references a dropped
table, or a table no code touches, becomes a check finding instead of a guess.

The covered surface is evidence-gated by import: sqlite3 C API arguments, GRDB `sql:` arguments,
`Table(…)` and `static let/var databaseTableName`, SQLite.swift `Table`/`prepare`/`run`, Fluent
`schema`/`query(_:)` and `static let schema`, plus ungated uppercase SQL literals anywhere. Core
Data, SwiftData, Realm and other database frameworks are counted under `limitations` rather than
read — entity names are not SQL catalog relations, and emitting them as facts would produce
diagnostics for declarations that were never supposed to exist. SQL arguments that are not
literals, and relation names that cannot be resolved statically, stay in the document marked
`dynamic` so the join can count what it could not see.

SQL text is read by a token scanner that follows the relation-name rules every persistence
producer shares through the isthmus contract. A `FROM` inside function arguments
(`EXTRACT(YEAR FROM created_at)`, `TRIM(BOTH ' ' FROM name)`, `SUBSTRING(name FROM 2)`; a subquery
inside them still counts), an unqualified name that is a CTE of the same `;`-separated statement
(unquoted names compare case-insensitively, quoted names as written), and the operand of
`IS [NOT] DISTINCT FROM` are not relations: none of them becomes a `relation-use` fact or is
counted under `unjoined-dynamic-relations`. The CTE rule covers the whole statement, so a CTE
named after a table hides that table too — `WITH users AS (SELECT * FROM users …)` drops the real
`users` its body reads.

Like `bridges`, the command attaches the index's USR to the enclosing declaration when it can,
so isthmus retentions can name the function that touches a table. Facts at file scope carry no
symbol. The command refuses `--since`, `--level`, `--report-format` and `--strict` for the same
reasons `bridges` does: the document is a complete boundary export, not a finding.

### `routes` — export the HTTP requests the app makes

```bash
cartograph routes                                        # library calls, no declarations needed
cartograph routes --wrappers http-wrappers.json          # plus your own wrappers; JSON on stdout
cartograph routes --wrappers http-wrappers.json --include-tests --format text
```

An app rarely calls `URLSession` with a literal URL; it goes through its own endpoint type or a
`send(path:method:)` helper, and which argument is the path is not something the source says. You
declare those wrappers in an `http-wrappers` v1 file (the schema belongs to isthmus,
`../isthmus/docs/HTTP-WRAPPERS.md`), and `routes` emits one `route-call` fact per call site in the
`bridge-facts` exchange format with `target: "http"` and `roles: ["client"]`, so [isthmus](../isthmus)
can join them by (method, path template) against server route declarations and OpenAPI operations.

```json
{"format": "http-wrappers", "version": 1, "wrappers": [
  {"language": "swift", "kind": "constructor", "owner": "Endpoint", "name": "init",
   "methodArg": {"label": "method"}, "pathArg": {"label": "path"},
   "methodEnum": {"get": "GET", "post": "POST"}, "pathAnchor": "root"}
]}
```


`http-wrappers` v2 also supports an explicit `pathSuffix` list:

```json
{"format":"http-wrappers","version":2,"wrappers":[
  {"language":"swift","kind":"constructor","owner":"Endpoint","name":"init",
   "pathArg":{"label":"path"},"defaultMethod":"GET","pathAnchor":"root",
   "pathSuffix":[{"literal":"details"},{"argument":{"label":"segments"},"shape":"array"}]}
]}
```

Each suffix entry describes decoded single path segments. Literal `/` is encoded as `%2F` inside
one segment; use multiple entries to describe multiple segments. Scalar unknown values become `{}`;
array expansion requires a known literal/constant array, and unknown length remains dynamic.
Files are limited to 1 MiB, declarations to 32 suffix entries, and expansion to 64 segments.
A dynamic main path stays dynamic and unresolved suffix composition is counted.
Use separate v1 configuration for sibling producers that have not adopted v2.
Constructor label/type inference fixes apply to both v1 and v2; v2 without suffix has the same
behavior as v1 in this version. Wrapper `service` can distinguish configured HTTP services.


Arguments bind by label first and position second; an omitted verb takes `defaultMethod`, an enum
case (including the implicit member `.get`) maps through `methodEnum`, and anything else is
`methodDynamic`. Direct `URLRequest` and `URLSession` requests are read too when their verb and path
are statically provable — the verb comes from `httpMethod` assignments in the same body, and a
request that leaves the function unassigned is `methodDynamic` rather than a guessed `GET`. Paths
follow the shared producer rules and their conformance vectors (vendored under `conformance/`): a
whole-segment interpolation becomes `{}`, a query tail and a proven query-suffix local are stripped,
same-file constants are substituted, `URL(string:relativeTo:)` roots `/x` and bases `x`, and
anything else is kept as `dynamic` with the proven `channelPrefix`. Userinfo, query, fragment,
high-entropy segments and webhook paths are removed or masked in every field that carries path
text, including the source expression of a dynamic fact.

Paths can also come from another file in the project: `Paths.users.rawValue`, immutable
`static let` String members, and unambiguous type aliases are resolved across the scanned files.
Literal strings, references to those members and string concatenation are supported. Conditional
declarations, conflicting names, local value/type shadows, non-String members, mutable properties,
cycles and expressions exceeding the depth or path-length limits stay dynamic.
Constructor wrappers select a declaration whose configured path argument actually matches the call.
An implicit path enum case is resolved only when a complete, unambiguous initializer signature
proves its String-backed enum type, including safe project type aliases. Missing or competing
initializer surfaces, inherited/memberwise possibilities, and generic/local shadows stay dynamic.


Common libraries need no declaration. Each rule follows the library's source and was checked against
the request line a local server actually received (`experiments/http-client-oracle`, 35 requests on
macOS 26.7 with Alamofire 5.12.2 and Moya 15.0.3; a test replays the recording on every run):

| Library | Read without declarations |
|---|---|
| Foundation | `URL(string:)`, `URL(string:relativeTo:)` (RFC 3986 merge when the base is a literal URL), `appendingPathComponent` / `appending(path:)` / `appending(component:)`, URL constants on types, `httpMethod` assignments, `data(from:)` / `dataTask(with:)` / `dataTaskPublisher(for:)` |
| URLComponents | `scheme`, `host`, `port`, `path`, `percentEncodedPath` assigned in the same block before `.url` is read; a conditional assignment or `&components` makes the URL unreadable |
| Alamofire | `request` / `download` / `streamRequest` / `upload(_:to:)` on `AF`, `Session.default` or a property typed `Session`, with `method:` or the method's default verb (`upload` is POST); `URLRequest(url:method:)` and `request.method =`; routers conforming to `URLRequestConvertible` whose `asURLRequest()` appends `path` to a base |
| Moya | types conforming to `TargetType`, directly or through a project protocol: one fact per enum case from the `baseURL`, `path` and `method` switches (a protocol-extension default counts), `rawValue` paths included |

Foundation's `appendingPathComponent`, `appending(path:)` and `URLComponents.path` take decoded text
and percent-encode `?`, `#` and `%`, so a Moya `path` of `users/search?draft=1` is sent as
`/users/search%3Fdraft=1` and emitted that way — the join then shows the call never reaches
`/users/search`. A value that may hold slashes (`appending(path: path)`) is not guessed to be one
segment: the fact is `dynamic` with the proven `channelPrefix`. Router facts are attributed to the
**enum case** (or the target type, for a struct target): the index records every reference to the
case, so isthmus trace's reverse traversal reaches `provider.request(.users)` and the callers of a
function that receives the case as a parameter, which call-site attribution could not follow. A switch
arm with `where`, or one the command cannot read, makes that case `dynamic` rather than borrowing
another arm's path. A struct target whose `path` is a stored property is a descriptor filled in by its
callers — declare its initializer in `http-wrappers` (it is counted under `http-wrapper-undeclared:`
until you do); a router type that owns any declared wrapper is left to the declaration, so one request
is never emitted twice. A project that declares its own `Session`, `TargetType` or `URLRequestConvertible`
type is not read with these rules.

Test sources — `Tests/`, `…Tests` directories and `…Tests.swift` files, judged on the
project-relative path — are skipped and declared `sourceSets: {"tests": "excluded"}`;
`--include-tests` reads them and marks their facts `testSource`. `--service` names the document's
service for isthmus attribution. What the command could not turn into a fact is counted with the
contract's client-side prefixes: `route-call-coverage:` for request URLs it could not read, routers
whose request assembly it could not read, and files importing HTTP clients it does not model (APIKit,
Get, Siesta, RxAlamofire, Apollo, AFNetworking), `url-rewrite-interceptors:` for a custom Moya
endpoint mapping or an Alamofire request adapter that rewrites the URL, `generated-client-unscanned:`
for files importing an OpenAPI generated-client runtime,
`http-wrapper-undeclared:` for functions that pass a parameter through as the path,
`http-wrapper-unresolved:` for a declared wrapper that matched no declaration or no call, and
`ambiguous-base-join:` for a relative path after an unknown base. None of these gaps can bound the
paths of the calls they hide, so the document carries no `limitationScopes` and each gap applies to
every declaration, as the contract prescribes for unscoped limitations. The index is optional here: USRs
are attached when one is found, otherwise facts carry qualified names and `missing-route-usrs:`
says so. The same flags `bridges` refuses are refused for the same reason.

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

When a metric does need a ceiling, `thresholds` in `.cartograph.yml` turns it into warnings:
`max_instability` and `max_distance` bound the ratios, and `max_efferent_coupling` bounds Ce itself.
Instability is a ratio, so a module that depends on three others and one that depends on thirty
can both read 1.00; the absolute count is what catches a module reaching into every layer.
Isolated nodes are never flagged, and `metrics --strict` fails the run when a warning remains.
`check` does not evaluate metric thresholds; run `metrics --strict` as its own CI step.

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

A rule can carry an optional `rationale` (why the rule exists) and `hint` (how to fix a violation).
A bare violation invites the shortest edit that gets around the rule, especially from a coding agent
that turns reports straight into edits; the team's reasoning has to travel with the finding for the
fix to match the intent.

```yaml
rules:
  - name: Presentation must not reach the data layer directly
    from: Presentation
    deny: [Data]
    rationale: Views stay testable without a database.
    hint: Inject a use case from the Domain layer instead.
```

Both appear as `rationale:` and `hint:` lines in the violation's `details`, which the `text` and
`json` reports print, and under `--explain`. Formats that carry a single message line (`xcode`,
`github-actions`, `checkstyle`, `sarif`) do not show them. Multi-line values are folded onto one
line and empty values count as absent. Neither is part of the baseline fingerprint, so rewording
them never invalidates a baseline.

### `baseline` — adopt on an existing codebase

```bash
cartograph baseline --write .cartograph-baseline.json
```

Records today's findings so only *new* ones fail the build. Fingerprints are USR-based, so moving
code up and down a file does not resurrect a suppressed finding. The record includes the
`unused-import` and `unused-parameter` warnings that `fix` acts on, so a `fix --strict` dry run
fails only on new ones, and `dead` counts those warnings as suppressed. An import has no USR, so it
is identified by its file and the imported name, with the file written relative to the project
root: the committed baseline matches in a checkout at another path. A file outside the project
root keeps its absolute path.

Where the file is written is always an explicit decision: `--write`, or the project root default
(`.cartograph-baseline.json`) when the configuration sets no `baseline_path`. The `baseline_path`
configuration key names where suppression findings are *read* from, never where a baseline is
written — a key in the analyzed repository's config must not be able to point a write at an
arbitrary path, and if `baseline_path` is set while `--write` is missing, `baseline` exits 64 and
says so rather than guessing.

A baseline you name — with `--baseline` or `baseline_path` — must exist. When it does not, every
command that applies a baseline (`dead`, `cycles`, `metrics`, `rules`, `fix`, `query`, `check`)
exits 64 before opening the index, because a mistyped path would otherwise drop every suppression
and report the accepted findings as new ones. The default `.cartograph-baseline.json` stays
optional: with no name given, it is read only if it exists. Writing never reads a baseline, so
`baseline --write` can create the file a committed `baseline_path` names, and commands that do not
apply one run meanwhile. `serve` exits 64 at start for a missing `--baseline`; a missing
`baseline_path` makes `cartograph_query` and `cartograph_check` return an error result until the
file exists. A named file that exists but cannot be read is still a tool failure (exit 2).

### `--since` — review only what a pull request touched

```bash
cartograph dead --since origin/main --strict
```

Reports only findings **located in** modeled source files changed since a git revision — Swift,
Objective-C and Interface Builder suffixes — including committed changes, uncommitted changes to
tracked files, and new files you have not added yet. Other changed paths are listed as limitations
when they cannot be modeled. The graph is still built from the whole project, because reachability
computed on a partial graph is simply wrong; only the report narrows. A cycle has no single
location, so `cycles` and `check` report it when any node of its strongly connected component has
a declaration in a changed file — a type's extensions count, and so does any file of a module —
wherever its representative path runs.

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

These git lookups run inside the repository under analysis with its content filters, external diff
and textconv drivers, fsmonitor and submodule configuration disabled (see Known limitations), so a
tracked file whose content is unchanged but whose stat differs — for example in a copied working
tree or after a file is rewritten with the same bytes, until git refreshes its index (`git status`
does) — is reported as changed. A repository that configures a filter driver whose name cannot be
safely disabled makes `--since` stop with an error (exit 2) rather than risk running it.

The lookups also never fetch missing objects from a partial clone's promisor remote. A blobless
clone (`--filter=blob:none`) needs no fetch, because rename detection is off and the reported paths
are the same without it; a comparison that needs a tree the clone does not hold, as in a treeless
clone (`--filter=tree:0`), stops with an error (exit 2). Check out without a tree filter in CI.

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
  retain_equatable_properties: true
  retain_hashable_properties: true
  retain_raw_representable_enum_cases: true
  retained_names: ["*.shared"]
  retained_files: ["Sources/Generated/**"]

thresholds:
  max_cycles: 0
  max_unused_symbols: 0
  max_rule_violations: 0
  max_instability: 0.9
  max_distance: 0.8
  max_efferent_coupling: 8   # distinct nodes one node may depend on (Ce)

baseline_path: .cartograph-baseline.json    # where --baseline READS suppression findings;
                                            # `cartograph baseline` writes only via --write or the
                                            # project-root default, never to this key; once set,
                                            # the file must exist (exit 64 otherwise)
external_retentions_path: .isthmus/retentions.cartograph.json   # from isthmus, see `bridges`
derived_data_path: DerivedData    # where CI put -derivedDataPath
report_format: text               # text json xcode checkstyle github-actions sarif
graph_format: dot                 # dot mermaid json html
strict: false
```

Relative paths in the file — `index_store_path`, `derived_data_path`, `baseline_path` and
`external_retentions_path` — resolve against the project root wherever the command runs, so
`cartograph check --project ios` from a monorepo root reads `derived_data_path: DerivedData` as
`ios/DerivedData`. The same paths given on the command line (`--index-store`, `--derived-data`,
`--baseline`, `--external-retentions`) resolve against the current directory.

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
| Stored properties of `Equatable`/`Hashable` types | synthesized `==`/`hash(into:)` leaves no reference |
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

**`retain_equatable_properties` and `retain_hashable_properties` also default to on.** Periphery
defaults both off. A stored property whose only reader is the synthesized `==` or `hash(into:)`
leaves no index evidence, so keeping it is the conservative side; turn them off when you want such
properties reported. These two reasons apply only when the containing type is reachable.
A nested, never-created `Equatable` or `Hashable` type cannot retain an otherwise unused outer
type through its stored properties. `Codable` and explicit retention rules remain separate.

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

- **File-level freshness is not build-configuration completeness.** The oldest observed covering
  unit exposes partial rebuilds of the same file, including scoped header dependencies. It cannot
  reveal configurations never indexed. Obsolete units may keep a file stale or missing until a fresh
  index removes them. Legacy snapshots without oldest-unit metadata use the prior latest-date
  fallback and cannot establish multi-context freshness. Files without a known unit are reported separately.

- **`#Preview` macro bodies.** Types used only inside a `#Preview` block are kept only when the
  compiler recorded the reference during macro expansion. `PreviewProvider` conformances are
  detected directly; `#Preview` is not.
- **Interface Builder connections are not matched individually.** Every `@IBOutlet` and `@IBAction`
  is kept when `retain_interface_builder` is on, whether or not a xib actually connects it, so
  disconnected outlets are not reported. Custom classes *are* matched by name.
- **Objective-C uses compiled Clang index evidence.** Development builds include declarations and
  references from `.m`/`.mm` implementations and apply external retentions using actual `c:` USRs.
  Headers are not separately scanned and runtime message dispatch is not completely resolved.
  The conservative `retain_objc_accessible` default remains; unindexed sources remain a gap.
- **Callers in another language are known only through isthmus.** `bridges` exports what Swift
  declares; whether Dart or JavaScript actually calls it is a join this tool does not perform.
- **Assignment still counts as a use in the graph.** `dead` reports a property that is only ever
  assigned as an `assign-only` warning, using the read/write roles the index records (see `dead`).
  The graph itself has one `reference` edge kind, though, so `counter.neverRead = 1` still makes
  `bump()` a user of `neverRead`: `query` answers `reachable`, and `impact` and `graph` show the
  edge. Read the warning together with those answers rather than expecting them to agree.
- **`#if` branches that did not compile do not exist.** The index store only knows the
  configuration you built.
- **Reading an untrusted repository's `.git`.** `--since` (on every command that accepts it) and the
  default `language-traversal` revision run `git` inside the repository under analysis. A repository
  distributed with its `.git` directory can point git at commands of its own choosing, so these
  read-only lookups disable repository-configured content filters (`clean`/`smudge`/`process`),
  external `diff`/`textconv` drivers, `fsmonitor`, commit-signature display and submodule
  configuration, and never re-read the working tree through a filter. They also never fetch a
  missing object from a partial clone's promisor remote (`GIT_NO_LAZY_FETCH=1`), because that fetch
  runs commands the repository's configuration chooses (`remote.<name>.uploadpack`,
  `core.sshCommand`, an `ext::` URL). As a result a tracked file that is byte-identical but
  stat-changed (for example in a copied working tree, until git refreshes its index) is reported as
  changed; a file a filter normalized, such as Git LFS, looks changed and makes the traversal omit
  its `HEAD` revision; a submodule makes the traversal omit the revision; and a filter driver whose
  name cannot be disabled, or an object a lookup needs that the clone does not hold (an old tree in
  a treeless `--filter=tree:0` clone, say), makes `--since` fail and the traversal omit the
  revision. A blobless clone (`--filter=blob:none`) works as before. If a submodule holds sources
  you need analyzed, pass `--revision` yourself. git still runs — its own SECURITY notes warn that
  no git command is safe on a fully attacker-controlled `.git`, so analyze a `git clone --no-local`
  copy when in doubt — and your user-global git configuration is otherwise trusted. Refusing the
  fetch needs git 2.45 or a May 2024 security release of an older line (such as 2.39.4 or 2.44.1);
  an older git ignores the setting and still fetches.
- **Directory symlinks that leave the project root are not followed.** A directory symlink whose
  target resolves outside the project root (`Sources/App/vendor -> ../shared`, `-> /`) is skipped by
  every walk of the project, so the sources, headers and Interface Builder documents behind it are
  never read: their facts are absent from `dead`, `query`, `impact`, `check`, `routes`, `bridges`,
  `schema` and `dataflow`, and a declaration called only from there can be reported unreachable.
  Each `limitations` list counts such links outside your excludes as
  `symlinked-directories-outside-root`, with their project-relative paths. Cartograph treats it like a
  missing source: `impact --format language-traversal` proves no `bound` dispatch and
  `affected --format xcodebuild` prints no selectors. isthmus, by contrast, does not read that prefix
  as a coverage gap, so a link planted in the repository cannot soften an isthmus check.
  To analyze shared code reached this way, run with `--project` at a directory that contains both.
  Symlinks that stay inside the root are followed as before, and file symlinks are still read
  wherever they point.

## CI

Exit codes let a script tell "your code has problems" from "the tool did not run":

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Findings with `--strict`, or a configured threshold exceeded |
| `2` | Tool failure — no index store, an index that knows nothing about this project, unreadable index, invalid configuration |
| `64` | Usage error — unknown option, unknown subcommand, invalid value, or a flag combination the command cannot honor |

The SwiftPM command plugin keeps only `0` versus non-zero: SwiftPM exits 1 for any plugin failure,
and the original code survives only in its `error: cartograph exited with status N` line. Run the
binary or the official action where a script must tell these codes apart.

### The official action

The composite action downloads a release binary, builds the index, runs one gate and uploads the
SARIF report to code scanning. Get
[Cartograph Swift Analysis on Marketplace](https://github.com/marketplace/actions/cartograph-swift-analysis?version=action-v1.0.0):

```yaml
name: Cartograph
on: [push, pull_request]
permissions:
  contents: read
  security-events: write          # needed for upload-sarif
jobs:
  cartograph:
    runs-on: macos-15             # Cartograph loads libIndexStore from the Xcode toolchain
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0          # --since needs the base commit
      - uses: ictechgy/cartograph@action-v1.0.0
        with:
          command: check
          version: 0.28.0
          args: --since ${{ github.event.pull_request.base.sha || github.event.before }}
```

The `action-v1.0.0` tag is the action release; `version: 0.28.0` selects the CLI binary.
Pin both for a repeatable setup (`@main` tracks the development branch), and add `sha256` to pin
the archive itself. Marketplace's default
"Use latest version" currently follows the repository's latest CLI release; select
`action-v1.0.0` or use the version-specific link above for the action release. Inputs:

| Input | Default | Meaning |
|---|---|---|
| `command` | `check` | `check` (dead + cycles + rules together), `dead`, `cycles` or `rules` |
| `args` | — | Extra arguments, for example `--limit 500`, split with shell-like quoting and never expanded |
| `version` | `latest` | Release tag to download, or `latest` for the newest release (logged as a notice) |
| `sha256` | — | SHA-256 of `cartograph-<version>-macos-universal.tar.gz`; any other archive fails the step |
| `binary` | — | Path to an existing binary; skips the download |
| `project` | `.` | Project root; the index store is discovered from it |
| `build` | `swift` | `swift build` before analyzing, or `none` when you build yourself |
| `sarif-file` | `cartograph.sarif` | Where to write the SARIF 2.1.0 report |
| `upload-sarif` | `true` | Upload to code scanning (requires `security-events: write`) |
| `fail-on-findings` | `true` | `false` reports without failing the step |

Outputs: `exit-code` (the raw CLI code, including `64` for usage errors), `sarif-file` and `sarif-id`
(GitHub's upload receipt, empty when upload is disabled). The action
fails with a clear message on a non-macOS runner, because the tool loads `libIndexStore` from the
Xcode toolchain. Building with `xcodebuild`? Set `build: none` and either pass your binary through
`binary` or install Cartograph yourself and keep the manual commands below.

Every download is checked against the SHA-256 digest GitHub recorded for the release asset, and
only the `cartograph` executable is extracted; a missing or different digest, or an executable that
is not a regular file, fails the step before anything runs. The recorded digest catches a corrupted
or mismatched download, but GitHub computes it again when a release asset is replaced, so `sha256`
is what pins the archive: copy the asset digest from the release page without its `sha256:` prefix.
With `version: latest` the action logs a notice naming the release it used. The action gives
`GH_TOKEN` only to the step that reads the release; the downloaded binary first runs, as
`--version`, in a step without it.

`args` is split into words with shell-like quoting (Python `shlex`, as in the GitLab component),
but no shell evaluates it: `$`, backticks and glob characters stay literal, and
`--exclude "UI Tests/**"` reaches the CLI as one pattern. An unclosed quote or a trailing backslash
ends the step with `exit-code` `64` before the CLI runs.

`action-v1.0.0` predates these checks: it runs the downloaded binary unverified, has no `sha256`
input, and leaves `args` to the shell's word splitting and globbing.

The `action-v1.0.0` action rejects unexpected exit codes and missing reports, and never uploads a
report left by an earlier invocation. These fixes are not part of the existing `0.20.0` action tag.
The [integration workflow](.github/workflows/action-sarif.yml) uploads actual corpus findings;
[validation notes](docs/ACTION-CORPUS-CACHE.md) distinguish local checks from GitHub acceptance.

Without the action, the same gate is two commands:

```yaml
- run: swift build
- run: cartograph check --strict --report-format github-actions
```

For GitHub code scanning, emit SARIF:

```yaml
- run: cartograph dead --report-format sarif -o cartograph.sarif
- uses: github/codeql-action/upload-sarif@v4
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

### GitLab CI/CD component

[Cartograph CI in the GitLab Catalog](https://gitlab.com/explore/catalog/ictechgy/cartograph-ci)
runs the same analyzer on a macOS runner and publishes Code Quality findings alongside the native report:

```yaml
include:
  - component: gitlab.com/ictechgy/cartograph-ci/cartograph@1.0.0
    inputs:
      runner-tags: [macos]
```

The selected runner must already be available to your project; the component does not provision one.
The default CLI is pinned to `0.20.0` with its archive checksum. See the
[component guide](https://gitlab.com/ictechgy/cartograph-ci/-/blob/1.0.0/README.md)
for build inputs, report-only mode, analysis limitations and GitLab report views.

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

Async embedders can use `try await IndexStoreProvider(configuration: indexConfiguration).loadSnapshotAsync()`
to keep blocking disk/database work off the Swift cooperative executor. The existing synchronous
`loadSnapshot()` API remains available. On macOS 15+, its upstream async library loader uses a dedicated
task executor; on macOS 14, call the async entry from Swift tasks instead of blocking those tasks with
the synchronous API. The raw reader's async-to-sync library/store opening bridge has a 30-second wait
budget and fails without returning a partial snapshot. The database-backed mode's preceding synchronous
database initialization and the entire record scan are outside that budget. A C opening call that stalls
on the shared serial loader queue can delay later requests until they time out; requests are not isolated
from that stall and the queue is not forcibly reset. Cancellation is cooperative;
the async entry delivers cancellation after the blocking read returns, without claiming that C work
was interrupted. The minimum supported deployment target remains macOS 14; newer-runner validation
does not establish macOS 14 runtime coverage.

### 0.29 source migration

The source version is `0.29.0`; confirm its published asset on [GitHub Releases](https://github.com/ictechgy/cartograph/releases)
before selecting its installation tag. The release archive includes `Scripts/cartograph-git-impact.py`.
It requires Python 3.10+, Git, the Swift toolchain, and the matching Cartograph binary.

Existing `impact`, `--since`, and snapshot v1/v2 inputs remain readable. `--since` retains its current-index
selection semantics; use the Git helper for exact base/head or working-tree capture. The new
`--files-from` selector preserves an exact JSON file list, including an empty patch.
`cartograph_impact` adds optional `before` for a project-local snapshot. Preserve the entire comparison
and its session metadata when adapting MCP responses; traversal stays separate for each revision.

Embedding clients should rebuild. Snapshot v2 adds optional `inputFingerprint`; impact v1 adds optional
`input`. Older captures leave fingerprints unknown, and older decoders may drop these new fields.
New captures store a physical project root so relocated compiler paths remain consistent. An externally
supplied `AnalysisContext` has no proven capture generation and leaves its input fingerprint absent.
Ordinary API calls retain default arguments; captured initializer/function references may need their
types updated. Static candidates, incomplete results and unknown freshness never authorize test skipping.

### 0.28 source migration

[0.28.0 is published](https://github.com/ictechgy/cartograph/releases/tag/0.28.0).
The [release workflow](https://github.com/ictechgy/cartograph/actions/runs/39179128842) verified the
extracted universal archive before publication; the [tap update](https://github.com/ictechgy/homebrew-tap/pull/63)
also passed public archive installation and formula tests on macOS arm64. See [CHANGELOG.md](CHANGELOG.md)
for the complete scope and measured limits.

Embedding clients should rebuild against the new library. The optional
`IndexedSymbol.compilerUnitTest` field distinguishes a compiler observation from syntax-based
retention; old snapshots leave it unavailable, and `false` is not proof of a non-test.
Ordinary initializer calls retain defaults, but captured initializer function references may need
updating. Analysis snapshots stay v2; older readers may drop the new optional provenance.

`XCTestIdentityFacts` describes framework identity, not test-target membership. The public
SwiftPM membership model and pure facts are available for explicit captured inputs, while receipt
acquisition/validation is still test-support code, with no production command or input option.
The graph-only `XCTestIdentifier.identifier` overload now conservatively returns `nil`; pass identity
facts from the same snapshot to use the new overload, and preserve the documented module-to-target
assumption. Neither form establishes safe test skipping or arbitrary UI/E2E execution.

## Project language

Documentation and user-facing output are in English. Source comments are in Korean, which is the
maintainer's working language; identifiers are always English. Pull requests may be written in
either language.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Agents working in this repository should read
[AGENTS.md](AGENTS.md) first.

For the actual pinned IndexStoreDB CLI comparator, independent expected answers, setup costs and
measurement limits, see the [reproducible comparison protocol](docs/evaluation/indexstore-cli-benchmark.md).
CI preserves raw evidence; a synthetic fixture pass is not a universal performance or accuracy claim.

## Workspace and local package coverage

Build the workspace scheme and all relevant local-package targets, then pass that build's index
with `--index-store`. Automatic selection uses store/unit-directory recency, not target coverage;
when several candidates exist, output records the selected path, candidate count, and rule.
Compare `unindexed-sources`, stale/missing paths, and known local targets before relying on absent
callers or import-removal candidates. SDK/binary dependencies can legitimately have no local source
units. PBXSourcesBuildPhase/SwiftPM target membership is not fully reconstructed; unresolved coverage
continues to block narrowed `xcodebuild` selection. Run the whole suite when selectors cannot be verified.

For a standard local SwiftPM `.../index/store`, Cartograph reads only the adjacent configuration's
`description.json` (8 MiB cap), without executing `Package.swift`. A command must explicitly name
the selected index and existing local Swift sources before `build-module-coverage` can name a module
whose expected sources lack captured unit timestamps. Excluded sources, conflicting command membership,
stale metadata and unsupported input stay distinct. This is an observation against build metadata, not
proof of current target membership, definition coverage or build freshness. SDK/binary modules without
local sources are not marked missing. Xcode stores and compiler `out` overrides have no such mapping.
The description also participates in session invalidation; absence of a warning is not a coverage pass.

Git-ignored untracked sources and nested repositories are excluded from discovery; tracked files
take precedence over ignore rules. Exclusions are reported and do not prove build completeness.
Generated DI files can connect real callers. After reviewing their role, use
`retention.retained_files: ["Sources/Generated/**"]` to retain declarations without discarding edges.
A generated-looking name or a human-maintained design-token file is not automatically hidden.

File/module graphs use uniquely evidenced occurrence ownership, including extensions declared
outside the original type's module. Symbol/type graphs retain semantic ownership. Missing or
conflicting occurrence ownership remains an explicit attribution limitation.

`query.usedBy` contains reverse dependency neighbors, including implementation relationships.
Read each neighbor's `edges`: `overrides`, `conformance`, and `extends` describe implementation or
type relationships; they do not prove runtime invocation. `call`/`reference` and optional occurrence
evidence distinguish those observations. Generated Provider implementations are not automatically callers.

## License

MIT. See [LICENSE](LICENSE).

Cartograph is an independent project. It is not affiliated with Periphery or Apple.

## RN event emissions

`cartograph bridges --rn-events` exports `sendEvent(withName:body:)` from directly declared
`RCTEventEmitter` subclasses importing React, as a separate v2 `react-native-event` document.
Join it with an isthmus 0.8.0+ `extract-js --events` document. Dynamic names remain
unresolved; Objective-C events, Expo module events, wrappers and indirect inheritance are outside
this scan. Run this separately from the default bridge export.
