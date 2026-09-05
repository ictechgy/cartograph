import Flutter

/// Nothing in Swift calls this class. Dart does, through the string "demo/camera".
public final class CameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "demo/camera", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(CameraPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "takePhoto":
            result("/tmp/photo.jpg")
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
