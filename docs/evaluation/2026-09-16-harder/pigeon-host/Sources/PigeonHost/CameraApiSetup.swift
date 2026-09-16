import Foundation

/// Pigeon 생성 코드의 형태를 그대로 흉내낸 등록부.
public enum CameraApiSetup {
    public static func setUp(messenger: FlutterBinaryMessenger, api: CameraApi?) {
        let channel = FlutterBasicMessageChannel<Any?>(
            name: "dev.flutter.pigeon.host.CameraApi.takePhoto",
            binaryMessenger: messenger)
        if let api {
            channel.setMessageHandler { _, reply in
                _ = audit("takePhoto")
                api.takePhoto { shot in
                    reply(shot)
                }
            }
        } else {
            channel.setMessageHandler(nil)
        }

        let switchChannel = FlutterBasicMessageChannel<Any?>(
            name: "dev.flutter.pigeon.host.CameraApi.switchCamera",
            binaryMessenger: messenger)
        switchChannel.setMessageHandler { _, reply in
            api?.switchCamera { ok in
                reply(ok)
            }
        }

        // 수신자가 추적 불가한 동적 채널 — 사실이 보존되어야 한다.
        makeAuxiliaryChannel(messenger: messenger).setMessageHandler { _, reply in
            reply(nil)
        }
    }

    private static func makeAuxiliaryChannel(
        messenger: FlutterBinaryMessenger
    ) -> FlutterBasicMessageChannel<Any?> {
        FlutterBasicMessageChannel(
            name: "dev.flutter.pigeon.host.CameraApi.ping",
            binaryMessenger: messenger)
    }
}
