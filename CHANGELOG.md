# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `docs/scans/2026-09-flutter-plugins.md` measures what `bridges` sees on fourteen public Flutter
  and React Native repositories, with `Scripts/scan-public-plugins.sh` to reproduce it. The
  headline: first-party Flutter plugins have moved to Pigeon (703 `BasicMessageChannel`
  constructors in `flutter/packages`, one `FlutterMethodChannel`), community plugins still use string
  channels in the `FlutterPlugin.handle(_:result:)` shape, and about half of the popular plugins
  implement iOS in Objective-C where this tool sees nothing.
- The repository is a Claude Code plugin: `/plugin marketplace add ictechgy/cartograph` then
  `/plugin install cartograph@cartograph` installs the same skill `cartograph skill` writes. The
  plugin points at `Skills/`, so there is no third copy of the file beyond the two the drift test
  already compares.
- `docs/demo/agent-deletes-native-handler/` is a draft reproduction of the failure this tool
  exists to prevent, awaiting a Flutter toolchain to be run end to end.

### Fixed

- `bridges` attributes a `FlutterPlugin.handle(_:result:)` to the channel named by
  `registrar.addMethodCallDelegate(instance, channel:)` instead of guessing from "the only channel in
  the file". On the scanned repositories this turned 52 of 110 handlers from inferred into
  attributed. Handlers passed as method references (`setMethodCallHandler(handleCall)`) are
  attributed to their channel, and `setMethodCallHandler(nil)` is no longer reported as a
  registration. All three shapes came from audioplayers and plus_plugins, not from the corpus.

## [0.5.3] - 2026-09-05

### Changed

- `bridges` now emits project-relative locations and UTC millisecond timestamps, and
  `--target flutter|react-native` can split a mixed project into a v1 document that isthmus can
  consume without guessing.

## [0.5.2] - 2026-09-04

A follow-up review of 0.5.1 at maximum effort found that the scoping introduced there stopped at
function declarations. This release finishes it.

### Fixed

- Channel variables are looked up the same way constants are: a `let channel = …` in one type
  never stands in for a same-named variable in another, a closure sees the locals of the function
  that encloses it but its own locals do not leak outward, and a nested function's locals are keyed
  the same way in both passes. Each of these was a path to a literal the scanner had not actually
  seen. `dead --explain` says when a retention matched by qualified name rather than by USR.

## [0.5.1] - 2026-09-04

A review round over 0.5.0 with four independent reviewers (GLM, Codex, Antigravity, Grok). Every
change here closes a path where `bridges` could emit a literal it had not actually seen, or where
`--external-retentions` could keep or drop a declaration without saying so.

### Fixed

- `bridges` no longer resolves an implicit member (`FlutterMethodChannel(name: .channelName)`) to a
  same-named constant in the file. The receiver of that expression is `String`, not any type the
  file declares, so the literal it produced could be wrong and would have joined in isthmus as if
  certain. It is now `dynamic`. Constants are looked up by their declaring type — `A.name` and
  `B.name` no longer share one slot — and are resolved after the whole file has been read, so a
  `static let` declared below the `init` that uses it is followed as documented.
- A `case "…"` is attributed to a handler only when the switch subject really is a method name:
  `call.method`, or a local that was assigned from it (`let m = call.method`). A bare `.method`
  enum case no longer counts. Cases wrapped in `#if` are found. `FlutterMethodCall?` and
  `Flutter.FlutterMethodCall` parameters put a function in handler context like the plain type.
- `@objc(Name) @objcMembers` classes export only what Objective-C can see: `private`, `fileprivate`
  and `@nonobjc` members are skipped, nested types do not inherit the exposure, and extensions of
  the class do.
- The Objective-C macro scanner ignores macros in trailing `//` comments, string literals and
  `#if 0` regions, keeps a block whose `@end` is missing when the next `@implementation` starts,
  and treats an empty `RCT_EXPORT_METHOD()` as a dynamic name rather than an empty one.
