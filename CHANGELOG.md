# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `query --batch <requests.json>` answers many declarations from one index read. The requests file
  is a JSON array of 1 to 1000 names or USRs, at most 1 MiB, and the results come back in request
  order with duplicates kept so the caller can pair the two arrays by index. Sweeping a `dead`
  report one name at a time cost a process and an index read per name; on a 7,466-symbol app,
  asking about all 43 findings took 19.6 s that way and 0.47 s in one batch, and all 43 answers
  were identical to the one-at-a-time answers. An `ambiguous` name is a normal result. If any name
  is not found the exit code is 64, but every other result is still returned. A malformed requests
  file is rejected before the index is opened and exits 64 rather than 2, because it is an argument
  problem and not a failure to analyze; the names that were not found are listed on stderr so a
  failed sweep does not send you back to diff the JSON. A batch answers every request from one
  snapshot, so a sweep cannot straddle a rebuild the way one process per name can. The output is
  the `symbol-query-batch` v1 format that dartograph already writes, so an agent learns one
  response shape rather than one per language.
- An ambiguous name now returns candidates you can choose between. Each candidate carries its
  `kind`, `module` and declaration site alongside the USR, and `dead --explain` prints the same.
  `qualifiedName` is `Module.name` and leaves out the owning type, so asking a real app about
  `body` returned 127 candidates of which 122 printed as the identical string `HealthMap.body`;
  the same query now yields 127 distinct rows.
- `query` and `dead --explain` accept `Container.member`, so you can narrow an ambiguous name with
  a name you just read in the answer instead of copying a USR. Nesting works to any depth
  (`Outer.Inner.leaf`), the outermost part may be the module (`App.Outer.leaf`), and an
  intermediate container may be left out (`Outer.leaf`) because knowing only the outer type is the
  normal case; over-matching comes back as `ambiguous` rather than a guess. The container may be
  the type an extension extends, so a member declared in an extension answers to its type's name.
  This runs only when the plain lookup found nothing, so a declaration literally named
  `Detail.body` still wins.

### Fixed

- Three retention reasons made `dead --explain` ungrammatical. The sentence is "X is retained
  because it is <reason>", and three reasons began with a verb, producing "it is satisfies a
  protocol declared outside the analyzed code". They are now "required by a protocol declared
  outside the analyzed code", "an override of a declaration outside the analyzed code" and
  "matched by a retain rule in the configuration". A test now reads every reason through the
  sentence it will appear in.

### Changed

- References are no longer sorted on the way out of the index store. Every reference in the project
  was put through an `O(n log n)` sort whose comparator built a three-`String` tuple per comparison,
  and there are roughly ten references per symbol. The order was never read: `CodeGraph.init` folds
  edges by signature and sorts them again, the retention scan builds a `Set`, and the extension-target
  map is keyed by a USR that a Swift extension can only have once. On a 7,466-symbol app each command
  loses about 0.13 s of wall clock — `dead` 0.64 s to 0.48 s, `graph --level symbol` 0.66 s to 0.53 s,
  `cycles` 0.49 s to 0.36 s. Output is byte-identical across seven commands on four projects; the only
  difference found anywhere was the `generatedAt` field of `bridges`, which differs between two runs of
  the same binary. That the order does not reach the output was true by accident and is now a test.

  One place did depend on the order and is now closed. The extension-target map let the last
  `.extends` reference for a USR win, which was harmless while the input was sorted. A Swift
  extension USR can only name one extended type, and instrumenting the map found no duplicate on
  four apps, the corpus, and all four graph levels; but "last wins" with an unsorted input means
  the index decides, so the map now takes the smaller USR and cannot vary with order.

- The path filter is evaluated once per file rather than once per symbol. It is a property of the
  file, and a file carries dozens of symbols, so the same path was matched against every glob
  thousands of times; a sampled profile put that one call at about a third of every command. On a
  7,466-symbol app `graph --level symbol` drops from 0.71-0.75 s to 0.64-0.65 s and `dead` from
  0.64-0.68 s to 0.58-0.63 s, with byte-identical output. The wall-clock share is smaller than the
  profile share because reading the index store dominates.

### Removed

