import CartographCore
import CartographSyntax
import Foundation

/// `bridges` 명령이 내보내는 문서. isthmus 가 읽는 교환 형식(버전 1)이다.
///
/// 이 문서는 Swift 에서 본 사실만 담는다. "이 핸들러를 Dart 가 실제로 부른다"는 판정은
/// 다른 언어의 사실과 조인해야 나오고, 그것은 isthmus 의 몫이다. 리터럴이 아닌 이름도
/// `dynamic: true` 로 남긴다. 버리면 isthmus 가 조인하지 못한 수를 셀 수 없다.
///
/// 키 순서는 정렬한다. 두 실행의 출력을 diff 할 수 있어야 한다.
public struct BridgeFactsDocument: Sendable, Equatable, Codable {
    /// 교환 형식 이름. isthmus 가 파일을 열었을 때 첫 줄에서 무엇인지 알아야 한다.
    public static let format = "bridge-facts"
    /// 교환 형식 버전. `GRAPH-EXCHANGE.md` 가 바뀌면 함께 올린다.
    ///
    /// 1 은 isthmus Phase 0 에서 Dart ↔ Swift 코퍼스를 양방향 조인해 확정한 판이다.
    public static let version = 1

    public struct Tool: Sendable, Equatable, Codable {
        public let name: String
        public let version: String
    }

    /// 교환 형식의 Fact. `BridgeFact` 를 계약에 맞는 모양으로 옮긴 것이다.
    public struct Fact: Sendable, Equatable, Codable {
        public struct Symbol: Sendable, Equatable, Codable {
            public let qualifiedName: String
            public let usr: String?
        }

        public let kind: String
        /// 채널 또는 모듈 이름. 없으면 null. 리터럴이 아니면 원문 표현식.
        public let channel: String?
        public let method: String?
        public let dynamic: Bool
        public let location: SourceLocation
        public let symbol: Symbol?

        private enum CodingKeys: String, CodingKey {
            case kind, channel, method, dynamic, location, symbol
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            channel = try container.decodeIfPresent(String.self, forKey: .channel)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            dynamic = try container.decode(Bool.self, forKey: .dynamic)
            location = try container.decode(SourceLocation.self, forKey: .location)
            symbol = try container.decodeIfPresent(Symbol.self, forKey: .symbol)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            // 채널이 없는 것은 정보다. 키를 빼면 소비자가 "빠졌다"와 "몰랐다"를 못 가른다.
            // 계약이 `null` 을 명시하므로 그대로 쓴다. 나머지 선택 필드는 계약대로 뺀다.
            try container.encode(channel, forKey: .channel)
            try container.encodeIfPresent(method, forKey: .method)
            try container.encode(dynamic, forKey: .dynamic)
            try container.encode(location, forKey: .location)
            try container.encodeIfPresent(symbol, forKey: .symbol)
        }

        init(_ fact: BridgeFact, relativeTo projectPath: String) {
            kind = fact.kind.rawValue
            channel = fact.channel
            method = fact.method
            dynamic = fact.isDynamic
            location = fact.location.relative(to: projectPath)
            symbol = fact.symbol.map { Symbol(qualifiedName: $0.qualifiedName, usr: $0.usr) }
        }
    }

    public let format: String
    public let version: Int
    public let tool: Tool
    /// 신선도 판단용. 인덱스 시각이 아니라 이 문서를 만든 시각이다.
    public let generatedAt: String
    public let platform: String
    /// 브리지 메커니즘. 사실이 하나도 없으면 null.
    ///
    /// 계약은 문서당 하나를 요구한다. Swift 프로젝트가 Flutter 와 RN 을 함께 품는 일은
    /// 드물지만 불가능하지 않아, 그때는 다수를 적고 `limitations` 에 알린다.
    public let target: String?
    public let project: String
    public let facts: [Fact]
    /// 이 문서가 보지 못한 것. 매번 붙는 경보가 아니라 실제로 센 값이다.
    public let limitations: [String]

    private enum CodingKeys: String, CodingKey {
        case format, version, tool, generatedAt, platform, target, project, facts, limitations
    }

    public init(
        tool: Tool,
        generatedAt: String,
        project: String,
        facts: [BridgeFact],
        unscannedEventChannels: Int = 0,
        unscannedMessageChannels: Int = 0,
        objectiveCSourceCount: Int = 0,
        extraLimitations: [String] = []
    ) {
        format = Self.format
        version = Self.version
        self.tool = tool
        self.generatedAt = generatedAt
        platform = "swift"
        self.project = project
        self.facts = facts.sorted().map { Fact($0, relativeTo: project) }

        let targets = Self.countByTarget(facts)
        target = Self.dominantTarget(targets)
        limitations = Self.limitations(
            for: facts, targets: targets,
            unscannedEventChannels: unscannedEventChannels, unscannedMessageChannels: unscannedMessageChannels,
            objectiveCSourceCount: objectiveCSourceCount
        ) + extraLimitations
    }

