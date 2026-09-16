import Foundation

/// Flutter SDK 없이 컴파일되는 최소 스텁. 스캐너는 타입이 아니라 이름으로 묶으므로
/// 실제 Pigeon 산출물과 같은 형태만 갖추면 된다.
public protocol FlutterBinaryMessenger {}

public final class FlutterStandardMessageCodec {
    public static let sharedInstance = FlutterStandardMessageCodec()
}

public final class FlutterBasicMessageChannel<Arguments> {
    public typealias Reply = (Any?) -> Void
    public typealias MessageHandler = (Arguments?, @escaping Reply) -> Void

    public let name: String
    public let binaryMessenger: FlutterBinaryMessenger

    public init(
        name: String,
        binaryMessenger: FlutterBinaryMessenger,
        codec: FlutterStandardMessageCodec = .sharedInstance
    ) {
        self.name = name
        self.binaryMessenger = binaryMessenger
    }

    public func setMessageHandler(_ handler: MessageHandler?) {}
}

public final class Messenger: FlutterBinaryMessenger {}
