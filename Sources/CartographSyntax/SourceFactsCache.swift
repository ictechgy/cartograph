import CartographCore
import Foundation

/// 구문 분석 결과를 파일 내용 기준으로 재사용하는 캐시.
///
/// 실측에서 `dead` 실행 시간의 대부분이 SwiftSyntax 재파싱이었다. 인덱스 수집은
/// 이미 증분이고 그래프·도달성은 값싼데, 매 실행마다 소스 전부를 다시 파싱했다.
///
/// 파싱 결과는 파일 내용만의 순수 함수다. 그래서 내용 해시를 키로 쓰면 안전하다.
/// 수정 시각이 아니라 내용을 쓰는 이유는, 체크아웃이나 파일 복사로 시각만 바뀌는
/// 경우와 시각이 그대로인 채 내용이 바뀌는 경우를 모두 피하기 위해서다. 파일은
/// 어차피 읽어야 하므로 해시 비용만 더해진다.
public struct SourceFactsCache: Sendable {
    /// 캐시 항목 하나.
    public struct Entry: Codable, Sendable, Equatable {
        public let fingerprint: String
        public let facts: SourceFileFacts

        public init(fingerprint: String, facts: SourceFileFacts) {
            self.fingerprint = fingerprint
            self.facts = facts
        }
    }

    /// 디스크에 저장하는 문서.
    struct Document: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// 캐시 형식이나 분석기 동작이 바뀌면 예전 항목을 통째로 버려야 한다.
    /// 버전을 올리는 것을 잊으면 낡은 결과로 조용히 틀린 분석을 하게 된다.
    static let schemaVersion = 1

    private let fileSystem: any FileSystem
    private let path: String
    /// 분석기 설정이 결과를 바꾸므로 지문에 함께 넣는다.
    private let analyzerIdentity: String

    public init(fileSystem: any FileSystem, path: String, analyzerIdentity: String) {
        self.fileSystem = fileSystem
        self.path = path
        self.analyzerIdentity = analyzerIdentity
    }

    /// 저장된 항목을 읽는다. 없거나 형식이 다르면 빈 값으로 시작한다.
    public func load() -> [String: Entry] {
        guard let data = try? fileSystem.readData(at: path),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Self.schemaVersion
        else { return [:] }
        return document.entries
    }

    /// 이번 실행에서 실제로 본 항목만 저장한다.
    ///
    /// 통째로 덮어쓰므로 지워진 파일의 항목이 남아 무한히 자라지 않는다.
    /// 저장에 실패해도 분석 결과에는 영향이 없으므로 조용히 넘어간다.
    public func save(_ entries: [String: Entry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Document(version: Self.schemaVersion, entries: entries))
        else { return }
        try? fileSystem.write(data, to: path)
    }

    /// 소스 내용과 분석기 설정을 함께 담은 지문.
    ///
    /// 길이를 함께 넣는다. 해시가 우연히 부딪혀도 길이가 다르면 걸러지므로 값싼
    /// 한 줄로 우연 충돌이 사실상 사라진다. 잘못 적중하면 바뀐 파일에 대해 예전
    /// 결과를 조용히 내놓게 되고, 그것은 검출할 방법이 없다.
    public func fingerprint(of source: String) -> String {
        "\(source.utf8.count):\(Self.stableHash(source)):\(Self.stableHash(analyzerIdentity))"
    }

    /// 분석 결과를 바꾸는 입력들을 하나의 문자열로 모은다.
    ///
    /// 도구 버전과 분석기 개정 번호가 특히 중요하다. 이것이 없으면 업그레이드해도
    /// 손대지 않은 파일에는 수정이 적용되지 않아, 고친 오탐이 그대로 되살아난다.
    public static func analyzerIdentity(
        toolVersion: String,
        analysisRevision: Int,
        externalTestCaseClasses: [String]
    ) -> String {
        // 구분자는 이름 안에 나올 수 없는 것으로 둔다. 쉼표로 이으면
        // `["A,B"]` 와 `["A", "B"]` 가 같은 지문이 된다.
        ([toolVersion, String(analysisRevision)] + externalTestCaseClasses.sorted())
            .joined(separator: "\u{0}")
    }

    /// 프로젝트마다 하나씩 두는 기본 캐시 경로.
    ///
    /// 저장소 안이 아니라 임시 디렉터리에 둔다. 분석 산출물이 저장소를 더럽히면
    /// `.gitignore` 관리가 사용자 부담이 되고, 지워도 결과가 달라지지 않는 캐시를
    /// 커밋할 위험도 생긴다.
    public static func defaultPath(forProject projectPath: String) -> String {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cartograph-syntax-cache")
        return (directory as NSString).appendingPathComponent(stableHash(projectPath) + ".json")
    }

    /// 실행마다 같은 값을 주는 해시(FNV-1a 64비트).
    ///
    /// Swift 의 `Hasher` 는 실행마다 시드가 달라 캐시 키로 쓸 수 없다.
    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
