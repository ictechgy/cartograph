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
and its archived source is still the best documentation of the problem. Its open-source repository is
now archived under MIT, and development continues as a [commercial product](https://periphery.pro)
that is free for indie and hobby projects and for open source of any size — so if unused code is all
you need, use it. Cartograph is not a fork, and not a free replacement; it is a different framing of
the same machinery.

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
| How does a value reach this function? | not answerable | `dataflow` returns bounded interprocedural contexts as JSON |
| Callers in Dart or JavaScript | invisible | `bridges` exports the Swift side of a platform channel; `--external-retentions` reads the join back |
| Graph export | — | ✅ DOT, Mermaid, JSON, self-contained HTML |
| SARIF for code scanning | — | ✅ |
| `@objc` retained by default | ❌ opt-in | ✅ on by default |

The retention rules — the genuinely hard-won knowledge about what *looks* unused but must not be
deleted — are absorbed wholesale. See [Retention rules](#retention-rules).

## Install

Requires macOS 14+ and a Swift toolchain (Xcode or the Command Line Tools) at run time —
Cartograph loads `libIndexStore` from it. CI runs on Swift 6.3.3; development happens on 6.4.
Swift 5 language-mode projects are supported: build them with your Swift 6 toolchain (Swift 5 mode
is a compiler option, and the index it writes is read the same way) and analyze as usual.

**Homebrew** — a prebuilt universal binary, installs in seconds:

```bash
brew install ictechgy/tap/cartograph
```

**Mint** — builds from source, no tap to add:

```bash
mint install ictechgy/cartograph@0.10.1
```

**No install at all** — for a Swift package, add Cartograph as a dependency and use the command
plugin. Everyone on the team and CI then runs the same version:

```swift
// Package.swift
.package(url: "https://github.com/ictechgy/cartograph", revision: "0.10.1"),
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
becomes a name. When several directories match by name, the `WorkspacePath` in each one's
`info.plist` decides which belongs to this project; if none of them names it, Cartograph says so
rather than picking the most recent.
When several candidates exist it takes the most recently written one, because a stale index fails
quietly rather than loudly. The exception is ambiguity: if two or more name-matched directories
remain and none proves ownership through `WorkspacePath`, Cartograph lists them instead of
guessing — the same rule that makes `query` return candidates instead of a guess.
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
  reports Objective-C sources, Interface Builder documents, sources edited since their own index unit was
   written, a package that exports library products while `retain_public` is off, and a path filter
   that narrows the analysis *beyond the defaults*, or an edge-kind filter — any of which could be
   the reason `usedBy` is empty. The default excludes alone do not count —
  they are a noise guard, not a narrowing you chose, and a warning that fires on every project is
  not read. File-level timestamps prevent a build of another target from hiding an edited file.
  `unindexed-sources` counts files without a known index unit; `missing-sources` counts indexed
  files that disappeared. `unreadable-sources` reports other read failures: declarations in those
  files are kept with reason `sourceUnavailable` until source access is restored and the analysis
  is rerun. These limits also appear in `dead` reports.
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
result, not a failure. If any name is not found the exit code is 64, but **every** result is still
returned — one typo does not cost you the other forty-two answers. A malformed requests file is
rejected before the index is opened and exits 64, not 2, because it is an argument problem rather
than a failure to analyze. The names that were not found are listed on stderr, so a failed sweep
does not send you back to diff the JSON.

A batch answers every request from one snapshot. A sweep run one name at a time can straddle a
rebuild and answer half its questions from a different index.

This is the `symbol-query-batch` v1 format that dartograph writes, so an agent learns one response
shape rather than one per language.

`dead --report-format json` carries the same `limitations` list, so a sweep that starts from the
unused list sees what the graph could not, without a `query` per entry. Every format a CI job reads
carries it too, because a gate that passes while the analysis was blind is the one thing a gate must
never do: `text` counts them in the summary line and prints a `limitations:` block after it, `xcode`
emits a location-less `note:`, `github-actions` emits a `::notice` with no file so it lands on the
run summary, and `sarif` puts them in `runs[].invocations[].toolExecutionNotifications`. None of
that changes the exit code or the finding count. `checkstyle` is the exception: its schema has no
slot that is not a file's error, and adding one would raise the finding count its consumers show,
so pair it with one of the others when you need the limitations.

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
depth 2. `--call-depth` accepts 1 through 8. The command rejects `--level`, `--since`, and
`--report-format`: value analysis has its own context graph, answers one subject, and is JSON-only.

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
`.m` file. `bridges` reads those literals out of the sources with SwiftSyntax (and a text scan for
Objective-C), attaches the USR the index has for the enclosing declaration, and writes the
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
(up to 64 steps). Mutable strings, unknown shadowing bindings, operators, interpolation and cross-file values
remain dynamic. See the [constant/Needle/storyboard checks](docs/scans/2026-09-analysis-blindspots.md).

Cross-function value propagation is not implemented: parameters, returns, callbacks and async
results remain unresolved bridge names. Query paths describe symbol dependencies. See the
[interprocedural analysis check](docs/scans/2026-09-interprocedural-flow.md) for runtime comparisons and scope.

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
  "tool" : { "name" : "cartograph", "version" : "0.10.1" },
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

### `--since` — review only what a pull request touched

```bash
cartograph dead --since origin/main --strict
```

Reports only findings **located in** files changed since a git revision — committed changes,
uncommitted changes to tracked files, and new files you have not added yet. The graph is still built
from the whole project, because reachability computed on a partial graph is simply wrong; only the
report narrows.

It answers "what did this change touch", not "what did this change cause". If your commit deletes
the last call to a symbol declared in a file you did not touch, that symbol becomes dead but its
finding sits in the untouched file and is not reported. The baseline catches that case on the next
full run; `--since` is a lens, not a proof. `baseline` therefore refuses `--since`: a partial record
would later make every out-of-scope finding look new. `query` refuses it too: one declaration is not
a finding list, so the lens has nothing to attach to. The same goes for `graph` (the whole project,
not a report), `bridges` (a partial export would read as missing handlers downstream) and the
`--explain` answers (one subject, like `query`). Only `dead`, `cycles`, `metrics` and `rules` over
the finding list honor `--since`.

`baseline` and `--since` answer different questions and compose: the baseline is the CI ratchet
that keeps today's debt from growing, `--since` is the pull-request lens. In CI, check out with full
history (`fetch-depth: 0`), or the revision will not resolve.

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

baseline_path: .cartograph-baseline.json
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

### Known limitations

- **File-level freshness is not build-configuration completeness.** A file's latest index unit
  prevents unrelated targets from hiding its edits, but does not prove that every configuration
  containing that same file has been rebuilt. Files without a known unit are reported separately.

- **`#Preview` macro bodies.** Types used only inside a `#Preview` block are kept only when the
  compiler recorded the reference during macro expansion. `PreviewProvider` conformances are
  detected directly; `#Preview` is not.
- **Interface Builder connections are not matched individually.** Every `@IBOutlet` and `@IBAction`
  is kept when `retain_interface_builder` is on, whether or not a xib actually connects it, so
  disconnected outlets are not reported. Custom classes *are* matched by name.
- **Objective-C sources are not analyzed.** `.m` and `.h` files are invisible to the graph; Swift
  declarations they reach are covered by `retain_objc_accessible`, which is on by default. `bridges`
  does read `.m` files, but only for React Native export macros, as text.
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
- run: cartograph dead   --strict --report-format github-actions
- run: cartograph cycles --strict
- run: cartograph rules  --strict
```

For GitHub code scanning, emit SARIF:

```yaml
- run: cartograph dead --report-format sarif -o cartograph.sarif
- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: cartograph.sarif
```

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
