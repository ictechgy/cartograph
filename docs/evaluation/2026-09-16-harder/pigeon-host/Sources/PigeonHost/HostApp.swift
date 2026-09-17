import Foundation

/// 등록부를 호출해 그래프가 모두 도달 가능하도록 한다.
public enum HostApp {
    public static func start() {
        CameraApiSetup.setUp(messenger: Messenger(), api: DefaultCameraApi())
    }
}