    /// `target` 이 없으면 키를 빼지 않고 `null` 로 적는다. 계약이 그렇게 정했다.
    ///
    /// 합성 Encodable 은 옵셔널을 `encodeIfPresent` 로 내 키를 지운다. `Fact.channel` 에는
    /// 같은 이유로 손으로 쓴 인코더가 있는데 문서 레벨을 놓쳤었다.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(tool, forKey: .tool)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(platform, forKey: .platform)
        try container.encode(target, forKey: .target)
        try container.encode(project, forKey: .project)
        try container.encode(facts, forKey: .facts)
        try container.encode(limitations, forKey: .limitations)
    }

    private static func countByTarget(_ facts: [BridgeFact]) -> [BridgeFact.Target: Int] {
        facts.reduce(into: [:]) { $0[$1.target, default: 0] += 1 }
    }

    private static func dominantTarget(_ counts: [BridgeFact.Target: Int]) -> String? {
        // 동수면 이름 순으로 고정한다. 실행마다 답이 달라지면 안 된다.
        // `max` 는 비교자가 참인 쪽을 "작다"고 보므로, 이름이 앞서는 쪽을 "크다"고 답해야
        // 동수에서 `flutter` 가 이긴다.
        counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }?.key.rawValue
    }

    /// 사실 목록에서 실제로 센 한계.
    static func limitations(
        for facts: [BridgeFact],
        targets: [BridgeFact.Target: Int],
        unscannedEventChannels: Int = 0,
        unscannedMessageChannels: Int = 0,
        objectiveCSourceCount: Int = 0
    ) -> [String] {
        var result: [String] = []
        // 키 이름은 계약의 예시(`dynamic-channel-names`, `missing-handler-usrs`)를 따른다.
        // isthmus 가 파싱한다면 같은 이름이어야 한다.
        let dynamicChannels = facts.count { $0.kind == .channelRegister && $0.isDynamic }
        if dynamicChannels > 0 {
            result.append("dynamic-channel-names: \(dynamicChannels) channel constructors use a non-literal name")
        }
        let dynamicMethods = facts.count { $0.kind == .methodHandle && $0.isDynamic }
        if dynamicMethods > 0 {
            result.append(
                "dynamic-method-names: \(dynamicMethods) method handlers branch on a non-literal name, "
                    + "so they cannot be joined and are listed with their source expression"
            )
        }
        let unattributed = facts.count { $0.kind == .methodHandle && $0.channel == nil }
        if unattributed > 0 {
            result.append(
                "unattributed-method-handles: \(unattributed) method handlers have no channel because they "
                    + "sit outside a handler closure and their file does not construct exactly one channel"
            )
        }
        let inferred = facts.count(where: \.isChannelInferred)
        if inferred > 0 {
            result.append(
                "inferred-channels: \(inferred) method handlers were attributed to the only channel in "
                    + "their file rather than to an enclosing handler, so the channel is a guess"
            )
        }
        let missingUSRs = facts.count { $0.kind == .methodHandle && $0.symbol != nil && $0.symbol?.usr == nil }
        if missingUSRs > 0 {
            result.append("missing-handler-usrs: \(missingUSRs) method handlers have only a qualified name")
        }
        let swiftReactModules = facts.count {
            $0.kind == .moduleExport && $0.target == .reactNative && $0.location.path.hasSuffix(".swift")
        }
        let swiftReactMethods = facts.count {
            $0.kind == .methodHandle && $0.target == .reactNative && $0.location.path.hasSuffix(".swift")
        }
        if swiftReactModules > 0 {
            result.append(
                "objc-named-classes: \(swiftReactModules) module-export and \(swiftReactMethods) method-handle "
                    + "fact(s) come from @objc(Name) classes, which may name an Objective-C class rather than "
                    + "a React Native module"
            )
        }
        let objectiveCHandlers = facts.count { $0.kind == .methodHandle && !$0.location.path.hasSuffix(".swift") }
        if objectiveCHandlers > 0 {
            result.append(
                "objective-c-handlers: \(objectiveCHandlers) method handlers come from Objective-C sources and "
                    + "carry no USR, so a retention for them cannot be applied by --external-retentions"
            )
        }
        if unscannedEventChannels > 0 {
            result.append(
                "unscanned-event-channels: \(unscannedEventChannels) FlutterEventChannel constructor(s) are not "
                    + "read; stream handlers are outside this format"
            )
        }
        if unscannedMessageChannels > 0 {
            result.append(
                "unscanned-message-channels: \(unscannedMessageChannels) BasicMessageChannel constructor(s) are not "
                    + "read; Pigeon-generated bridges are outside this format"
            )
        }
        // Flutter 핸들러가 Objective-C 로 쓰인 플러그인(package_info_plus, share_plus)은 여기 아무
        // 사실도 없다. 이것을 세지 않으면 isthmus 는 "핸들러 없는 호출" 을 오류로 낸다.
        if objectiveCSourceCount > 0 {
            result.append(
                "objective-c-sources: \(objectiveCSourceCount) Objective-C file(s) were read only for React Native "
                    + "export macros, so a Flutter handler written in Objective-C is not here"
            )
        }
        if targets.count > 1 {
            let breakdown = targets.keys.sorted { $0.rawValue < $1.rawValue }
                .map { "\($0.rawValue) \(targets[$0] ?? 0)" }.joined(separator: ", ")
            let isTie = Set(targets.values).count == 1
            result.append(
                "mixed-targets: facts come from more than one bridge (\(breakdown)); 'target' is "
                    + (isTie ? "the first alphabetically because the counts tie" : "the majority")
            )
        }
        return result
    }
}

