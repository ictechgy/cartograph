# Bounded Objective-C Flutter scan — 2026-09-08

This records the **unreleased change for issue #64**, not capabilities of the published 0.8.2
binary. It is a source-shape check, not a Flutter application build or a claim of complete
Objective-C coverage.

## Inputs and observations

The files were fetched read-only at the same pinned revisions used in the earlier public plugin
scan. No plugin implementation is vendored in this repository. The regression corpus is handwritten.

| Repository / revision | File | Registrations | Method handles | Result |
|---|---|---:|---:|---|
| fluttercommunity/plus_plugins `13e1704` | package_info_plus iOS `FPPPackageInfoPlusPlugin.m` | 1 | 1 | `getAll`, channel `dev.fluttercommunity.plus/package_info` |
| fluttercommunity/plus_plugins `13e1704` | package_info_plus macOS `FPPPackageInfoPlusPlugin.m` | 1 | 1 | `getAll`, same channel |
| fluttercommunity/plus_plugins `13e1704` | share_plus iOS `FPPSharePlusPlugin.m` | 1 | 1 | `share`, channel `dev.fluttercommunity.plus/share`; immutable NSString constant |
| fluttercommunity/plus_plugins `13e1704` | battery_plus iOS `FPPBatteryPlusPlugin.m` | 1 | 3 | Public harness verifies all three ObjC methods alongside macOS Swift |
| Baseflow/flutter-geolocator `209f356` | `GeolocatorPlugin.m` | 0 | 0 | File contains conditional compilation; no active branch guessed |
| tekartik/sqflite `263864b` | `SqflitePlugin.m` | 0 | 0 | File contains conditional compilation; no active branch guessed |

These are six files across three repositories, with positive extraction for **three plugins**.
The six previously invisible plugins have not all become fully observable. In particular, a
conditional outside the registration method still defers the whole file in this first scanner.

Sources and licenses:

- [package_info_plus iOS](https://github.com/fluttercommunity/plus_plugins/blob/13e1704/packages/package_info_plus/package_info_plus/ios/package_info_plus/Sources/package_info_plus/FPPPackageInfoPlusPlugin.m),
  [macOS](https://github.com/fluttercommunity/plus_plugins/blob/13e1704/packages/package_info_plus/package_info_plus/macos/package_info_plus/Sources/package_info_plus/FPPPackageInfoPlusPlugin.m),
  [share_plus](https://github.com/fluttercommunity/plus_plugins/blob/13e1704/packages/share_plus/share_plus/ios/share_plus/Sources/share_plus/FPPSharePlusPlugin.m)
  and [battery_plus](https://github.com/fluttercommunity/plus_plugins/blob/13e1704/packages/battery_plus/battery_plus/ios/battery_plus/Sources/battery_plus/FPPBatteryPlusPlugin.m)
  — repository license BSD-3-Clause.
- [GeolocatorPlugin.m](https://github.com/Baseflow/flutter-geolocator/blob/209f356/geolocator_apple/darwin/geolocator_apple/Sources/geolocator_apple/GeolocatorPlugin.m)
  — repository license MIT.
- [SqflitePlugin.m](https://github.com/tekartik/sqflite/blob/263864b/sqflite_darwin/darwin/sqflite_darwin/Sources/sqflite_darwin/SqflitePlugin.m)
  — repository license BSD-2-Clause.

## What the implementation promises

The token scanner preserves string values and UTF-8 positions, ignores comments and string-like
code, and recognizes direct channel factories/initializers, inline blocks and same-file registrar
delegates. Only positive, direct `isEqualToString:` conditions are emitted as static method names.
Dynamic names remain dynamic; uncertain scopes, pointer mutation, shadowing, macros and unsupported
forwarding must not be rewritten as a convenient literal.

Every Objective-C implementation fact carries `sourceLanguage: objective-c` and no fabricated
Swift symbol. It can satisfy a bridge join without claiming that cartograph's Swift graph contains
that declaration. New isthmus reports matched graph-external handlers as `omittedObjectiveCHandlers`
in the Swift-only retention document. An unmarked Swift match missing its symbol still fails.

`objective-c-sources` remains a general, **unscoped** gap even after successful extraction. Finding
three channel literals does not prove there is no fourth channel behind an unsupported expression.
The first producer-side scoped gap is instead an opaque Swift handler supplied by an external
object or factory: its registration channel can be known even when its body is not inspected.

## Reproduction boundaries

`ObjectiveCFlutterScannerTests` contains positive and negative source-shape cases. The real
`FalsePositiveCorpus` compiles the Objective-C delegate shape without Flutter SDK by supplying
header declarations, exports its two bridge facts, and keeps the Swift dead-code lists unchanged.
The isthmus contract tests cover scoped/unscoped coexistence, old strings, malformed metadata,
source-language validation, complete Swift retentions and observable Objective-C omissions.

The per-file observations above were also checked with an optimized harness built from
`CartographCore`, `ObjectiveCLexer.swift` and `ObjectiveCFlutterScanner.swift`, using the files
unchanged. The package_info registration/branch locations are lines 13/18 in both files; share_plus
uses lines 271/290. No runtime or platform-specific correctness is inferred from these counts.

## Indexed identity correction

Issue #64's follow-up correctly distinguishes index availability from graph scope. Apple Clang
records Objective-C USRs: the real corpus index contains
`c:objc(cs)ObjCCameraPlugin(cm)registerWithRegistrar:` and
`c:objc(cs)ObjCCameraPlugin(im)handleMethodCall:result:`. The producer now reads `.m`/`.mm`
occurrences for bridges and attaches these actual IDs only on unique path, selector and declaration
line matches. Ordinary analysis continues to discover Swift files only. A Swift-only dummy index
still yields symbol-less ObjC facts; that is an input limitation, not an Objective-C limitation.
