# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/ictechgy/cartograph/compare/0.2.0...HEAD
[0.2.0]: https://github.com/ictechgy/cartograph/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ictechgy/cartograph/releases/tag/0.1.0
