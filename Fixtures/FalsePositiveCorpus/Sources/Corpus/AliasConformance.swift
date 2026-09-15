import SwiftUI

// Kingfisher.KFCrossPlatformViewRepresentable의 macOS 준수 절에서 재현했다.
// 실제로 쓰는 별칭과 참조 없는 별칭이 함께 있어야 무조건 보존하는 수정을 막는다.
typealias LivePlatformViewAlias = NSViewRepresentable
typealias UnusedPlatformViewAlias = NSViewRepresentable

struct AliasedPlatformView: LivePlatformViewAlias {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 외부 프로토콜이 별칭으로 쓰인 타입도 진입점에서 도달하게 한다.
public func exerciseAliasedConformance() {
    _ = AliasedPlatformView()
}
