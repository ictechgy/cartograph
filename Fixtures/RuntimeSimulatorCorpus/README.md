# iOS Simulator runtime collection corpus

This dependency-free UIKit app is compiled directly with `swiftc`, without a fixture Xcode project.
It exercises a dynamically assembled Objective-C class/selector name and a real selector call.
The scene manifest supports current UIKit scene lifecycle requirements.

`Scripts/verify-runtime-simulator.py --cartograph <debug-binary> --simulator <booted-test-device-UUID>`
builds and installs only this test app. Use a dedicated simulator. It checks the original return value,
exact compiler identities, explicit exit 0/7, a crash, `_exit(0)`, timeout, a mismatched installed binary,
and refusal to replace a running debug session. It does not run a user's app or alter signing settings.

The crash case comes from real validation: `simctl launch --console` can return 0 after UIKit aborts.
The collector must independently record an explicit application exit code and completed event log.
An interactive app killed by SpringBoard is a partial trace, even when it contains useful events.
