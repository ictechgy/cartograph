/// 다른 도구가 "이 선언은 언어 경계 너머에서 쓰인다"고 알려 온 보존 근거 하나.
///
/// isthmus 가 Dart·JS·Kotlin 쪽 사실과 이 도구의 `bridges` 출력을 조인한 결과다.
/// 인덱스는 언어 경계를 넘지 못한다. Dart 가 `invokeMethod('takePhoto')` 를 부른다는
/// 사실은 Swift 컴파일러가 알 수 없고, 그래서 그 핸들러는 인덱스만 보면 죽은 코드다.
/// 이 값이 그 공백을 메운다. 근거(`evidence`)를 함께 들고 있어야 `dead --explain` 이
/// "왜 살았는가"에 문장으로 답할 수 있다.
///
/// 형식은 `../isthmus/docs/GRAPH-EXCHANGE.md` 의 "외부 보존 근거" 초안 0 이다.
public struct ExternalRetention: Sendable, Equatable, Codable {
    public struct Symbol: Sendable, Equatable, Codable {
        public let usr: String?
        public let qualifiedName: String?

        public init(usr: String?, qualifiedName: String?) {
            self.usr = usr
            self.qualifiedName = qualifiedName
        }
    }

    /// 경계 너머에서 부른 쪽의 위치.
    public struct Caller: Sendable, Equatable, Codable {
        public let platform: String
        public let path: String
        public let line: Int?

        public init(platform: String, path: String, line: Int?) {
            self.platform = platform
            self.path = path
            self.line = line
        }
    }

    public struct Evidence: Sendable, Equatable, Codable {
        public let channel: String?
        public let method: String?
        public let caller: Caller?

        public init(channel: String?, method: String?, caller: Caller?) {
            self.channel = channel
            self.method = method
            self.caller = caller
        }
    }

    public let symbol: Symbol
    /// 보존 이유. 초안 0 에서는 `bridge` 하나다. 모르는 값도 버리지 않고 그대로 싣는다.
    public let reason: String
    public let evidence: Evidence?

    public init(symbol: Symbol, reason: String, evidence: Evidence?) {
        self.symbol = symbol
        self.reason = reason
        self.evidence = evidence
    }

    /// `--explain` 에 실을 근거 문장. 있는 정보만 이어 붙인다.
    ///
    /// 근거를 "외부 파일이 그렇다고 했다"로 뭉개면 사용자는 그 파일을 열어야 한다.
    /// 어느 플랫폼의 어느 줄이 어느 채널로 무엇을 불렀는지가 답이다.
    public var evidenceDescription: String {
        var parts: [String] = []
        if let caller = evidence?.caller {
            let site = caller.line.map { "\(caller.path):\($0)" } ?? caller.path
            parts.append("\(caller.platform) \(site)")
        }
        if let method = evidence?.method { parts.append("invokes '\(method)'") }
        if let channel = evidence?.channel { parts.append("on channel '\(channel)'") }
        return parts.isEmpty ? "reason '\(reason)' with no evidence attached" : parts.joined(separator: " ")
    }
}

/// `--external-retentions` 가 읽는 파일 전체.
public struct ExternalRetentionsDocument: Sendable, Equatable, Codable {
    /// 이 도구가 읽을 수 있는 형식 이름과 버전.
    public static let expectedFormat = "external-retentions"
    public static let supportedVersion = 0

    public struct Producer: Sendable, Equatable, Codable {
        public let name: String
        public let version: String?

        public init(name: String, version: String?) {
            self.name = name
            self.version = version
        }
    }

    public let format: String
    public let version: Int
    public let producedBy: Producer?
    public let generatedAt: String?
    public let retentions: [ExternalRetention]

    public init(
        format: String = ExternalRetentionsDocument.expectedFormat,
        version: Int = ExternalRetentionsDocument.supportedVersion,
        producedBy: Producer? = nil,
        generatedAt: String? = nil,
        retentions: [ExternalRetention]
    ) {
        self.format = format
        self.version = version
        self.producedBy = producedBy
        self.generatedAt = generatedAt
        self.retentions = retentions
    }

    /// 한계 목록에 적을 출처. "isthmus 0.1.0, generated 2026-…" 처럼.
    public var provenanceDescription: String {
        var text = producedBy.map { producer in
            producer.version.map { "\(producer.name) \($0)" } ?? producer.name
        } ?? "an unknown producer"
        if let generatedAt { text += ", generated \(generatedAt)" }
        return text
    }
}
