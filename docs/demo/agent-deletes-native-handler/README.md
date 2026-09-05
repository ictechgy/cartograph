# Demo: an agent deletes a native handler that only Dart calls

Status: **draft, not yet executed end to end.** The authoring environment had no Flutter SDK, so
the app has not been built or run. Anyone with a Flutter toolchain can finish it by following
"Reproduce" and correcting whatever does not match.

## What the failure is, precisely

`lib/main.dart` calls `MethodChannel('demo/camera').invokeMethod('takePhoto')`.
`ios/Runner/CameraPlugin.swift` answers in `switch call.method { case "takePhoto": takePhoto(result) }`.

No Swift code mentions `"takePhoto"` except that `case`. An agent asked to remove unused code
works from text search and its own reading: `takePhoto(_:)` is called from one `case` whose string
nothing in Swift produces, so the arm and the helper look like leftovers. It deletes them. The build
stays green. The first tap on the button throws `MissingPluginException` at runtime.

Be precise about what `cartograph` alone says here, because the naive framing ("cartograph reports
the handler as dead") is wrong for this shape. `handle(_:result:)` implements a requirement of the
external `FlutterPlugin` protocol, so `cartograph dead` keeps it (reason `externalConformance`),
and `takePhoto(_:)` is reachable from it. `cartograph dead` reports **nothing**, before and after
the agent's deletion. That is the point: no single-language tool can see that Dart is the caller of
`"takePhoto"`. The string is the only link, and only the cross-language join sees it.

(`cartograph dead` does report the whole class when a plugin is analysed as its own package with
no app entry point — the plus_plugins repositories are that case — and `--external-retentions`
exists for that. This demo is the app-side case.)

## Reproduce

1. `flutter create demo`, then copy this directory's `lib/main.dart` over `demo/lib/main.dart` and
   `ios/Runner/CameraPlugin.swift`, `ios/Runner/AppDelegate.swift` into `demo/ios/Runner/`.
   Add `CameraPlugin.swift` to the Runner target in Xcode unless the project uses synchronized
   folders (Flutter templates created with Xcode 16 do; older ones need the file added by hand).
2. `cd demo && flutter pub get && flutter build ios --simulator --debug` so the compiler writes an
   index store under `ios/DerivedData` or the default DerivedData.
3. `cartograph dead --project demo/ios --index-store <DerivedData>/Index.noindex/DataStore`.
   Expected: no findings that mention `CameraPlugin`. `cartograph dead --explain 'handle(_:result:)'`
   should say it satisfies a protocol declared outside the analysed code.
4. In a fresh agent session with no skill installed: "Remove unused code in `ios/Runner`." Expected:
   it removes the `case "takePhoto"` arm and `takePhoto(_:)`, or the whole class and its
   registration line. `flutter build ios` passes either way.
5. Run on a simulator and tap the button. Expected: an unhandled `MissingPluginException(No
   implementation found for method takePhoto on channel demo/camera)` in the debug console; the app
   itself keeps running because Flutter catches uncaught async errors, so look at the console, not
   for a crash dialog.

## The guard this demonstrates

6. Produce the two fact files and join them:
   ```bash
   cartograph bridges --project demo/ios --format json --target flutter > swift.json
   dartograph bridges --format json -- demo > dart.json
   isthmus check --strict dart.json swift.json
   ```
   Expected before the deletion: exit 0. After it: exit 1, naming `lib/main.dart:<line>` as a
   `method-invoke` of `takePhoto` on `demo/camera` with no matching `method-handle`.
7. Install the skill (`cartograph skill`) and repeat step 4. Expected: the agent runs `cartograph
   query takePhoto(_:)` first, sees it reachable from `handle(_:result:)`, and reads the
   `limitations` line about the Flutter boundary before deciding. Whether it then stops is the
   experiment, not the assumption.

## Files

- `lib/main.dart` — one button, one channel, one method. The exception is not caught on purpose.
- `ios/Runner/CameraPlugin.swift` — the handler in the standard `FlutterPlugin` shape, with the
  helper the agent is likely to delete.
- `ios/Runner/AppDelegate.swift` — registration.
