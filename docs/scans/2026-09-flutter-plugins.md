# Bridge facts in the wild: 14 public Flutter and React Native repositories (2026-09-05)

What `cartograph bridges` sees on the Swift and Objective-C side of public plugins, measured to
answer three questions: how much of the ecosystem still crosses the language boundary with string
channels, what the scanner attributes with confidence versus what it has to count as a limitation,
and which real code shapes the scanner had never seen.

## Method

Each repository was cloned shallow at the commit shown and scanned with `cartograph bridges
--format json` (development build after the fixes this scan produced, equivalent to 0.5.4). No
Flutter SDK was involved: `bridges` walks the sources with SwiftSyntax and reads `.m` files as text,
and only needs an index store to attach USRs. A dummy SwiftPM target at each repository root provided
an index store, so every fact here has `missing-handler-usrs` and no USR; that column is omitted.
`example/` directories were excluded from the file counts. Pigeon files were counted by the
generator's header comment.

The script is `Scripts/scan-public-plugins.sh` in this repository. The Dart side was not scanned
(dartograph does that; see isthmus).

## Results

| repository | commit | Swift files | ObjC files | Pigeon Swift files | channel-register | method-handle | attributed | channel null | inferred | dynamic | BasicMessageChannel | EventChannel | module-export |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| flutter/packages | a929c2f | 280 | 56 | 114 | 1 | 0 | 0 | 0 | 0 | 0 | 707 | 5 | 1 |
| firebase/flutterfire | 7a5c295 | 137 | 37 | 15 | 4 | 8 | 8 | 0 | 0 | 1 | 150 | 10 | 3 |
| fluttercommunity/plus_plugins | 13e1704 | 30 | 11 | 0 | 7 | 14 | 14 | 0 | 0 | 0 | 0 | 8 | 0 |
| bluefireteam/audioplayers | cd475c7 | 7 | 0 | 0 | 2 | 23 | 0 | 23 | 0 | 1 | 0 | 2 | 0 |
| juliansteenbakker/mobile_scanner | 997502a | 10 | 0 | 0 | 1 | 13 | 13 | 0 | 0 | 0 | 0 | 2 | 0 |
| MaikuB/flutter_local_notifications | b475bc8 | 5 | 4 | 0 | 1 | 14 | 14 | 0 | 14 | 0 | 0 | 0 | 0 |
| juliansteenbakker/flutter_secure_storage | e144260 | 8 | 1 | 0 | 3 | 7 | 7 | 0 | 0 | 0 | 0 | 2 | 0 |
| Baseflow/flutter-permission-handler | fc60b52 | 2 | 20 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Baseflow/flutter-geolocator | 209f356 | 2 | 13 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| ryanheise/just_audio | 454a24c | 2 | 11 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| tekartik/sqflite | 263864b | 2 | 8 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| react-native-device-info | 06a9ed6 | 1 | 3 | 0 | 0 | 29 | 29 | 0 | 0 | 0 | 0 | 0 | 2 |
| react-native-webview | d65a961 | 1 | 5 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 1 |
| mrousavy/react-native-vision-camera | 91bae1f | 429 | 7 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

"attributed" is a method-handle with a literal channel that came from a registration call, not a
guess. "inferred" is the fallback where a file constructs exactly one channel and the handler is
attributed to it. "channel null" is a handler the scanner saw but could not attach to any channel.

## What the numbers say

**The first-party ecosystem has left string channels.** `flutter/packages` has 114 Pigeon-generated
Swift files and 707 `BasicMessageChannel` constructors against a single `FlutterMethodChannel`
registration. flutterfire is mid-migration (15 Pigeon files, 150 message channels, 4 method channels
left). For these, the join isthmus performs today has nothing to join; the exchange format needs a
message-channel fact kind before it can cover them, and the scanner counts them as
`unscanned-message-channels` so the gap is visible rather than silent.

**The community plugin tier still uses string channels, and mostly in one shape.** plus_plugins,
mobile_scanner, flutter_secure_storage, flutter_local_notifications and audioplayers cross the boundary
with `FlutterMethodChannel` and a `FlutterPlugin.handle(_:result:)` method. That shape is exactly
what an agent-driven cleanup would misjudge: the handler's `case "…"` arms have no Swift caller.

**Half of the popular plugins are invisible to this tool.** permission-handler, geolocator,
just_audio and sqflite implement iOS in Objective-C. `cartograph` reports them as
`objective-c-sources` and finds no facts. Any claim about coverage has to say this first.

**Nitro and JSI modules produce no string facts, correctly.** react-native-vision-camera has 429
Swift files and zero bridge facts because it does not use `RCT_EXPORT_*` or `@objc(Name)`; the
older React Native modules (device-info, webview) still do, all of it in `.m` files, which means
no USR and therefore no retention round-trip.

## What the scan found in the scanner

Three code shapes the corpus had never contained, all fixed and pinned by unit tests in the same
change as this report:

1. **Delegate registration is a fact, not a guess.** `registrar.addMethodCallDelegate(instance,
   channel: c)` names the type whose `handle(_:result:)` receives the channel. Before this scan the
   scanner attributed those handlers by the "single channel in the file" heuristic and counted them
   as inferred: 52 of 110 handlers. After: 14, all in flutter_local_notifications, whose registration
   happens in another file.
2. **Handlers passed as method references.** audioplayers registers with
   `channel.setMethodCallHandler(handleGlobalMethodCall)`. The referenced method is the handler and
   its arms belong to that channel.
3. **`setMethodCallHandler(nil)` is an unregistration**, and was being emitted as a
   `channel-register` fact.

One shape remains open and is counted honestly: audioplayers' `handle(_:result:)` forwards the call
to `handleAsync(_:result:)` inside a `Task`, and its 23 arms live there. Following one hop of
`call` through a local function call is the next scanner change if a second plugin shows the shape.

## Limits of this scan

Fourteen repositories chosen by the author, not sampled. Swift side only. No USRs, so nothing here
tests the retention round-trip; the corpus and the isthmus `plus_plugins` gate do that. Dart-side
call counts, which would say how many of these handlers anything actually invokes, need dartograph
and were out of reach in the authoring environment.
