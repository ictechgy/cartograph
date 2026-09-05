import Foundation

/// 언어 경계. Flutter 가 부르는 핸들러는 Swift 코드 어디에서도 참조되지 않는다.
///
/// Flutter 프레임워크 없이 스캐너가 보는 형태만 재현한 스텁이다. 스캐너는 타입 이름과
/// 메서드 이름만 보므로, 실제 Flutter 와 같은 이름이면 같은 사실이 나온다.
public final class FlutterMethodChannel {
    public init(name: String, binaryMessenger: Any) {}
    public func setMethodCallHandler(_ handler: ((FlutterMethodCall, (Any?) -> Void) -> Void)?) {}
}

public struct FlutterMethodCall {
    public let method: String
}

/// Dart 가 `invokeMethod('takePhoto')` 로 부르는 핸들러. 인덱스만 보면 죽은 코드다.
///
/// isthmus 가 돌려주는 `external-retentions.json` 이 `init(messenger:)` 를 가리키고,
/// `verify-fixtures.sh` 가 그 파일을 걸었을 때 이 타입이 보고에서 빠지는지 확인한다.
public final class CameraBridge {
    static let channelName = "com.example/camera"
    let channel: FlutterMethodChannel

    public init(messenger: Any) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "takePhoto":
                self?.takePhoto()
                result(nil)
            default:
                result(nil)
            }
        }
    }

    func takePhoto() {}
}

/// FlutterPlugin 표준 형태. 스캔한 공개 플러그인(plus_plugins, mobile_scanner)이 전부 이 모양이다.
///
/// `registrar.addMethodCallDelegate(instance, channel:)` 이 어느 타입의 `handle(_:result:)` 가
/// 채널을 받는지 말해 준다. 추측이 아니라 등록 호출의 사실이고, `handle` 의 USR 이 실제
/// 인덱스에서 붙는지는 여기서만 검증된다.
public protocol FlutterPluginRegistrar: AnyObject {
    func messenger() -> Any
    func addMethodCallDelegate(_ delegate: AnyObject, channel: FlutterMethodChannel)
}

public final class PhotoPlugin: NSObject {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.example/photo", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(PhotoPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: (Any?) -> Void) {
        switch call.method {
        case "pick": result("photo")
        default: result(nil)
        }
    }
}

/// 핸들러를 클로저가 아니라 메서드 참조로 다는 형태(audioplayers).
public final class AudioBridge {
    let channel: FlutterMethodChannel

    public init(messenger: Any) {
        channel = FlutterMethodChannel(name: "com.example/audio", binaryMessenger: messenger)
        channel.setMethodCallHandler(handleCall)
    }

    func handleCall(_ call: FlutterMethodCall, result: (Any?) -> Void) {
        let method = call.method
        if method == "play" { result(nil) }
    }
}
