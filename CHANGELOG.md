# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/ictechgy/cartograph/compare/0.1.0...HEAD
[0.1.0]: https://github.com/ictechgy/cartograph/releases/tag/0.1.0