- `bridges` attaches a USR by the exact selector only; when that fails it falls back to the base
  name only if exactly one declaration carries it. Index paths and walked paths are compared after
  resolving symlinks, so `/private/tmp` and `/tmp` no longer split a file's symbols from its facts.
  The symbol table is built once per run instead of once per file.
- `target` is written as `null` when there are no facts, as the exchange format requires, instead
  of being omitted.
- `--external-retentions`: a retention that carries a USR no longer shadows a name-only retention
  for the same qualified name. When a name-only retention matches several declarations they are
  all kept, as the retention rules require, and the count is reported as
  `external-retentions-ambiguous`. The file is read before the index store, so a broken file fails
  even where there is no index. `generatedAt` with fractional seconds (which is what isthmus
  writes) is parsed, so the staleness check fires. Evidence strings are stripped of control
  characters before they reach the terminal.
- New limitation counters: `unscanned-message-channels` (Pigeon's `BasicMessageChannel`),
  `objective-c-handlers` (RN handlers in `.m` files, which carry no USR and so cannot be retained
  through a retentions file), and `objc-named-classes` now includes the method handles it implies.
  `mixed-targets` says when `target` was chosen on a tie.
- A local `let name = "…"` is visible only inside the function that declares it. Hoisting it to
  the file would have turned every bare `name` in the file into that literal, including references
  to a global declared elsewhere. `let m = call.method` aliases are likewise scoped to their
  function or handler closure, and a function nested inside a method body is neither an enclosing
  declaration nor an exported React Native method. Members of a `private extension` are not
  exported; an explicit `@objc private func` is; `static` and `class` methods are not.
- The agent skill no longer implies that a retentions file being present settles an `unreachable`
  handler, and names `retainedByMember` alongside `retained` as the states that carry
  `reason: externalBridge`. Reinstall it with `cartograph skill --force`; the copy written by 0.4.0
  or 0.5.0 keeps the old wording until then.
- Because the retentions file is now read before the index store, a broken file fails every
  analysis command, not only `dead`, which is the same treatment a broken baseline gets.

## [0.5.0] - 2026-09-04

### Added

- `cartograph bridges` exports what Swift declares at a language boundary, in the `bridge-facts`
  exchange format that isthmus joins with the Dart or JavaScript side. A Flutter method-call
  handler or a React Native module is called from another language, which the compiler index never
  sees, so until now it was reported unreachable with no way to say otherwise. The only link
  between the two sides is a string — `FlutterMethodChannel(name:)`, `case "takePhoto":`,
  `@objc(CalendarManager)`, `RCT_EXPORT_METHOD(addEvent:)` — and this command reads those literals
  with SwiftSyntax (and a text scan for the Objective-C macros), then attaches the USR the index
  holds for the enclosing declaration so the answer can come back as a retention.

  It states facts, not verdicts. A non-literal name is kept with its source expression and marked
  `dynamic` rather than dropped; one level of constant is followed, but only through `Self`, `self`
  or a type declared in the same file, so a same-named member on some other receiver never turns
  into a literal it is not. A `case "…"` outside a handler closure counts only inside a function
  that takes a `FlutterMethodCall`, and is attributed to the file's single channel (counted as
  inferred) or left `null`. `limitations` counts what could not be resolved. The Objective-C
  macro files are the first `.m` sources this tool reads at all; block comments are blanked first
  so a module someone commented out does not come back as a handler.

- `--external-retentions <path>` (or `external_retentions_path`) reads the retentions isthmus hands
  back and keeps each named declaration as a retained root with reason `externalBridge`. `dead
  --explain` quotes the evidence — which platform, file and line invoked which method on which
  channel — instead of pointing at the file. `query` lists the file's provenance and how many of its
  retentions name nothing in the index, so a stale file shows up as a limitation before it shows up
  as a wrong deletion, and a file generated before the index store was written is flagged as
  stale. A retention that carries a USR matches only that USR; the name is used only when isthmus
  had no USR to give, so a same-named declaration in another module cannot be kept by mistake. A
  configured path that does not exist is a tool failure, not a silent no-op: someone who supplied
  the file expects it to be applied.

