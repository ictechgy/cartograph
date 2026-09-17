import Foundation

/// Dart 쪽에서 호출되는 호스트 API. 구현은 메시지 핸들러를 통해서만 도달한다.
public protocol CameraApi {
    func takePhoto(completion: @escaping (String) -> Void)
    func switchCamera(completion: @escaping (Bool) -> Void)
}

public final class DefaultCameraApi: CameraApi {
    private var sessionLog: [String] = []

    public init() {}

    public func takePhoto(completion: @escaping (String) -> Void) {
        prepareSensor()
        completion("shot-\(sessionLog.count)")
    }

    public func switchCamera(completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    private func prepareSensor() {
        sessionLog.append("warm")
    }
}

/// 메시지당 실행되는 감사 기록. 핸들러 본문에서만 호출한다.
func audit(_ event: String) -> String {
    "audit:\(event)"
}
