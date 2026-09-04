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

        init(_ fact: BridgeFact) {
            kind = fact.kind.rawValue
            channel = fact.channel
            method = fact.method
            dynamic = fact.isDynamic
            location = fact.location
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

    public init(
        tool: Tool,
        generatedAt: String,
        project: String,
        facts: [BridgeFact],
        unscannedEventChannels: Int = 0,
        extraLimitations: [String] = []
    ) {
        format = Self.format
        version = Self.version
        self.tool = tool
        self.generatedAt = generatedAt
        platform = "swift"
        self.project = project
        self.facts = facts.sorted().map(Fact.init)

        let targets = Self.countByTarget(facts)
        target = Self.dominantTarget(targets)
        limitations = Self.limitations(for: facts, targets: targets, unscannedEventChannels: unscannedEventChannels)
            + extraLimitations
    }

    private static func countByTarget(_ facts: [BridgeFact]) -> [BridgeFact.Target: Int] {
        facts.reduce(into: [:]) { $0[$1.target, default: 0] += 1 }
    }

    private static func dominantTarget(_ counts: [BridgeFact.Target: Int]) -> String? {
        // 동수면 이름 순으로 고정한다. 실행마다 답이 달라지면 안 된다.
        counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }?.key.rawValue
    }

    /// 사실 목록에서 실제로 센 한계.
    static func limitations(
        for facts: [BridgeFact],
        targets: [BridgeFact.Target: Int],
        unscannedEventChannels: Int = 0
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
                "unattributed-method-handles: \(unattributed) method handlers sit outside a handler "
                    + "closure in a file with several channels, so their channel is null"
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
        let objectiveCNamed = facts.count {
            $0.kind == .moduleExport && $0.target == .reactNative && $0.location.path.hasSuffix(".swift")
        }
        if objectiveCNamed > 0 {
            result.append(
                "objc-named-classes: \(objectiveCNamed) module-export fact(s) come from @objc(Name) classes, "
                    + "which may name an Objective-C class rather than a React Native module"
            )
        }
        if unscannedEventChannels > 0 {
            result.append(
                "unscanned-event-channels: \(unscannedEventChannels) FlutterEventChannel constructor(s) are not "
                    + "read; stream handlers are outside this format"
            )
        }
        if targets.count > 1 {
            let breakdown = targets.keys.sorted { $0.rawValue < $1.rawValue }
                .map { "\($0.rawValue) \(targets[$0] ?? 0)" }.joined(separator: ", ")
            result.append("mixed-targets: facts come from more than one bridge (\(breakdown)); 'target' is the majority")
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
enum BridgeSymbolResolver {
    static func resolve(_ scanned: [ScannedBridgeFact], in snapshot: IndexSnapshot) -> [BridgeFact] {
        let byPath = Dictionary(grouping: snapshot.symbols, by: \.location.path)
        return scanned.map { entry in
            guard let declaration = entry.declaration else { return entry.fact }
            let candidates = byPath[entry.fact.location.path] ?? []
            let symbol = match(declaration, among: candidates)
            return entry.fact.attaching(BridgeFact.Symbol(qualifiedName: declaration.qualifiedName, usr: symbol?.usr))
        }
    }

    /// 인자 라벨까지 같은 심볼을 먼저, 없으면 기본 이름이 같은 심볼을 찾는다. 여럿이면 줄이 가장 가까운 것.
    ///
    /// 기본 이름만 보면 `handle(_:)` 과 `handle(_:result:)` 중 줄이 가까운 쪽이 이긴다.
    /// 그쪽이 진짜 핸들러가 아니면 isthmus 는 엉뚱한 선언을 살리고 진짜 핸들러는 죽은
    /// 코드로 보고된다. 라벨 일치가 실패 방향이 덜 위험하다.
    private static func match(_ declaration: EnclosingDeclaration, among symbols: [IndexedSymbol]) -> IndexedSymbol? {
        nearest(declaration, among: symbols.filter { Self.baseName($0.name) == declaration.indexName || $0.name == declaration.indexName })
            ?? nearest(declaration, among: symbols.filter { SourceFileFacts.baseName(ofIndexName: $0.name) == declaration.name })
    }

    /// 실패 가능 이니셜라이저의 `init?(…)` 를 `init(…)` 으로 맞춘다.
    private static func baseName(_ indexName: String) -> String {
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
