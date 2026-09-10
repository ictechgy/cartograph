import CartographCore
import CartographSyntax
import Foundation

/// `bridges` 명령이 내보내는 문서. isthmus 가 읽는 교환 형식(버전 1)이다.
///
/// 이 문서는 Swift 플랫폼 쪽에서 본 Swift·Objective-C 사실을 담는다. "이 핸들러를 Dart 가 실제로 부른다"는 판정은
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
        public let sourceLanguage: BridgeFact.SourceLanguage?

        private enum CodingKeys: String, CodingKey {
            case kind, channel, method, dynamic, location, symbol, sourceLanguage
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            channel = try container.decodeIfPresent(String.self, forKey: .channel)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            dynamic = try container.decode(Bool.self, forKey: .dynamic)
            location = try container.decode(SourceLocation.self, forKey: .location)
            symbol = try container.decodeIfPresent(Symbol.self, forKey: .symbol)
            sourceLanguage = try container.decodeIfPresent(BridgeFact.SourceLanguage.self, forKey: .sourceLanguage)
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
            try container.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
        }

        init(_ fact: BridgeFact, relativeTo projectPath: String) {
            sourceLanguage = fact.sourceLanguage
            kind = fact.kind.rawValue
            channel = fact.channel
            method = fact.method
            dynamic = fact.isDynamic
            location = fact.location.relative(to: projectPath)
            symbol = fact.symbol.map { Symbol(qualifiedName: $0.qualifiedName, usr: $0.usr) }
        }
    }

    /// 문자열의 특정 한계 항목 전체를 포함하는 채널 집합. 범위를 모르면 항목 자체를 만들지 않는다.
    public struct LimitationScope: Sendable, Equatable, Codable {
        public let limitationIndex: Int
        public let channels: [String]
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
    /// 생산자가 해결한 실제 절대 루트. 소비자는 이 문자열을 바꾸지 않고 정확히 비교한다.
    public let project: String
    public let facts: [Fact]
    /// 이 문서가 보지 못한 것. 매번 붙는 경보가 아니라 실제로 센 값이다.
    public let limitations: [String]
    public let limitationScopes: [LimitationScope]?

    private enum CodingKeys: String, CodingKey {
        case format, version, tool, generatedAt, platform, target, project, facts, limitations, limitationScopes
    }

    public init(
        tool: Tool,
        generatedAt: String,
        project: String,
        facts: [BridgeFact],
        unscannedEventChannels: Int = 0,
        unscannedMessageChannels: Int = 0,
        objectiveCSourceCount: Int = 0,
        extraLimitations: [String] = [],
        opaqueHandlerChannels: [String?] = []
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
        var messages = Self.limitations(
            for: facts, targets: targets,
            unscannedEventChannels: unscannedEventChannels, unscannedMessageChannels: unscannedMessageChannels,
            objectiveCSourceCount: objectiveCSourceCount
        )
        if !opaqueHandlerChannels.isEmpty {
            let known = opaqueHandlerChannels.compactMap { $0 }
            limitationScopes = known.count == opaqueHandlerChannels.count
                ? [LimitationScope(limitationIndex: messages.count, channels: Set(known).sorted())]
                : nil
            messages.append(
                "opaque-handler-bodies: \(opaqueHandlerChannels.count) handler registration(s) use bodies "
                    + "outside the supported local scan"
            )
        } else {
            limitationScopes = nil
        }
        limitations = messages + extraLimitations
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
        try container.encodeIfPresent(limitationScopes, forKey: .limitationScopes)
    }

    /// 다른 도구가 문서 전체를 거부하게 되는 이름을 출력 전에 가른다. 값을 오류 문장에 싣지 않는다.
    static func validateNames(_ facts: [BridgeFact], opaqueHandlerChannels: [String?]) throws {
        let factNames = facts.flatMap { [$0.channel, $0.method].compactMap { $0 } }
        guard (factNames + opaqueHandlerChannels.compactMap { $0 }).allSatisfy({ name in
            !name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))).isEmpty && !name.unicodeScalars.contains {
                $0.value < 32 || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029
            }
        }) else { throw CartographError.unsupportedBridgeName }
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
            result.append(
                "dynamic-channel-names: \(dynamicChannels) channel-registration facts have a channel name "
                    + "that could not be resolved statically"
            )
        }
        let dynamicMethods = facts.count { $0.kind == .methodHandle && $0.isDynamic }
        if dynamicMethods > 0 {
            result.append(
                "dynamic-method-names: \(dynamicMethods) method-handler facts have a channel or method name "
                    + "that could not be resolved statically, so they cannot be joined "
                    + "and are listed with their source expression"
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
        // Swift 신선도 신호다("빌드 뒤 편집된 Swift"). ObjC 핸들러는 이름뿐 심볼이 돼도 여기에
        // 섞지 않는다. `objective-c-handlers` 과 같은 경로 술어로 가른다 — 한쪽에 세면 다른 쪽에
        // 안 센다. sourceLanguage 표식을 빠뜨린 스캔 경로가 생겨도 신호가 오염되지 않는다.
        let missingUSRs = facts.count {
            $0.kind == .methodHandle && $0.location.path.hasSuffix(".swift")
                && $0.symbol != nil && $0.symbol?.usr == nil
        }
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
                    + "are outside the Swift analysis graph, so their retentions cannot be applied by --external-retentions"
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
        // 직접 패턴을 읽었어도 ObjC 전체의 완전성을 증명하지 못한다. 일부 채널을 찾았다는
        // 이유로 범위를 좁히면 미지원 코드가 다른 채널의 핸들러를 가리는 경우 거짓 error가 된다.
        if objectiveCSourceCount > 0 {
            result.append(
                "objective-c-sources: \(objectiveCSourceCount) Objective-C file(s) were read for React Native "
                    + "export macros and supported direct Flutter patterns; other Objective-C handlers may be absent"
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
        symbolsByPath = Dictionary(grouping: snapshot.symbols.filter { !$0.isExternal }) { Self.canonical($0.location.path) }
    }

    func resolve(_ scanned: [ScannedBridgeFact]) -> [BridgeFact] {
        scanned.map { entry in
            guard let declaration = entry.declaration else { return entry.fact }
            let candidates = symbolsByPath[Self.canonical(entry.fact.location.path)] ?? []
            if entry.fact.sourceLanguage == .objectiveC {
                // 이름이나 가장 가까운 줄로 추측하지 않는다. Clang 정의 위치가 유일할 때만 USR 을 붙인다.
                let exact = candidates.filter {
                    $0.usr.hasPrefix("c:") && $0.name == declaration.indexName && $0.location.line == declaration.line
                }
                // 여러 빌드 구성을 묶은 스토어에서는 같은 선언이 같은 USR 로 두 번 기록되기도 한다.
                // USR 이 하나로 유일하면 그것이 이 선언의 신원이다.
                guard Set(exact.map(\.usr)).count == 1, let symbol = exact.first else {
                    // 유일한 매치가 없으면 Swift 사실과 같은 대칭으로 구문의 이름만 싣는다. 이름은
                    // 소스에서 결정적이지만 USR 은 그렇지 않고, 틀린 USR 은 없는 것보다 나쁘다.
                    // 인덱스 없이 빌드된 환경의 ObjC 핸들러가 신원 없는 증거로만 남는 것을 막는다(#75).
                    return entry.fact.attaching(BridgeFact.Symbol(qualifiedName: declaration.qualifiedName, usr: nil))
                }
                return entry.fact.attaching(BridgeFact.Symbol(qualifiedName: declaration.qualifiedName, usr: symbol.usr))
            }
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