- The known limitation "a retained member inside an unreachable type still answers retained" is
  gone from both READMEs and from the agent skill, where it was rule 6. The change below fixed it;
  the documents still described the old behaviour. Verified on a real app: `query` on the `body` of
  an unreachable `View` now reports `state: unreachable`, and `dead --explain` says "not reachable
  from any retained root" instead of naming the framework.

### Fixed

- A member is no longer reported as `retained` inside a type the same run calls `unreachable`.
  A `body` that satisfies `View`, or an `encode(to:)` that satisfies `Codable`, is kept because the
  framework calls it — and the framework calls it only if something constructs the type. Asking
  about the type said "never used" while asking about its member said "the framework calls this, do
  not delete it", in one answer. Witness retentions now wait for their owning type to become
  reachable, reusing the mechanism the reverse-override traversal already had, and a retention that
  never activates is dropped so the reason set stays a subset of what is reachable. A witness with
  no owning type — an extension of a type outside the analyzed code — stays unconditional, because
  there is nothing for it to wait for.

  On four real projects the reported findings and the test-only list are unchanged; only the
  reachable count falls, which is the point.

## [0.7.0] - 2026-09-06

### Changed

- Types are reported again. Two retention rules were keeping every type alive: a member that
  overrides or satisfies a declaration outside the analyzed code kept its owning type, and so did a
  compiler-synthesized member such as a memberwise initializer. Between them, a `View` nobody draws
  and a `struct NeverUsed: Equatable {}` were immortal, and the tool had never reported a single
  unused type on a real app. Both rules now keep the member and stop there. The same guard covers a
  conformance written as `extension X: View`, so the two spellings of one piece of code cannot give
  opposite answers.

  Measured on four projects, with every new finding checked by hand — each has exactly one
  occurrence, its own declaration:

  | project | findings | new | no longer reported |
  |---|---|---|---|
  | cartograph | 0 → 0 | 0 | 0 |
  | HealthMap (7,466 nodes) | 43 → 43 | 7 types | 7 members of those types |
  | AnbuRadar | 6 → 6 | 0 | 0 |
  | Gakjaba | 1 → 2 | 1 type | 0 |

  The HealthMap row is the point: the count did not move, but seven shell members left and the seven
  types that hold them arrived. Deleting the members, as the old output invited, left an empty type
  that could never be reported again.

  A member can still answer `retained` while the type that holds it is `unreachable` — a `body` is
  kept because the framework calls it, which is true only if something constructs the type. `dead`
  reports the type in that case, so a sweep is right; a single `query` on the member is not. Both
  READMEs and the agent skill now say so.

### Fixed

- A type used only as an enum case's associated value, as the right-hand side of a `typealias`, or
  as the witness of an `associatedtype` now has an edge to it in the graph. The index records those
  references, but with no relation to the declaration that holds them, and the adapter only built an
  edge when a relation was present — so those types had no incoming edge at all and were kept alive
  only by the retention rule for compiler-synthesized members. That is an accident, not an answer,
  and it is the reason narrowing the retention rules would have reported types whose deletion does
  not compile. The reference is attributed to the closest preceding declaration in the same file,
  which is all the index gives: it has locations, not ranges.

  The attribution is deliberately narrow. It applies only where the indexer is known to omit the
  relation — an enum case, a `typealias`, an `associatedtype` — and never to an implicit occurrence.
  A wider rule attaches macro-expanded code to whatever declaration precedes the attribute line,
  because `@Observable` records its expansion at the attribute rather than at the type: on one real
  project that invented two circular dependencies between types that do not reference each other.
  Measured on four projects, this version adds only the intended edges (`+4`, `+18`, `+6`, `0`) and
  changes no finding and no cycle.

## [0.6.0] - 2026-09-06

### Added

- A package that exports library products while `retain_public` is off now says so in
  `limitations`. Its callers live outside the repository, so the entire public surface comes back
  unreachable, and a consumer that turns that list into deletions breaks every dependent. Reproduced
  on a package with one library product: two public types reported with the default, none with
  `--retain-public`. The check reads the manifest and stays silent when any executable product is
  declared, because then the entry point is inside the repository and reachability means what it
  says.

