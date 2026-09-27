import CartographCore

/// `routes` 명령이 내보내는 문서. bridge-facts v1 교환 형식의 `target: "http"` 호출 측 문서다.
///
/// isthmus 가 서버 선언·스펙과 (동사, 정규 경로 템플릿)으로 조인한다. 호출이 0건이어도
/// `target` 은 `http` 로 남는다 — roles 가 있는 http 문서는 사실이 없어도 "스캔했으나 없음"이고,
/// `null` 이면 "스캔 안 함"과 구분할 수 없다. 키는 정렬해 두 실행의 출력을 diff 할 수 있게 한다.
public struct RouteCallsDocument: Sendable, Equatable, Encodable {
    /// 교환 형식의 route-call 사실. `RouteCallFact` 를 계약 필드 이름으로 옮긴 것이다.
    public struct Fact: Sendable, Equatable, Encodable {
        public let channel: String?
        public let method: String?
        public let methodDynamic: Bool?
        public let dynamic: Bool
        public let pathAnchor: HTTPPathAnchor
        public let authority: String?
        public let service: String?
        public let channelPrefix: String?
        public let queryTailStripped: Bool?
        public let maskedSegments: Int?
        public let testSource: Bool?
        public let location: SourceLocation
        public let symbol: BridgeFactsDocument.Fact.Symbol?

        private enum CodingKeys: String, CodingKey {
            case kind, channel, method, methodDynamic, dynamic, pathAnchor, authority, service, channelPrefix
            case queryTailStripped, maskedSegments, testSource, location, symbol
        }

        init(_ fact: RouteCallFact, baseVariants: [String], documentService: String?) {
            channel = fact.channel
            method = fact.method
            methodDynamic = fact.method == nil ? true : nil
            dynamic = fact.isDynamic
            pathAnchor = fact.pathAnchor
            authority = fact.authority
            // 문서 값과 같으면 사실에서 뺀다. 유효 service 는 같고 파일이 짧아진다.
            service = fact.service == documentService ? nil : fact.service
            channelPrefix = fact.isDynamic ? fact.channelPrefix : nil
            queryTailStripped = fact.queryTailStripped && !fact.isDynamic ? true : nil
            maskedSegments = fact.maskedSegments > 0 ? fact.maskedSegments : nil
            testSource = fact.isTestSource ? true : nil
            location = fact.location.relative(toBaseVariants: baseVariants)
            symbol = fact.symbol.map { .init(qualifiedName: $0.qualifiedName, usr: $0.usr) }
        }

        /// 존재 자체가 증거인 표식은 `true` 일 때만 싣는다. `channel` 은 null 도 정보라 항상 싣는다.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("route-call", forKey: .kind)
            try container.encode(channel, forKey: .channel)
            try container.encodeIfPresent(method, forKey: .method)
            try container.encodeIfPresent(methodDynamic, forKey: .methodDynamic)
            try container.encode(dynamic, forKey: .dynamic)
            try container.encode(pathAnchor, forKey: .pathAnchor)
            try container.encodeIfPresent(authority, forKey: .authority)
            try container.encodeIfPresent(service, forKey: .service)
            try container.encodeIfPresent(channelPrefix, forKey: .channelPrefix)
            try container.encodeIfPresent(queryTailStripped, forKey: .queryTailStripped)
            try container.encodeIfPresent(maskedSegments, forKey: .maskedSegments)
            try container.encodeIfPresent(testSource, forKey: .testSource)
            try container.encode(location, forKey: .location)
            try container.encodeIfPresent(symbol, forKey: .symbol)
        }
    }

    /// 테스트 소스를 스캔했는지 선언한다. 소비자는 테스트 사실을 error 근거에서 뺀다.
    public struct SourceSets: Sendable, Equatable, Encodable {
        public let tests: String
    }

    public let format = BridgeFactsDocument.format
    public let version = BridgeFactsDocument.version
    public let tool: BridgeFactsDocument.Tool
    public let generatedAt: String
    public let platform = "swift"
    public let target = "http"
    public let project: String
    /// 이 문서가 호출 측이라는 선언. route-call 은 client 역할 문서에만 올 수 있다.
    public let roles = ["client"]
    public let sourceSets: SourceSets
    public let service: String?
    public let facts: [Fact]
    public let limitations: [String]

    private enum CodingKeys: String, CodingKey {
        case format, version, tool, generatedAt, platform, target, project, roles, sourceSets, service, facts, limitations
    }

    public init(
        tool: BridgeFactsDocument.Tool, generatedAt: String, project: String, facts: [RouteCallFact],
        includesTests: Bool, service: String?, limitations: [String]
    ) {
        self.tool = tool
        self.generatedAt = generatedAt
        self.project = project
        sourceSets = SourceSets(tests: includesTests ? "included" : "excluded")
        self.service = service
        let baseVariants = PathFilter.variants(of: project)
        self.facts = facts.sorted().map { Fact($0, baseVariants: baseVariants, documentService: service) }
        self.limitations = limitations
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(tool, forKey: .tool)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(platform, forKey: .platform)
        try container.encode(target, forKey: .target)
        try container.encode(project, forKey: .project)
        try container.encode(roles, forKey: .roles)
        try container.encode(sourceSets, forKey: .sourceSets)
        try container.encodeIfPresent(service, forKey: .service)
        try container.encode(facts, forKey: .facts)
        try container.encode(limitations, forKey: .limitations)
    }

    /// 사람이 훑어볼 한 줄 요약. 디버깅용이고 계약의 일부가 아니다.
    public func renderText() -> String {
        var lines = facts.map { fact in
            var line = "\(fact.location)  \(fact.method ?? "?") \(fact.channel ?? "-")  (\(fact.pathAnchor.rawValue))"
            if fact.dynamic { line += "  (dynamic)" }
            if let symbol = fact.symbol { line += "  \(symbol.usr ?? symbol.qualifiedName)" }
            return line
        }
        lines.append("")
        lines.append("\(facts.count) route call(s) · target http")
        lines += limitations.map { "  limitation: " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }
}
