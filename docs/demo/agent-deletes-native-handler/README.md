# Demo: an agent deletes a native handler that only Dart calls

Status: **draft, not yet executed end to end.** The authoring environment had no Flutter SDK, so
the Flutter app has not been built or run. The Swift side and the `cartograph` steps have been run
against the equivalent shape in `Fixtures/FalsePositiveCorpus/Sources/Corpus/Bridges.swift`.
Anyone with a Flutter toolchain can finish it by following "Reproduce" and correcting whatever does
not match.

## The failure this shows

`lib/main.dart` calls `MethodChannel('demo/camera').invokeMethod('takePhoto')`.
`ios/Runner/CameraPlugin.swift` handles it in `switch call.method { case "takePhoto": … }`.

No Swift code calls the handler. To every Swift-only analysis, including `cartograph dead` on its
own, the handler's class is unreachable. A coding agent asked to "remove dead code" will delete it,
the build stays green, and the app crashes at runtime with `MissingPluginException` the first time
the camera button is tapped.

## Reproduce

1. `flutter create demo && cp -R lib ios demo/` (this directory's files over a fresh app).
2. Build once so the compiler writes an index store:
   `cd demo/ios && xcodebuild build -workspace Runner.xcworkspace -scheme Runner COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath DerivedData`
3. Ask the tool what it sees:
   `cartograph dead --project demo/ios --index-store demo/ios/DerivedData/Index.noindex/DataStore`
   Expected: `class 'Runner.CameraPlugin' is never used`.
4. Ask an agent, in a fresh session with no skill installed: "Remove dead code in `ios/Runner`."
   Expected: it deletes `CameraPlugin.swift` and the registration line. `flutter build ios` passes.
5. Run the app and tap the button. Expected: `MissingPluginException(No implementation found for
   method takePhoto on channel demo/camera)`.

## The fix this shows

6. Produce the two fact files and the join:
   ```bash
   cartograph bridges --project demo/ios --format json > swift.json
   dartograph bridges --format json -- demo > dart.json
   isthmus retentions dart.json swift.json --for cartograph > retentions.json
   ```
7. `cartograph dead --project demo/ios --external-retentions retentions.json`
   Expected: no findings. `cartograph dead --explain CameraPlugin` says the handler is retained
   because `dart lib/main.dart:<line> invokes 'takePhoto' on channel 'demo/camera'`.
8. Install the skill (`cartograph skill`) and repeat step 4. Expected: the agent runs `query`,
   sees `reason: externalBridge`, and does not delete.
9. `isthmus check --strict` in CI turns a deleted handler into a failing build with both file
   locations in the message.

## Files

- `lib/main.dart` — one button, one channel, one method.
- `ios/Runner/CameraPlugin.swift` — the handler in the standard `FlutterPlugin` shape.
- `ios/Runner/AppDelegate.swift` — registration.
