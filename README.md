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
| Graph export | — | ✅ DOT, Mermaid, JSON, self-contained HTML |
| SARIF for code scanning | — | ✅ |
| `@objc` retained by default | ❌ opt-in | ✅ on by default |

The retention rules — the genuinely hard-won knowledge about what *looks* unused but must not be
deleted — are absorbed wholesale. See [Retention rules](#retention-rules).

## Install

Requires macOS 14+ and a Swift toolchain (Xcode or the Command Line Tools) at run time —
Cartograph loads `libIndexStore` from it. CI runs on Swift 6.3.3; development happens on 6.4.

**Homebrew** — a prebuilt universal binary, installs in seconds:

```bash
brew install ictechgy/tap/cartograph
```

**Mint** — builds from source, no tap to add:

```bash
mint install ictechgy/cartograph@0.3.0
```

**No install at all** — for a Swift package, add Cartograph as a dependency and use the command
plugin. Everyone on the team and CI then runs the same version:

```swift
// Package.swift
.package(url: "https://github.com/ictechgy/cartograph", from: "0.3.0"),
```

```bash
swift package cartograph dead --strict
swift package cartograph graph --format mermaid > graph.mmd
```

The plugin declares no write permission, so it never prompts; redirect stdout to save output.

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
`.build/debug/index/store`, `.build/out`, and `~/Library/Developer/Xcode/DerivedData/<project>-*`.
When several exist it takes the most recently written one, because analyzing a stale index fails
quietly rather than loudly. Recent SwiftPM writes an index automatically, so for a Swift package
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
    "index-staleness: 3 of 214 source file(s) changed after the index store was written, so a call added since the last build is not here yet",
    "single-configuration: the index store knows only the configuration that was built, ..."
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
  reports Objective-C sources, Interface Builder documents, sources edited since the index store was
  written, and a configured path or edge-kind filter that could be the reason `usedBy` is empty.
- **A baseline the team already accepted is marked as such** (`suppressedByBaseline`), so nobody
  re-litigates a decision that was already made. It is only set when the declaration would actually
  have been reported.
- **A neighbour carries every relation that reaches it**, not one of them. A subclass that both
  calls and overrides comes back as `"edges": ["call", "overrides"]`; reporting one would let you
  delete on half the picture.
- **A name matching several declarations returns the candidates, not a guess.** Ask again with one
  of the USRs.

```console
$ cartograph query Client
{
  "candidates" : [
    { "qualifiedName" : "Network.Client", "usr" : "s:7Network6ClientC" },
    { "qualifiedName" : "Storage.Client", "usr" : "s:7Storage6ClientC" }
  ],
  "level" : "symbol",
  "limitations" : [ ... ],
  "requested" : "Client",
  "status" : "ambiguous"
}
```

`members` and `declaredIn` carry containment, which is not use. A type's own dependencies live in
its members on a symbol-level graph, so `dependsOn: []` on a class is normal and does not mean the
class depends on nothing — follow `members`.

`--depth` follows more than one edge in each direction and `--limit` caps how many neighbours come
back; `depth` on each neighbour says how far it was, and `truncated` tells you when the cap bit.
Reachability is always computed on the symbol-level graph regardless of `--level`, which is why
`level` is in the response. A neighbour's `location` is where it is *declared*, not where it uses
the subject. Fields with no value are omitted rather than set to null: `declaredIn` on a top-level
declaration, `reason` on one that is not retained, `path` on one that is not reached, and `result`
or `candidates` depending on `status`.

An unknown name exits 64, so a typo in a script does not pass silently as "nothing uses it".

### `metrics` — architecture metrics

```bash
cartograph metrics --level module
```

Robert C. Martin's package metrics, computed on your graph. Run against this repository:

```
NODE                   Ca  Ce     I     A     D           ZONE
---------------------  --  --  ----  ----  ----  -------------
CartographCore          8   0  0.00  0.05  0.95   zone-of-pain
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
would later make every out-of-scope finding look new.

`baseline` and `--since` answer different questions and compose: the baseline is the CI ratchet
that keeps today's debt from growing, `--since` is the pull-request lens. In CI, check out with full
history (`fetch-depth: 0`), or the revision will not resolve.

## Configuration

`.cartograph.yml` in the project root. Run `cartograph init` for a commented template.
Command-line options always win over the file.

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
| Overrides and conformances whose base lies outside the analyzed code | the framework calls them |
| `subscript(dynamicMember:)`, `@_dynamicReplacement`, `dynamic` | dynamic dispatch |
| Compiler-synthesized declarations | you cannot delete them |
| `// cartograph:ignore`, `// cartograph:ignore:all` | you said so |
| `retained_names`, `retained_files` globs | you said so |

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

- **`#Preview` macro bodies.** Types used only inside a `#Preview` block are kept only when the
  compiler recorded the reference during macro expansion. `PreviewProvider` conformances are
  detected directly; `#Preview` is not.
- **Interface Builder connections are not matched individually.** Every `@IBOutlet` and `@IBAction`
  is kept when `retain_interface_builder` is on, whether or not a xib actually connects it, so
  disconnected outlets are not reported. Custom classes *are* matched by name.
- **Objective-C sources are not analyzed.** `.m` and `.h` files are invisible; Swift declarations
  they reach are covered by `retain_objc_accessible`, which is on by default.
- **`#if` branches that did not compile do not exist.** The index store only knows the
  configuration you built.

## CI

Exit codes let a script tell "your code has problems" from "the tool did not run":

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Findings with `--strict`, or a configured threshold exceeded |
| `2` | Tool failure — no index store, unreadable index, invalid configuration |
| `64` | Usage error — unknown option, unknown subcommand, invalid value |

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