- `dead --report-format json` now carries the same `limitations` list as `query`. An agent that
  starts from the unused list and walks it towards deletions had no way to learn that the project
  has Objective-C sources, that the index predates its edits, or that an external retentions file
  was (or was not) in effect. As with `query`, the list is never empty on `dead` — the
  single-configuration note always applies — and the key is absent from `cycles` and `rules`,
  which have no retention rules to be limited by.

### Fixed

- `dead --report-test-only` no longer reports a type as "reached only from tests" when the only
  thing keeping it alive is its compiler-synthesized memberwise initializer. No test had touched
  it; the synthesized root was excluded from the production traversal but the type it belonged to
  was not excluded from the candidates. The false-positive corpus caught this while a public struct
  stub was being added for the bridge fixture.

- The agent skill named retention reasons that do not exist (`objcExposed`, `codingKeys`,
  `caseIterable`). It now lists the values the tool actually emits.

### Changed

- The false-positive corpus gains an Objective-C target. Every iOS project available for
  dogfooding was pure Swift, so the `objective-c-sources` limitation had never been observed on a
  real `.m` file; `verify-fixtures.sh` now checks it is counted, and pins the `bridges` output
  against a real index so the syntax-to-USR attachment is verified by the compiler rather than by a
  hand-built snapshot.

## [0.4.0] - 2026-09-04

### Added

- `cartograph skill` installs `.claude/skills/cartograph/SKILL.md`, teaching a coding agent to ask
  this tool about a symbol instead of grepping for it. The same file is committed under `Skills/`
  and a test fails if the two drift, so the version a human reviews is the version an agent
  receives.

  Most of the skill is about what an answer does not prove. An agent turns a verdict into an edit
  without pausing, so a file that only taught the commands would make wrong deletions faster: it
  says that `unreachable` is a fact about the graph rather than permission to delete, that
  `limitations` must be read in the same breath, that `suppressedByBaseline` means the team already
  decided, and that loading the whole graph answers nothing `query` could not.

  It also states the one thing most likely to cause real damage: `retain_public` is off by default,
  so in a library or framework the entire public surface is reported unreachable, and an agent that
  acted on that would break every consumer outside the repository.

  Passing the rules is not treated as permission. A checklist an agent can complete becomes a
  licence to proceed, which would reproduce the exact failure the skill exists to prevent, so the
  file says what to do afterwards — delete only what was asked, report what was checked, and name
  the limitations that applied rather than deleting and hoping.

- `cartograph query <symbol>` answers three questions about one declaration as JSON: who uses it,
  what it uses, and whether it is reachable from a retained root. Every other command sweeps the
  project and reports findings; this one answers a question the caller already has, and reverse
  reachability ("who uses this?") was not answerable at all before.

  The output is deliberately not a verdict. `state` is a fact about the graph and the retention
  reason ships as a value rather than as prose, so the caller decides what it means. Every response
  carries `limitations` — counted from the Objective-C sources and Interface Builder documents
  actually present in the project, not copied from the README — so a consumer that never reads the
  documentation still learns why an `unreachable` answer might be wrong. A baseline the team already
  accepted is marked `suppressedByBaseline` instead of being re-litigated, and a name matching
  several declarations returns the candidates with their USRs instead of a guess.

  `--depth` and `--limit` bound the answer in each direction, with `truncated` flags so a capped
  answer is never mistaken for a complete one. Reachability is always computed on the symbol-level
  graph regardless of `--level`, which is why the response states its own level.

  Each neighbour carries every relation that reaches it rather than one of them — a subclass that
  both calls and overrides comes back as `["call", "overrides"]`, and reporting one of the two would
  let a consumer delete on half the picture. Containment is reported separately as `members` and
  `declaredIn`, because a type does not *use* its own methods, but omitting them entirely made
  `dependsOn` come back empty for every class on a symbol-level graph, which reads as "depends on
  nothing".

  `limitations` is counted from the project within the same include/exclude scope the graph uses,
  and ships on `notFound` too: asking about a name declared in Objective-C and being told only "no
  such thing" hides the difference between absent and invisible. Besides Objective-C sources and
  Interface Builder documents it reports sources edited since the index store was written — the most
  dangerous silence for a consumer deciding to delete — and a configured path or edge-kind filter
  that could be the reason `usedBy` is empty.

