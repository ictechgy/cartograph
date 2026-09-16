import CartographCore
import CartographIndexStore
import CartographSyntax
import Foundation

/// `bridges` 명령이 내보내는 문서. 기본 출력은 버전 1이고 BasicMessageChannel 선택 출력은 버전 2다.
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
    /// BasicMessageChannel 전용 opt-in 문서 버전.
    public static let messageVersion = 2

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
        public let channelPrefix: String?
        public let handlerScope: BridgeFact.HandlerScope?
        public let dependencies: [BridgeFact.Dependency]?
        public let dynamic: Bool
        public let location: SourceLocation
        public let symbol: Symbol?
        public let sourceLanguage: BridgeFact.SourceLanguage?

        private enum CodingKeys: String, CodingKey {
            case kind, channel, method, channelPrefix, handlerScope, dependencies, dynamic, location, symbol, sourceLanguage
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            channel = try container.decodeIfPresent(String.self, forKey: .channel)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            channelPrefix = try container.decodeIfPresent(String.self, forKey: .channelPrefix)
            handlerScope = try container.decodeIfPresent(BridgeFact.HandlerScope.self, forKey: .handlerScope)
            dependencies = try container.decodeIfPresent([BridgeFact.Dependency].self, forKey: .dependencies)
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
            try container.encodeIfPresent(channelPrefix, forKey: .channelPrefix)
            try container.encodeIfPresent(handlerScope, forKey: .handlerScope)
            try container.encodeIfPresent(dependencies, forKey: .dependencies)
            try container.encode(dynamic, forKey: .dynamic)
            try container.encode(location, forKey: .location)
            try container.encodeIfPresent(symbol, forKey: .symbol)
            try container.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
        }

        init(_ fact: BridgeFact, relativeToBaseVariants baseVariants: [String], includeExecution: Bool = true) {
            sourceLanguage = fact.sourceLanguage
            kind = fact.kind.rawValue
            channel = fact.channel
            method = fact.method
            channelPrefix = includeExecution ? fact.channelPrefix : nil
            handlerScope = includeExecution ? fact.handlerScope.map {
                BridgeFact.HandlerScope(
                    start: $0.start.relative(toBaseVariants: baseVariants),
                    end: $0.end.relative(toBaseVariants: baseVariants),
                    complete: $0.complete
                )
            } : nil
            dependencies = includeExecution ? fact.dependencies?.map {
                BridgeFact.Dependency(
                    kind: $0.kind, scope: $0.scope,
                    location: $0.location.relative(toBaseVariants: baseVariants),
                    symbol: $0.symbol, dispatchTargets: $0.dispatchTargets
                )
            } : nil
            dynamic = fact.isDynamic
            location = fact.location.relative(toBaseVariants: baseVariants)
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
    /// 선택한 브리지 전송 방식. v1 MethodChannel 문서에는 쓰지 않는다.
    public let transport: String?
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
        case format, version, tool, generatedAt, platform, transport, target, project, facts, limitations, limitationScopes
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
        opaqueHandlerChannels: [String?] = [],
        version: Int = Self.version,
        transport: String? = nil
    ) {
        format = Self.format
        self.version = version
        self.tool = tool
        self.generatedAt = generatedAt
        platform = "swift"
        self.transport = transport
        self.project = project
        // 사실 수천 건이 각각 기준 경로 표기를 펼치지 않게 한 번만 계산한다.
        let baseVariants = PathFilter.variants(of: project)
        // 실행 근거는 v2 문서 전체와, v1 에서 분기 범위를 단 method-handle 에 실린다.
        // 범위가 없는 사실은 스캐너가 근거를 시도하지 않은 것이므로 그대로 둔다.
        let includeExecution = version == Self.messageVersion
        var executionBudget = 1_000_000
        var executionTruncated = false
        var scopedKinds: Set<String> = []
        self.facts = facts.sorted().map { fact in
            let factExecutes = includeExecution || fact.handlerScope != nil
            guard factExecutes, let scope = fact.handlerScope else {
                return Fact(fact, relativeToBaseVariants: baseVariants, includeExecution: factExecutes)
            }
            scopedKinds.insert(fact.kind.rawValue)
            // 스코프는 있는데 근거 배열이 없으면 완전하다고 할 수 없다.
            // 명세된 스코프의 절반이 비는 것을 조용히 통과시키지 않는다.
            let dependencies = fact.dependencies ?? []
            var dependencyValues: [BridgeFact.Dependency] = []
            var complete = scope.complete && fact.dependencies != nil
            for dependency in dependencies.sorted(by: { $0.location < $1.location }).prefix(10_000) {
                var dispatchTargets = dependency.dispatchTargets
                if dispatchTargets.count > 10_000 {
                    dispatchTargets = Array(dispatchTargets.prefix(10_000))
                    complete = false
                    executionTruncated = true
                }
                let cost = 1 + dispatchTargets.count
                guard executionBudget >= cost else {
                    complete = false
                    executionTruncated = true
                    break
                }
                executionBudget -= cost
                dependencyValues.append(BridgeFact.Dependency(
                    kind: dependency.kind, scope: dependency.scope, location: dependency.location,
                    symbol: dependency.symbol, dispatchTargets: dispatchTargets
                ))
            }
            if dependencies.count > 10_000 {
                complete = false
                executionTruncated = true
            }
            let bounded = fact.attachingExecution(
                handlerScope: .init(start: scope.start, end: scope.end, complete: complete),
                dependencies: dependencyValues
            )
            return Fact(bounded, relativeToBaseVariants: baseVariants, includeExecution: true)
        }

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
        var allLimitations = messages + extraLimitations
        // 이름은 계약 문자열이다. 새 종류마다 같은 모양의 한계를 붙인다.
        // stream-handle 은 스코프를 싣지 않는다 — 스트림 핸들러는 클로저가 아니라
        // FlutterStreamHandler 구현 객체로 넘어가 계약도 근거 부재를 예정한다.
        for (kind, label) in [("message-handle", "message"), ("method-handle", "method")] {
            guard includeExecution || scopedKinds.contains(kind) else { continue }
            let incomplete = self.facts.filter { $0.kind == kind && $0.handlerScope?.complete == false }.count
            if incomplete > 0 {
                allLimitations.append(
                    "incomplete-\(label)-handler-scopes: \(incomplete) handler scopes have missing, stale, ambiguous, or bounded dependency evidence"
                )
            }
        }
        if executionTruncated {
            allLimitations.append(
                "handler-dependencies-truncated: dependency evidence exceeded the documented budget; "
                    + "affected handler scopes are incomplete"
            )
        }
        limitations = allLimitations
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
        try container.encodeIfPresent(transport, forKey: .transport)
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
        let dynamicMessages = facts.count { $0.kind == .messageHandle && $0.isDynamic }
        if dynamicMessages > 0 {
            result.append(
                "dynamic-message-channel-names: \(dynamicMessages) message handlers have a channel name "
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
        let unattributedMessages = facts.count { $0.kind == .messageHandle && $0.channel == nil }
        if unattributedMessages > 0 {
            result.append(
                "unattributed-message-handles: \(unattributedMessages) message handlers have no channel"
            )
        }
        let unscopedMessages = facts.count { $0.kind == .messageHandle && $0.handlerScope == nil }
        if unscopedMessages > 0 {
            result.append(
                "unscoped-message-handlers: \(unscopedMessages) message handler(s) use a method reference "
                    + "without a closure scope"
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
    /// USR → 유일하게 결정되는 심볼. 같은 USR 이 다른 신원으로 기록된 스토어에서는 뺀다.
    private let uniqueSymbols: [String: IndexedSymbol]
    /// 최상위 코드 가상 심볼의 정규화 경로 → USR. main.swift 등록의 소유자다.
    private let topLevelUSRByPath: [String: String]
    private let referencesBySource: [String: [IndexedReference]]
    private let overridesByTarget: [String: [IndexedReference]]
    private let freshPaths: Set<String>
    /// 알려진 경로 → 실제 경로. `canonicalPath` 는 파일시스템을 두드리므로 참조마다 하지 않는다.
    private let canonicalPaths: [String: String]

    init(snapshot: IndexSnapshot, freshPaths: Set<String> = []) {
        let knownPaths = Set(snapshot.symbols.map(\.location.path))
            .union(snapshot.references.compactMap(\.location?.path))
            .union(freshPaths)
        var canonicalPaths: [String: String] = [:]
        for path in knownPaths {
            canonicalPaths[path] = Self.canonical(path)
        }
        self.canonicalPaths = canonicalPaths
        let symbolsByUSR = Dictionary(grouping: snapshot.symbols, by: \.usr)
        symbolsByPath = Dictionary(grouping: snapshot.symbols.filter { !$0.isExternal }) {
            canonicalPaths[$0.location.path] ?? Self.canonical($0.location.path)
        }
        uniqueSymbols = symbolsByUSR.reduce(into: [:]) { result, pair in
            let identities = Set(pair.value.map {
                "\(canonicalPaths[$0.location.path] ?? Self.canonical($0.location.path))\u{0}\($0.name)\u{0}\($0.kind.rawValue)\u{0}\($0.module)"
            })
            result[pair.key] = identities.count == 1 ? pair.value.first : nil
        }
        let prefix = IndexStoreMapping.topLevelCodeUSRPrefix
        topLevelUSRByPath = Dictionary(
            snapshot.symbols.compactMap { symbol -> (String, String)? in
                guard symbol.usr.hasPrefix(prefix) else { return nil }
                return (String(symbol.usr.dropFirst(prefix.count)), symbol.usr)
            }.map { (canonicalPaths[$0.0] ?? Self.canonical($0.0), $0.1) },
            uniquingKeysWith: { first, _ in first }
        )
        referencesBySource = Dictionary(grouping: snapshot.references, by: \.sourceUSR)
        overridesByTarget = Dictionary(
            grouping: snapshot.references.filter { $0.kind == .overrides }, by: \.targetUSR
        )
        self.freshPaths = Set(freshPaths.map(Self.canonical))
    }

    /// 인덱스 표기와 디스크 표기가 갈릴 수 있는 경로의 실제 경로.
    private func canonicalPath(_ path: String) -> String {
        canonicalPaths[path] ?? Self.canonical(path)
    }

    func resolve(
        _ scanned: [ScannedBridgeFact],
        handlerScopes: [ScannedBridgeHandlerScopes] = []
    ) -> [BridgeFact] {
        var dependencyBudget = 1_000_000
        return resolve(scanned, handlerScopes: handlerScopes, dependencyBudget: &dependencyBudget)
    }

    /// 파일을 나누어 스캔해도 문서 전체의 생성 예산을 공유한다.
    func resolve(
        _ scanned: [ScannedBridgeFact],
        handlerScopes: [ScannedBridgeHandlerScopes],
        dependencyBudget: inout Int
    ) -> [BridgeFact] {
        func normalizedLocation(_ location: SourceLocation) -> SourceLocation {
            SourceLocation(
                path: canonicalPath(location.path), line: location.line, column: location.column)
        }
        func normalizedScope(_ scope: BridgeFact.HandlerScope) -> BridgeFact.HandlerScope {
            .init(start: normalizedLocation(scope.start), end: normalizedLocation(scope.end), complete: false)
        }
        let messageEntries = Dictionary(grouping: scanned.compactMap { item -> (String, BridgeFact.HandlerScope?)? in
            guard item.fact.kind == .messageHandle, let declaration = item.declaration else { return nil }
            return (declarationKey(declaration), item.fact.handlerScope.map(normalizedScope))
        }, by: \.0).mapValues { $0.map(\.1) }
        // method-handle 의 분기 범위는 사실이 직접 싣고 온다. 클로저 범위와 한 목록에
        // 섞이면 둘이 겹쳐 양쪽 근거가 모두 불완전해지므로 선언별로 따로 모은다.
        var branchScopesByDeclaration: [String: [BridgeFact.HandlerScope]] = [:]
        for item in scanned where item.fact.kind == .methodHandle {
            guard let declaration = item.declaration, let scope = item.fact.handlerScope else { continue }
            branchScopesByDeclaration[declarationKey(declaration), default: []].append(normalizedScope(scope))
        }
        let branchScopeSets = branchScopesByDeclaration.mapValues { scopes in
            Set(scopes).sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        }
        let branchScopeValidity = branchScopeSets.mapValues { !Self.hasOverlappingScopes($0) }
        var scopedEntriesByDeclaration: [String: [BridgeFact.HandlerScope]] = [:]
        for entry in handlerScopes {
            scopedEntriesByDeclaration[declarationKey(entry.declaration), default: []]
                .append(contentsOf: entry.scopes.map(normalizedScope))
        }
        if handlerScopes.isEmpty {
            for item in scanned {
                guard let declaration = item.declaration else { continue }
                let key = declarationKey(declaration)
                scopedEntriesByDeclaration[key, default: []].append(contentsOf: item.handlerScopes.map(normalizedScope))
            }
        }
        var scopesByDeclaration = scopedEntriesByDeclaration.mapValues { scopes in
            Set(scopes).sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        }
        let scopeValidity = Dictionary(uniqueKeysWithValues: messageEntries.map { key, values in
            let scopes = scopesByDeclaration[key] ?? []
            let declared = Set(scopes)
            return (key, !declared.isEmpty && values.allSatisfy { scope in
                scope.map { declared.contains($0) } == true
            } && !Self.hasOverlappingScopes(scopes))
        })
        // 전체 목록이 없어도 관찰한 closure 내부 참조를 공통 등록 의존으로 바꾸지 않는다.
        // 이 보충은 귀속만 보존하며 위에서 확인하지 못한 완전성을 올리지 않는다.
        for (key, values) in messageEntries {
            scopesByDeclaration[key] = Set((scopesByDeclaration[key] ?? []) + values.compactMap { $0 })
                .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        }
        var evidenceByDeclaration: [String: ClassifiedReferences] = [:]
        var dispatchCache: [String: DispatchResult] = [:]
        return scanned.map { entry in
            guard let declaration = entry.declaration else {
                guard entry.fact.kind == .messageHandle || entry.fact.kind == .methodHandle,
                      let scope = entry.fact.handlerScope else { return entry.fact }
                var fact = entry.fact.attachingExecution(
                    handlerScope: .init(start: scope.start, end: scope.end, complete: false), dependencies: []
                )
                // 최상위 등록에는 감싸는 선언이 없다. 파일의 가상 최상위 심볼이 있으면
                // 그것이 소유자다 — 계약은 사실마다 감싸는 심볼을 요구한다.
                if let usr = topLevelUSRByPath[canonicalPath(entry.fact.location.path)],
                   let topLevel = uniqueSymbols[usr] {
                    fact = fact.attaching(BridgeFact.Symbol(
                        qualifiedName: Self.contractName(of: topLevel), usr: topLevel.usr))
                }
                return fact
            }
            let candidates = symbolsByPath[canonicalPath(entry.fact.location.path)] ?? []
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
            let resolved = entry.fact.attaching(BridgeFact.Symbol(qualifiedName: declaration.qualifiedName, usr: symbol?.usr))
            let isMethodBranch = entry.fact.kind == .methodHandle
            guard entry.fact.kind == .messageHandle || isMethodBranch,
                  let scope = entry.fact.handlerScope else {
                return resolved
            }
            guard let usr = symbol?.usr else {
                return resolved.attachingExecution(
                    handlerScope: .init(start: scope.start, end: scope.end, complete: false), dependencies: []
                )
            }
            let declarationKey = self.declarationKey(declaration)
            // 분기 우주는 종류마다 다르다. 메시지는 클로저 범위, 메서드는 case/if 본문이다.
            let allScopes = isMethodBranch
                ? (branchScopeSets[declarationKey] ?? []) : (scopesByDeclaration[declarationKey] ?? [])
            let allScopesComplete = isMethodBranch
                ? (branchScopeValidity[declarationKey] ?? false) : (scopeValidity[declarationKey] ?? false)
            let ownerKey = usr + "\u{0}" + declarationKey + (isMethodBranch ? "|method" : "|message")
            let evidence = evidenceByDeclaration[ownerKey] ?? classifyReferences(
                setupUSR: usr, declaration: declaration, allScopes: allScopes
            )
            evidenceByDeclaration[ownerKey] = evidence
            let dependencies = executionDependencies(
                declaration: declaration, scope: normalizedScope(scope),
                evidence: evidence,
                allScopesComplete: allScopesComplete,
                dispatchCache: &dispatchCache, dependencyBudget: &dependencyBudget
            )
            return resolved.attachingExecution(
                handlerScope: .init(start: scope.start, end: scope.end, complete: dependencies.complete),
                dependencies: dependencies.values
            )
        }
    }

    private struct DependencyResult {
        let values: [BridgeFact.Dependency]
        let complete: Bool
    }

    private struct ClassifiedReferences {
        let registration: [IndexedReference]
        let handler: [BridgeFact.HandlerScope: [IndexedReference]]
        let complete: Bool
        let registrationComplete: Bool
        let incompleteHandlers: Set<BridgeFact.HandlerScope>
    }

    private struct DispatchResult {
        let targets: [BridgeFact.Symbol]
        let complete: Bool
    }

    private func classifyReferences(
        setupUSR: String,
        declaration: EnclosingDeclaration,
        allScopes: [BridgeFact.HandlerScope]
    ) -> ClassifiedReferences {
        var complete = true
        var registration: [IndexedReference] = []
        var handler: [BridgeFact.HandlerScope: [IndexedReference]] = [:]
        var registrationComplete = true
        var incompleteHandlers: Set<BridgeFact.HandlerScope> = []
        // 선언 범위의 경로는 참조마다가 아니라 여기서 한 번만 실제 경로로 맞춘다.
        let normalizedStart = declaration.start.map {
            SourceLocation(path: canonicalPath($0.path), line: $0.line, column: $0.column)
        }
        let normalizedEnd = declaration.end.map {
            SourceLocation(path: canonicalPath($0.path), line: $0.line, column: $0.column)
        }
        for reference in referencesBySource[setupUSR, default: []]
        where reference.kind == .call || reference.kind == .reference {
            guard reference.targetKind != .parameter else { continue }
            guard let location = reference.location else {
                let isKnownNonExecutableTarget = uniqueSymbol(for: reference.targetUSR).map {
                    $0.isExternal || $0.kind == .parameter
                } == true
                if !isKnownNonExecutableTarget { complete = false }
                continue
            }
            if let normalizedStart, let normalizedEnd,
               !containsNormalized(location, start: normalizedStart, end: normalizedEnd) { continue }
            let scope = containingScope(location, in: allScopes)
            guard let target = uniqueSymbol(for: reference.targetUSR) else {
                if let scope { incompleteHandlers.insert(scope) } else { registrationComplete = false }
                continue
            }
            guard !target.isExternal, target.kind != .parameter else {
                // 외부 요구사항을 부르는 호출은 간선으로 담을 대상이 없다. 그 요구사항의
                // 프로젝트 내 구현이 있으면 근거를 빠뜨린 채 완전하다고 해선 안 된다.
                if target.isExternal, !overridesByTarget[reference.targetUSR, default: []].isEmpty {
                    if let scope { incompleteHandlers.insert(scope) } else { registrationComplete = false }
                }
                continue
            }
            if let scope {
                handler[scope, default: []].append(reference)
            } else {
                registration.append(reference)
            }
        }
        return ClassifiedReferences(registration: registration, handler: handler, complete: complete,
            registrationComplete: registrationComplete, incompleteHandlers: incompleteHandlers)
    }

    private func executionDependencies(
        declaration: EnclosingDeclaration,
        scope: BridgeFact.HandlerScope,
        evidence: ClassifiedReferences,
        allScopesComplete: Bool,
        dispatchCache: inout [String: DispatchResult],
        dependencyBudget: inout Int
    ) -> DependencyResult {
        let declarationStart = declaration.start
        let declarationEnd = declaration.end
        var complete = evidence.complete && evidence.registrationComplete && !evidence.incompleteHandlers.contains(scope)
            && allScopesComplete && declarationStart != nil && declarationEnd != nil
            && freshPaths.contains(scope.start.path)
        var values: Set<BridgeFact.Dependency> = []
        // 예산이 증거를 잘라도 입력 순서가 출력에 남지 않도록 정규 순서로 소비한다.
        dependencies: for (references, dependencyScope) in [
            (evidence.handler[scope, default: []].sorted(by: Self.referenceOrder),
             BridgeFact.Dependency.Scope.handler),
            (evidence.registration.sorted(by: Self.referenceOrder), BridgeFact.Dependency.Scope.registration),
        ] {
          for reference in references {
            if values.count >= 10_000 || dependencyBudget == 0 {
                complete = false
                break dependencies
            }
            guard let target = uniqueSymbol(for: reference.targetUSR) else {
                complete = false
                continue
            }
            guard !target.isExternal, target.kind != .parameter else { continue }
            guard let location = reference.location else {
                complete = false
                continue
            }
            let dispatch: DispatchResult
            if let cached = dispatchCache[target.usr] {
                dispatch = cached
            } else {
                var dispatchComplete = true
                let targets = dispatchTargets(for: target.usr, complete: &dispatchComplete)
                dispatch = DispatchResult(targets: targets, complete: dispatchComplete)
                dispatchCache[target.usr] = dispatch
            }
            complete = complete && dispatch.complete
            let dependency = BridgeFact.Dependency(
                kind: reference.kind,
                scope: dependencyScope,
                location: location,
                symbol: BridgeFact.Symbol(qualifiedName: Self.contractName(of: target), usr: target.usr),
                dispatchTargets: dispatch.targets
            )
            if !values.contains(dependency) {
                let cost = 1 + dependency.dispatchTargets.count
                guard dependencyBudget >= cost else {
                    complete = false
                    break dependencies
                }
                dependencyBudget -= cost
                values.insert(dependency)
            }
          }
        }
        return DependencyResult(values: values.sorted(by: Self.dependencyOrder), complete: complete)
    }

    private func dispatchTargets(for rootUSR: String, complete: inout Bool) -> [BridgeFact.Symbol] {
        var pending = [rootUSR]
        var next = 0
        var targets: [BridgeFact.Symbol] = []
        // seenTargets 가 큐의 중복 진입까지 막는다. 같은 구현을 가리키는 간선이
        // 여럿이어도 각 USR 은 한 번만 펼친다.
        var seenTargets: Set<String> = [rootUSR]
        while next < pending.count {
            let current = pending[next]
            next += 1
            let overrides = overridesByTarget[current, default: []].sorted {
                ($0.sourceUSR, $0.location?.description ?? "") < ($1.sourceUSR, $1.location?.description ?? "")
            }
            for override in overrides {
                guard let implementation = uniqueSymbol(for: override.sourceUSR) else {
                    complete = false
                    continue
                }
                guard !implementation.isExternal else { continue }
                guard seenTargets.insert(implementation.usr).inserted else { continue }
                targets.append(BridgeFact.Symbol(
                    qualifiedName: Self.contractName(of: implementation), usr: implementation.usr
                ))
                if targets.count >= 10_000 {
                    complete = false
                    return targets.sorted { ($0.usr ?? "", $0.qualifiedName) < ($1.usr ?? "", $1.qualifiedName) }
                }
                pending.append(implementation.usr)
            }
        }
        return targets.sorted { ($0.usr ?? "", $0.qualifiedName) < ($1.usr ?? "", $1.qualifiedName) }
    }

    private func declarationKey(_ declaration: EnclosingDeclaration) -> String {
        guard let start = declaration.start, let end = declaration.end else {
            return "\(declaration.qualifiedName)#\(declaration.line)"
        }
        // 같은 이름과 줄을 공유하는 overload/파일의 선언을 하나로 합치지 않는다.
        // 범위는 스캐너가 실제 구문에서 얻은 식별자이며, 이름 추측이 아니다.
        return "\(canonicalPath(start.path))#\(start.line):\(start.column)-\(end.line):\(end.column)"
    }

    private static func hasOverlappingScopes(_ scopes: [BridgeFact.HandlerScope]) -> Bool {
        // 스코프 경로는 진입 시점에 이미 실제 경로로 맞춰져 있다.
        let sorted = scopes.sorted { $0.start < $1.start }
        for (left, right) in zip(sorted, sorted.dropFirst())
        where right.start.path == left.start.path
            && (right.start.line, right.start.column) <= (left.end.line, left.end.column) {
            return true
        }
        return false
    }

    private func containingScope(
        _ location: SourceLocation, in scopes: [BridgeFact.HandlerScope]
    ) -> BridgeFact.HandlerScope? {
        var low = 0
        var high = scopes.count
        while low < high {
            let middle = (low + high) / 2
            let start = scopes[middle].start
            if (start.line, start.column) <= (location.line, location.column) { low = middle + 1 } else { high = middle }
        }
        let candidate = max(0, low - 1)
        guard candidate < scopes.count else { return nil }
        let scope = scopes[candidate]
        return containsNormalized(location, start: scope.start, end: scope.end) ? scope : nil
    }

    /// start/end 의 경로는 호출부가 이미 실제 경로로 맞춘 값이다.
    private func containsNormalized(_ location: SourceLocation, start: SourceLocation, end: SourceLocation) -> Bool {
        canonicalPath(location.path) == start.path
            && (location.line, location.column) >= (start.line, start.column)
            && (location.line, location.column) <= (end.line, end.column)
    }

    /// 예산이 증거를 잘라도 입력 순서가 출력에 남지 않도록 하는 정규 순서.
    private static func referenceOrder(_ lhs: IndexedReference, _ rhs: IndexedReference) -> Bool {
        let leftPosition = (lhs.location?.path ?? "", lhs.location?.line ?? 0, lhs.location?.column ?? 0)
        let rightPosition = (rhs.location?.path ?? "", rhs.location?.line ?? 0, rhs.location?.column ?? 0)
        guard leftPosition == rightPosition else { return leftPosition < rightPosition }
        return (lhs.targetUSR, lhs.kind.rawValue, lhs.origin.rawValue, lhs.targetKind?.rawValue ?? "")
            < (rhs.targetUSR, rhs.kind.rawValue, rhs.origin.rawValue, rhs.targetKind?.rawValue ?? "")
    }

    private static func dependencyOrder(
        _ lhs: BridgeFact.Dependency, _ rhs: BridgeFact.Dependency
    ) -> Bool {
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        if lhs.scope != rhs.scope { return lhs.scope.rawValue < rhs.scope.rawValue }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.symbol.usr != rhs.symbol.usr { return (lhs.symbol.usr ?? "") < (rhs.symbol.usr ?? "") }
        let leftDispatch = lhs.dispatchTargets.map { "\($0.usr ?? ""):\($0.qualifiedName)" }.joined(separator: "\u{0}")
        let rightDispatch = rhs.dispatchTargets.map { "\($0.usr ?? ""):\($0.qualifiedName)" }.joined(separator: "\u{0}")
        return leftDispatch < rightDispatch
    }

    private static func contractName(of symbol: IndexedSymbol) -> String {
        symbol.module.isEmpty ? symbol.name : "\(symbol.module).\(symbol.name)"
    }

    private func uniqueSymbol(for usr: String) -> IndexedSymbol? {
        uniqueSymbols[usr]
    }

    private static func canonical(_ path: String) -> String {
        LocalFileSystem.canonicalPath(path)
    }

    /// 인자 라벨까지 같은 심볼을 찾는다. 여럿이면 줄이 가장 가까운 것.
    ///
    /// 라벨 일치가 실패하면 기본 이름이 같은 심볼이 **하나뿐일 때만** 그것을 쓴다. 후보가
    /// 여럿인데 줄 거리로 고르면 `handle(_:)` 과 `handle(_:result:)` 중 엉뚱한 쪽에 USR 이
    /// 붙고, isthmus 는 그 선언을 살리고 진짜 핸들러는 죽은 코드로 보고된다.
    /// USR 이 없는 쪽이 틀린 USR 보다 안전하다. 없으면 `missing-handler-usrs` 로 세어진다.
    private static func match(_ declaration: EnclosingDeclaration, among symbols: [IndexedSymbol]) -> IndexedSymbol? {
        let labelled = symbols.filter { normalizingInitializer($0.name) == declaration.indexName }
        // 라벨 후보가 있는데 가까운 줄이 동률이면 다른 라벨의 심볼로 물러나지 않는다.
        if !labelled.isEmpty { return nearest(declaration, among: labelled) }
        let sameBase = symbols.filter { GraphNode.baseName(ofIndexName: $0.name) == declaration.name }
        return sameBase.count == 1 ? sameBase.first : nil
    }

    /// 실패 가능 이니셜라이저의 `init?(…)` 와 `init!(…)` 를 `init(…)` 으로 맞춘다. 구문 쪽 이름에는 물음표가 없다.
    private static func normalizingInitializer(_ indexName: String) -> String {
        indexName.replacingOccurrences(of: "?(", with: "(").replacingOccurrences(of: "!(", with: "(")
    }

    /// 가장 가까운 줄의 후보를 고른다. 거리가 같은 후보가 다른 USR 로 여럿이면 어느 쪽도
    /// 증거가 아니므로 둘 다 버린다 — USR 사전순 선택은 결정적이지만 틀릴 수 있다.
    private static func nearest(_ declaration: EnclosingDeclaration, among symbols: [IndexedSymbol]) -> IndexedSymbol? {
        let best = symbols.map { abs($0.location.line - declaration.line) }.min()
        let winners = symbols.filter { abs($0.location.line - declaration.line) == best }
        return Set(winners.map(\.usr)).count == 1 ? winners.first : nil
    }
}
