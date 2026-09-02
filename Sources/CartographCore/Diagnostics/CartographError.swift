import Foundation

/// 도구 실행 중 사용자에게 그대로 보여 줄 수 있는 오류.
///
/// 오류 메시지에는 원인과 다음 행동을 함께 담는다. 사용자는 대개
/// "인덱스 스토어를 못 찾았다"보다 "어떻게 만들면 되는지"를 알고 싶어 한다.
public enum CartographError: Error, Equatable, LocalizedError {
    /// 인덱스 스토어 경로를 찾지 못함.
    case indexStoreNotFound(searchedPaths: [String])
    /// 인덱스 스토어를 열지 못함.
    case indexStoreUnreadable(path: String, underlying: String)
    /// libIndexStore 동적 라이브러리를 찾지 못함.
    case indexStoreLibraryNotFound(searchedPaths: [String])
    /// 설정 파일 해석 실패.
    case invalidConfiguration(path: String, reason: String)
    /// 베이스라인 파일 해석 실패.
    case invalidBaseline(path: String, reason: String)
    /// 설정에서 참조한 레이어 이름이 정의되지 않음.
    case unknownLayer(name: String, definedLayers: [String])
    /// 분석 결과 문제가 발견되어 실패로 종료(`--strict`).
    case thresholdExceeded(rule: String, message: String)
    /// 결과를 파일로 쓰지 못함.
    case outputUnwritable(path: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case let .indexStoreNotFound(searchedPaths):
            return """
                Could not find an index store. Searched:
                \(searchedPaths.map { "  - \($0)" }.joined(separator: "\n"))
                Build first so the compiler writes an index store:
                  swift build
                  xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
                Then run again, or pass --index-store <path> to point at it directly.
                Note: with SwiftPM's Xcode-based build system, -Xswiftc -index-store-path is
                ignored; the store goes to <scratch path>/out.
                """
        case let .indexStoreUnreadable(path, underlying):
            return """
                Failed to open the index store at \(path): \(underlying)
                The store may have been written by a different toolchain, or a build may be \
                writing to it right now. Rebuild the index and try again.
                """
        case let .indexStoreLibraryNotFound(searchedPaths):
            return """
                Could not locate libIndexStore.dylib. Searched:
                \(searchedPaths.map { "  - \($0)" }.joined(separator: "\n"))
                Make sure Xcode or a Swift toolchain is installed and `xcode-select -p` points at it.
                """
        case let .invalidConfiguration(path, reason):
            return "Invalid configuration at \(path): \(reason)"
        case let .invalidBaseline(path, reason):
            return "Invalid baseline at \(path): \(reason)"
        case let .unknownLayer(name, definedLayers):
            return """
                Rule refers to undefined layer '\(name)'. Defined layers: \
                \(definedLayers.isEmpty ? "(none)" : definedLayers.joined(separator: ", "))
                """
        case let .thresholdExceeded(rule, message):
            return "Threshold exceeded for '\(rule)': \(message)"
        case let .outputUnwritable(path, underlying):
            return "Could not write to \(path): \(underlying)"
        }
    }
}