## [0.3.0] - 2026-09-03

### Added

- `Fixtures/FalsePositiveCorpus` collects the patterns that produced false positives in real code,
  as a package that actually compiles, and `Scripts/verify-fixtures.sh` compares the whole finding
  list in both directions — a new false positive and a lost detection fail equally. Unit tests run
  on hand-built snapshots, so they cannot check what the compiler writes into the index store, and
  every false positive found in this repository lived exactly there. CI runs it.

- `dead --report-test-only` reports production declarations reached only from tests or previews.
  They are not dead, so they are reported as `info` and never fail a build, but a team wants to know
  that tests are the sole caller. Declarations inside test targets are excluded — a module that
  contains test declarations is a test target — previews do not count, since a `#Preview` lives in
  the production module beside the view it previews. On a real project this cut the list from 408
  to 90.
- `cycles --explain <node>` lists the cycles one node takes part in, each with the edge to cut.
  `rules --explain <node>` shows which layer a node landed in, which pattern put it there, and
  which rules start from that layer. Reporting a tangle is accurate; naming the cut is actionable.
  Participation is judged by strongly connected component, not by the representative path, so a node
  in the same tangle is never told it is outside the cycle. `cycles --explain` counts its answer as
  a finding (being in a cycle is a bad state that `--strict` should catch); `rules --explain` does
  not, because a layer assignment is not a bad state. Neither is narrowed by `--since`: you asked
  about one node, so the answer is computed against the whole graph.
- `--since <git-revision>` reports only findings located in files changed since that revision —
  committed changes, uncommitted changes to tracked files, and new files. The graph is still built
  from the whole project, because reachability on a partial graph is simply wrong; only the report
  narrows. It answers "what did this change touch", not "what did this change cause", so `baseline`
  refuses to combine with it: a partial record would later make every out-of-scope finding look new.
- Syntax analysis results are cached per file, keyed by file content. A run that changes no source
  skips SwiftSyntax parsing entirely. The cache lives in the temporary directory, never in the
  repository, and is keyed by content rather than modification time so a checkout or a copy cannot
  serve a stale result. `CartographEnvironment.usesSyntaxCache` turns it off.

### Fixed

- A property used only through its projected value (`Child(text: $name)`) is no longer reported as
  unused. The index records the reference against `$name`, and nothing linked it back to `name`,
  so SwiftUI state that is plainly in use was reported as dead. Only the projected value is folded
  into the wrapped property — backing storage (`_name`) is referenced by the synthesized memberwise
  initializer, and folding that would hide genuinely unused properties.
- `@NSApplicationDelegateAdaptor`, `@UIApplicationDelegateAdaptor`, `@WKApplicationDelegateAdaptor`
  and `@WKExtensionDelegateAdaptor` properties are retained. SwiftUI owns the delegate; no code
  reads the property, but removing it breaks the app.
- Cases of a `CaseIterable` enum are retained. A case consumed only through `allCases` has no
  reference in the index, because the synthesized `allCases` body has no source range — the same
  mechanism as raw-representable enums.

### Performance

- Source discovery no longer calls `stat` twice per directory entry. It now reads each entry's type
  from the single enumeration that already knows it. On a 13,000-symbol project whose repository
  contains 210,000 entries, `dead` went from 33s to 2.2s — a profile showed the whole runtime was
  file-tree traversal, not analysis.

### Changed

- Layer-violation baseline fingerprints now include the rule name and the edge kind. Two rules
  denying the same edge used to share one fingerprint, so baselining one silently suppressed the
  other. Regenerate layer-rule baselines with `cartograph baseline`.
- `cartograph init` no longer writes an active `include:` key. An include that matches nothing
  reports "no findings" and exits 0 — a false all-clear in an Xcode project with no `Sources/`
  directory.

### Fixed