extension BridgeFactsDocument {
    /// 사람이 훑어볼 한 줄 요약. 디버깅용이고 계약의 일부가 아니다.
    public func renderText() -> String {
        var lines = facts.map { fact in
            var line = "\(fact.location)  \(fact.kind)"
            line += "  channel=\(fact.channel ?? "-")"
            if let method = fact.method { line += "  method=\(method)" }
            if fact.dynamic { line += "  (dynamic)" }
            if let symbol = fact.symbol { line += "  \(symbol.usr ?? symbol.qualifiedName)" }
            return line
        }
        lines.append("")
        lines.append("\(facts.count) bridge fact(s) · target \(target ?? "none")")
        lines += limitations.map { "  limitation: " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 구문에서 찾은 사실에 인덱스의 USR 을 붙인다.
///
/// 스캐너는 선언의 이름과 줄만 안다. 인덱스 스냅샷에서 같은 파일·같은 이름·가장 가까운
/// 줄의 심볼을 찾으면 그것이 USR 이다. isthmus 가 돌려주는 보존 근거는 이 USR 로
/// 돌아오므로, 여기서 못 찾으면 그 사실은 `dead` 에 영향을 주지 못한다.
///
/// `qualifiedName` 은 인덱스에서 찾았든 아니든 구문의 표기(`CameraPlugin.register`)다.
/// 계약이 그 표기를 쓰고, 자매 도구도 같은 모양을 낸다. 인덱스의 표기(`Module.name(labels)`)는
/// USR 이 있으면 필요 없고, 없을 때 섞이면 소비자가 두 표기를 맞출 수 없다.
struct BridgeSymbolResolver {
    /// 정규화한 경로 → 그 파일의 인덱스 심볼. 스냅샷 하나에 한 번만 만든다.
    ///
    /// 파일마다 다시 묶으면 파일 수 × 심볼 수다. 디스크 걷기 경로와 인덱스 경로는
    /// `/private/tmp` 와 `/tmp` 처럼 표기가 다를 수 있어 실제 경로로 맞춘다. 표기가 다르면
    /// 파일 하나의 USR 이 통째로 빠진다.
    private let symbolsByPath: [String: [IndexedSymbol]]

    init(snapshot: IndexSnapshot) {
        symbolsByPath = Dictionary(grouping: snapshot.symbols) { Self.canonical($0.location.path) }
    }

    func resolve(_ scanned: [ScannedBridgeFact]) -> [BridgeFact] {
        scanned.map { entry in
            guard let declaration = entry.declaration else { return entry.fact }
            let candidates = symbolsByPath[Self.canonical(entry.fact.location.path)] ?? []
            let symbol = Self.match(declaration, among: candidates)
            return entry.fact.attaching(BridgeFact.Symbol(qualifiedName: declaration.qualifiedName, usr: symbol?.usr))
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 인자 라벨까지 같은 심볼을 찾는다. 여럿이면 줄이 가장 가까운 것.
    ///
    /// 라벨 일치가 실패하면 기본 이름이 같은 심볼이 **하나뿐일 때만** 그것을 쓴다. 후보가
    /// 여럿인데 줄 거리로 고르면 `handle(_:)` 과 `handle(_:result:)` 중 엉뚱한 쪽에 USR 이
    /// 붙고, isthmus 는 그 선언을 살리고 진짜 핸들러는 죽은 코드로 보고된다.
    /// USR 이 없는 쪽이 틀린 USR 보다 안전하다. 없으면 `missing-handler-usrs` 로 세어진다.
    private static func match(_ declaration: EnclosingDeclaration, among symbols: [IndexedSymbol]) -> IndexedSymbol? {
        let labelled = symbols.filter { normalizingInitializer($0.name) == declaration.indexName }
        if let exact = nearest(declaration, among: labelled) { return exact }
        let sameBase = symbols.filter { SourceFileFacts.baseName(ofIndexName: $0.name) == declaration.name }
        return sameBase.count == 1 ? sameBase.first : nil
    }

    /// 실패 가능 이니셜라이저의 `init?(…)` 와 `init!(…)` 를 `init(…)` 으로 맞춘다. 구문 쪽 이름에는 물음표가 없다.
    private static func normalizingInitializer(_ indexName: String) -> String {
        indexName.replacingOccurrences(of: "?(", with: "(").replacingOccurrences(of: "!(", with: "(")
    }

    private static func nearest(_ declaration: EnclosingDeclaration, among symbols: [IndexedSymbol]) -> IndexedSymbol? {
        symbols.min { lhs, rhs in
            let lhsDistance = abs(lhs.location.line - declaration.line)
            let rhsDistance = abs(rhs.location.line - declaration.line)
            return lhsDistance == rhsDistance ? lhs.usr < rhs.usr : lhsDistance < rhsDistance
        }
    }
}
