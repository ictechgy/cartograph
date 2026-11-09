/// 소스 파일의 `import` 선언 하나.
///
/// import는 그래프 정점이 아니다 — 파일의 모듈 의존 표시이므로 `symbols` 에 넣으면
/// 모든 질의가 잡음을 얻는다. 구문 분석이 수집해 `SnapshotEnricher` 가 스냅샷에
/// 싣는다. "파일이 이 import 없이도 같은 모듈의 선언을 참조했는가" 라는 질의의
/// 입력이며, 판정 근거는 `fileModuleUsages` 에 있다.
public struct IndexedImport: Codable, Sendable, Equatable {
    /// `import A.B.C` 의 경로 구성요소. 모듈 이름은 첫 구성요소다.
    public let modulePath: [String]
    /// `import struct A.B` 처럼 선언 종류를 좁힌 경우 그 토큰(`struct` 등). 없으면 nil.
    public let scopedKind: String?
    /// `#if` 절 안쪽의 import — 현재 인덱스가 만들어진 플랫폼에서 존재하지
    /// 않았을 수 있어 미사용 판정에서 제외한다.
    public let isConditional: Bool
    /// `@_exported` 또는 `public`/`package`/`open` 수준의 import — 클라이언트에
    /// 심볼을 다시 노출하므로 파일에 참조가 없어도 미사용으로 보고하지 않는다.
    public let isReexported: Bool
    /// 선언 줄에 `cartograph:ignore` 계열 주석이 붙은 경우.
    public let isIgnored: Bool
    /// 무시 표식이 `cartograph:ignore:all` 에서만 왔는가 — 자기 줄의
    /// `cartograph:ignore` 가 함께 있으면 거짓이다.
    ///
    /// `ignore:all` 반사실은 이 표식이 선 import 의 무시만 푼다. 자기 주석이
    /// 있는 import 는 파일 주석을 떼도 무시가 남아야 하는데, 출처를 구분하지
    /// 않으면 주석이 억제하지도 않는 보고를 떠받치는 것으로 오판한다.
    public let isIgnoredOnlyByFileComment: Bool
    /// 파일 어딘가에 `#if` 가 있으면 true. 이 import 의 사용처가 인덱스가 만들어지지 않은 빌드 구성의
    /// 분기에만 있을 수 있다.
    ///
    /// 인덱스는 한 구성만 본다. 무조건 `import Combine` 이 있고 사용처가 `#if os(iOS)` 안에만 있는 파일을
    /// macOS 인덱스로 보면 사용 흔적이 없어, 미사용으로 보고하고 `fix --apply` 가 지우면 다른 구성의 빌드가
    /// 깨진다. nil 은 `#if` 가 없거나 이 사실을 기록하지 않은 이전 문서다(키가 없어도 읽힌다).
    public let fileHasConditionalCompilation: Bool?
    /// `import` 키워드의 위치.
    public let location: SourceLocation

    public init(
        modulePath: [String],
        scopedKind: String? = nil,
        isConditional: Bool = false,
        isReexported: Bool = false,
        isIgnored: Bool = false,
        isIgnoredOnlyByFileComment: Bool = false,
        fileHasConditionalCompilation: Bool? = nil,
        location: SourceLocation
    ) {
        self.modulePath = modulePath
        self.scopedKind = scopedKind
        self.isConditional = isConditional
        self.isReexported = isReexported
        self.isIgnored = isIgnored
        self.isIgnoredOnlyByFileComment = isIgnoredOnlyByFileComment
        self.fileHasConditionalCompilation = fileHasConditionalCompilation
        self.location = location
    }

    /// `#if` 가 있는 파일의 import 로 표시한 사본.
    public func inConditionallyCompiledFile() -> IndexedImport {
        IndexedImport(
            modulePath: modulePath, scopedKind: scopedKind, isConditional: isConditional,
            isReexported: isReexported, isIgnored: isIgnored, isIgnoredOnlyByFileComment: isIgnoredOnlyByFileComment,
            fileHasConditionalCompilation: true, location: location
        )
    }

    /// 경로의 첫 구성요소 — 탑레벨 모듈 이름.
    public var module: String { modulePath.first ?? "" }

    /// 진단 메시지에 쓰는, 소스에 적힌 그대로의 표기.
    public var spelling: String {
        let path = modulePath.joined(separator: ".")
        return scopedKind.map { "\($0) \(path)" } ?? path
    }
}