- A relative `--project` path (`--project .`) aborted the process. libIndexStore asserts on
  relative paths, so the run died with SIGABRT before the exit-code contract could apply. Project
  paths are now resolved to absolute before reaching the index layer.
- A glob with no separator now matches any path component, as gitignore does. `exclude: ["Pods"]`
  used to filter nothing under `Pods/`, and `retained_files: ["Generated"]` retained nothing at
  all — files the user asked to protect were reported as unused.
- Unknown keys inside `layers` and `rules` are now reported. A typo such as `denyed:` left the
  rule inert with no warning, so `rules` passed with no enforcement at all.
- `metrics` now fails when a configured threshold is exceeded, matching every other command. The
  same config file previously contained thresholds that gate CI and thresholds that do not.
- `metrics --report-format sarif` (and `checkstyle`, `xcode`, `github-actions`) now emits that
  format instead of the metrics JSON document, which code scanning rejected.
- `dead --explain` now applies the baseline, so `--strict` no longer reaches opposite verdicts for
  the same repository depending on the reporting flag.
- `dead --explain` on a name that matches nothing now exits 64 instead of 0, so a typo in a CI
  script is visible.
- Baseline write failures are reported as tool failures (exit 2) instead of findings (exit 1).
- Broken symlinks are no longer returned as source files, and two names for the same file are
  counted once.
- `SourceLocation.relative(to:)` handles the macOS `/tmp` ↔ `/private/tmp` duality, so report
  paths are relativized in both spellings.
- Mermaid labels escape `#` first, so a name containing an entity-like sequence is not eaten.
- Escaped identifiers (`` `default` ``) and failable initializers (`init?(rawValue:)`) now match
  their syntax declarations. Neither matched before, so a public declaration was analyzed as
  internal and reported unused.
- Declarations inside function bodies, accessors and closures are no longer recorded as syntax
  facts. A local sharing a member's name could be nearer to the index line and hijack the match,
  overwriting the member's accessibility or attaching a `cartograph:ignore` meant for the local.
- Operator declarations are recorded like every other declaration.
- DerivedData ownership matching tolerates case differences, symlinked checkouts and XML entities
  in `WorkspacePath`. Any of those made the check fall back to every same-named directory.

## [0.2.0] - 2026-09-02

### Changed

- Analysis results move with this release. The accessor and `main.swift` fixes add edges that were
  previously missing, so findings that were false positives disappear. Regenerate any baseline with
  `cartograph baseline`.
- `IndexStoreProvider.defaultDatabasePath(forStore:libraryPath:libraryModificationDate:)` no longer
  defaults its toolchain arguments. Callers must supply them, because a DerivedData store path is
  stable across Xcode upgrades and omitting the identity silently reopened a cache written by an
  older toolchain.

### Fixed

- Declarations referenced only from inside a computed property's getter or setter, or from a
  `willSet`/`didSet` observer, are no longer reported as unused. The index records such calls
  against the accessor, which is not a graph node, so those edges were dropped entirely. Accessor
  references now resolve to their property. This mattered most for code built around computed
  properties, such as RxSwift's `Reactive<Base>` extensions.
- Executables whose entry point is `main.swift` are no longer reported as entirely unused.
  Top-level statements have no enclosing declaration, so they produced no edges at all, and
  top-level declarations carry no `@main` marker. Each `main.swift` now gets a synthetic
  `top-level code` node that owns its statements, and its top-level declarations count as entry
  points.
- Generic type parameters are no longer graph nodes. The index records them as type aliases, so
  `Base` in `struct Reactive<Base>` was reported as unused.
- Syntax facts now match index symbols by name rather than by line alone. Two declarations on one
  line no longer swap accessibility and attributes, and a declaration whose attribute sits on the
  preceding line (`@discardableResult`, `@objc`) no longer loses its facts entirely — previously
  the name fallback never matched a function, because index names carry argument labels
  (`emit(_:options:)`) and syntax names do not.
- Conformances declared in an extension (`extension Money: Codable {}`) now reach the extended
  type, so its stored properties and enum cases are retained.