- The limitations list reaches every report format a CI job reads, not only JSON. A gate that passes
  while the analysis was blind to twelve Objective-C files is the one thing a gate must never do,
  and until now the only way to see that was to ask for JSON. `text` counts them in the summary line
  and prints a `limitations:` block after it, `xcode` emits a location-less `note:`,
  `github-actions` emits a `::notice` with no file so it lands on the run summary, and `sarif` puts
  them in `runs[].invocations[].toolExecutionNotifications` rather than in `results`, so code
  scanning does not count them as alerts. Exit codes and finding counts are unchanged. `checkstyle`
  is left alone on purpose: its schema has no slot that is not a file's `<error>`, and adding one
  would raise the finding count its consumers display.

### Changed

- Two limitations that fired on every run are gone from the list. `single-configuration` counted
  nothing: it was a statement about index stores in general rather than about this project, which
  is the definition of copying the README into the answer. `configured-path-filter` fired even on a
  project with no `.cartograph.yml`, because `exclude` defaults to `defaultExcludes`; it now fires
  only when include is set or exclude narrows the analysis past those defaults. Measured on four
  real projects, both fired on all four. A warning that fires every time is not read, and this list
  is where the tool says what it cannot see. The `#if` sentence now lives in the Known limitations
  of both READMEs and in the agent skill, where it belongs. `dead --report-format json` omits the
  `limitations` key entirely when there is nothing to report, rather than emitting an empty array.

- `IndexStoreLocator.derivedDataCandidates` takes `projectNames: [String]` instead of a single
  `projectName`. Ownership has to be decided over the union of every name at once: with one call per
  name, a name whose owner is proven does not stop another name's group from falling back to
  unverified directories. `CartographError.indexStoreNotFound` also carries a `derivedData:`
  associated value, defaulted to nil so existing construction still compiles; code that pattern-matches
  that case has to be updated.

### Fixed

- The SwiftPM dependency line both READMEs advertise does not resolve. `from: "0.5.5"` fails with
  `package 'cartograph' is required using a stable-version but 'cartograph' depends on an
  unstable-version package 'indexstore-db'`, because indexstore-db publishes no semantic-version
  tags and is pinned to a release branch. `revision: "0.5.5"` resolves and builds, so that is what
  the instructions say now, with the reason next to it. Reproduced both forms in a throwaway package.

- Auto-detection finds the index store of an Xcode project that does not live in a directory of its
  own name. The candidate names came only from the last component of `--project`, so
  `ios/HealthMap.xcodeproj` was looked up as `ios-<hash>` and never found, and the "Searched:" list
  held no DerivedData path at all, so there was no way to tell it had even been considered. Every
  Flutter and React Native app has that shape. Names now come from each `.xcodeproj` and
  `.xcworkspace` directly inside the project root, plus the folder's own name, which a Swift package
  opened in Xcode still needs. Only the root is scanned: recursing would make `Pods/Pods.xcodeproj`
  a name and open another project's store. Verified on three real apps on the author's machine, all
  of the `ios/<Name>.xcodeproj` shape, which now analyse with no flags at all.
- A DerivedData directory whose `info.plist` names a different project is never used, and when two
  or more match by name while none of them names this project, the run fails and lists them instead
  of silently taking the most recent. Picking one there analyses another project's index with
  nothing in the output to say so.
- Ownership is decided by containment in either direction. A `WorkspacePath` pointing at the parent
  of `--project` means the analysis was scoped to a source directory inside the workspace, which is
  a common way to run it, and the previous one-directional test called that a foreign checkout.
- The flat layout that `xcodebuild -derivedDataPath <dir>` writes is a candidate too, so the
  `--derived-data` flag works for the CI recipe the README documents.
- The failure message says what it looked for in DerivedData: the root, the names tried, and which
  of the four situations it hit — no such root, no name matched, names matched but nothing was built
  there, or directories matched but none of them names this project.
- `index-staleness` is reported for a store found under DerivedData. The freshness check resolved the
  store a second time without the DerivedData path, so it silently found nothing there and said
  nothing. That silence covered exactly the projects this change now opens, and Xcode-built projects
  are where an index goes stale most often.
