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
            takePhoto(result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// The only caller is the `case` above, and the only caller of that is Dart.
    private func takePhoto(_ result: FlutterResult) {
        result("/tmp/photo.jpg")
    }
}