- `test`-prefixed methods in production code are no longer treated as XCTest cases. The full
  XCTest contract is checked: an instance method of a class or extension, taking no arguments and
  returning nothing.
- A trailing `// cartograph:ignore` on the same line as a declaration now applies to it. Trailing
  comments live in the declaration's trailing trivia, which was never read.
- Interface Builder documents are parsed by XML rules rather than an exact `customClass="` match,
  so `customClass = 'ThemedButton'` is found, values inside XML comments are skipped, attribute
  names no longer match as suffixes of longer names, and `.XIB` matches case-insensitively.
- A DerivedData directory belonging to a different checkout of a same-named project is no longer
  selected. Ownership is resolved from `info.plist`'s `WorkspacePath`.
- `.build/<triple>/debug/index/store` layouts are searched.
- `deinit` declarations now carry syntax facts.
- The index cache path now requires the toolchain identity from its caller, and the definition
  occurrence's location wins over a declaration-only one.

## [0.1.0] - 2026-09-02

First release.

### Added

- `graph` renders the dependency graph at module, file, type or symbol resolution, in Graphviz DOT,
  Mermaid, JSON or a self-contained HTML page with no external resources.
- `cycles` finds circular dependencies via Tarjan's algorithm, reports a representative shortest
  cycle per strongly connected component, and names the lowest-weight edge as the cheapest cut.
- `dead` finds declarations unreachable from retained roots, with retention rules covering entry
  points, XCTest, swift-testing, Objective-C exposure, Interface Builder, raw-value enum cases,
  `CodingKeys`, property-wrapper and result-builder requirements, `Codable` stored properties,
  external overrides and conformances, dynamic dispatch, and comment commands.
- `dead --explain` reports why a declaration survives — the retention reason, or the path from a
  retained root.
- `metrics` computes afferent and efferent coupling, instability, abstractness and distance from
  the main sequence, and classifies each node into the main sequence, the zone of pain or the zone
  of uselessness.
- `rules` enforces ArchUnit-style layering rules declared in `.cartograph.yml`, and reports nodes
  that no layer covers.
- `baseline` records current findings so only new ones fail the build. Fingerprints are USR-based
  and survive line moves.
- `init` writes a commented configuration template.
- Diagnostic output as text, JSON, Xcode, Checkstyle, GitHub Actions or SARIF.
- Index store auto-detection across SwiftPM layouts and Xcode DerivedData, preferring the most
  recently written store.
- `CartographKit` ships as a library product for embedding the pipeline directly. Its query API
  (`cycles(in:)`, `unusedCode(in:)`, `metrics(in:)`, `layerViolations(in:)`) returns values;
  baselines, thresholds and formatting live in a separate command API so an embedder never parses
  rendered text. `loadContext()` reads the index once and serves every resolution from it.

### Notes

- `retain_objc_accessible` defaults to on, unlike Periphery. Mixed-language UIKit projects were its
  largest source of false positives.
- Exit codes: `0` success, `1` findings with `--strict` or a threshold exceeded, `2` tool failure,
  `64` usage error.
- Supported toolchain: Swift 6.3 or later on macOS 14+, verified on 6.3.3 in CI and 6.4 in
  development. `indexstore-db` publishes no semantic version tags, so `Package.swift` pins the
  `release/6.4.1` branch. Each Swift release moves that pin and gets a changelog entry.
- macOS only in practice: the index store format and `libIndexStore` discovery are Apple-toolchain
  specific.

[Unreleased]: https://github.com/ictechgy/cartograph/compare/0.5.3...HEAD
[0.5.3]: https://github.com/ictechgy/cartograph/compare/0.5.2...0.5.3
[0.5.2]: https://github.com/ictechgy/cartograph/compare/0.5.1...0.5.2
[0.5.1]: https://github.com/ictechgy/cartograph/compare/0.5.0...0.5.1
[0.5.0]: https://github.com/ictechgy/cartograph/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/ictechgy/cartograph/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/ictechgy/cartograph/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/ictechgy/cartograph/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ictechgy/cartograph/releases/tag/0.1.0