- An analysis whose index store knows none of the project's declarations now fails with exit code 2
  instead of reporting "no findings" and exiting 0. A green `--strict` gate over zero analysed
  declarations reads as "this code is clean", which is the one thing a gate must never say by
  accident. The error names the project, the store and how it was chosen, the `libIndexStore` it
  used, how many Swift files are under the project and how many survived include/exclude, and the
  unit count — the three counts are what separate a wrong `--project` from a filter that removed
  everything from a store built for another checkout. `--allow-empty-index` opts out for a run that
  is meant to analyse nothing, and then `limitations` carries `empty-index` so the answer still says
  it is a statement about nothing. `bridges` does not go through this guard: its scan is syntactic
  and `Scripts/scan-public-plugins.sh` runs it against an index that contributes nothing by design.
- Exclude globs no longer match the project root's *ancestor* directories. Matching them against the
  absolute path meant that a project living under a directory named `DerivedData`, `Pods`,
  `Generated`, `.build` or `Carthage` had every one of its files removed by the default excludes, so
  the graph was empty and `--strict` passed. The same happened to any user pattern whose name
  appeared above the project root. Excludes are now matched against the project-relative path;
  patterns written as absolute paths still apply to absolute paths, and includes are unchanged
  because narrowing those is the failure this filter exists to prevent. Reproduced with one package
  built in two directories that differed only in their parent's name: 7 nodes and 3 findings under
  one, 0 nodes and a clean exit under the other.
- `retained_files` globs no longer match the project root's ancestor directories either. The rule
  lived in a second place and only the exclude side had been fixed, which left the same false green
  by the opposite route: one pattern whose name appears above the project root retained every
  declaration, so `dead` reported nothing. Reproduced with `retained_files: ["**/repro/**"]` on a
  project under a directory of that name, turning 3 findings into 0 with exit 0. Both directions now
  go through one method on `PathFilter`, because a rule kept in two places gets fixed in one.
- A run that used `--allow-empty-index` says so in the text summary, not only in the JSON
  `limitations`: `dead: no findings (analysed nothing — --allow-empty-index) — …`. A CI log shows
  the summary line and nothing else, so an escape hatch that is invisible there disarms the guard
  completely.
- The error no longer advertises `--allow-empty-index` when it has already named the cause. On the
  wrong-path and everything-filtered branches the last and most prominent line used to be the flag
  that silences the check, which is the opposite of the next action. It now appears only when the
  tool genuinely cannot tell a misconfiguration from a deliberately empty run.
- A project with Objective-C sources and no Swift is told that, instead of being told its
  `--project` is wrong. A Flutter or React Native `ios/` directory is usually that shape, and the
  path is right.
- A project root given as a symbolic link is walked to the end. The URL-based directory enumeration
  fails with `ENOTDIR` on a link to a directory while `directoryExists` follows it, so the traversal
  found a directory it could not read and silently produced an empty tree. Pointing at this
  repository through a link reported 0 nodes where the real path reported 1,644.

## [0.5.5] - 2026-09-05

### Fixed

- `bridges` reads through a parenthesized switch subject, `switch (call.method)`. sensors_plus writes
  it that way and five of its handlers were invisible; the first real Dart-to-Swift join on
  plus_plugins is what showed it.
- The `bridges` document now carries `objective-c-sources: N` when the project has `.m` or `.mm`
  files. A Flutter handler written in Objective-C is not in the Swift facts, and without the
  limitation isthmus reports the Dart invocation as unhandled, which it is not — package_info_plus
  and share_plus are that case.

## [0.5.4] - 2026-09-05

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

[Unreleased]: https://github.com/ictechgy/cartograph/compare/0.5.5...HEAD
[0.7.0]: https://github.com/ictechgy/cartograph/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/ictechgy/cartograph/compare/0.5.5...0.6.0
[0.5.5]: https://github.com/ictechgy/cartograph/compare/0.5.4...0.5.5
[0.5.4]: https://github.com/ictechgy/cartograph/compare/0.5.3...0.5.4
[0.5.3]: https://github.com/ictechgy/cartograph/compare/0.5.2...0.5.3
[0.5.2]: https://github.com/ictechgy/cartograph/compare/0.5.1...0.5.2
[0.5.1]: https://github.com/ictechgy/cartograph/compare/0.5.0...0.5.1
[0.5.0]: https://github.com/ictechgy/cartograph/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/ictechgy/cartograph/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/ictechgy/cartograph/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/ictechgy/cartograph/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ictechgy/cartograph/releases/tag/0.1.0
