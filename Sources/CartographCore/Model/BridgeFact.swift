/// 언어 경계(브리지)에서 이 도구가 Swift 쪽에서 본 사실 하나.
///
/// isthmus 가 Dart·JS·Kotlin 쪽 사실과 조인해 "이 Swift 핸들러를 Dart 가 부른다"를
/// 만든다. 그래서 여기서는 **판정하지 않는다.** 리터럴이 아닌 이름도 버리지 않고
/// `isDynamic` 으로 표시한다. isthmus 가 조인하지 못한 사실을 한계로 세는 데 필요하다.
///
/// 교환 형식(`../isthmus/docs/GRAPH-EXCHANGE.md` 버전 1)의 직렬화 모양은 이 타입이
/// 아니라 `CartographKit` 의 문서 타입이 정한다. 여기서는 스캐너가 알아낸 것을 그대로 담는다.
public struct BridgeFact: Hashable, Sendable {
    /// 핸들러 closure의 소스 범위와 그 범위에서 확인한 의존성의 완전성.
    public struct HandlerScope: Hashable, Sendable, Codable {
        public let start: SourceLocation
        public let end: SourceLocation
        public let complete: Bool

        public init(start: SourceLocation, end: SourceLocation, complete: Bool) {
            self.start = start
            self.end = end
            self.complete = complete
        }
    }

    /// 인덱스 발생 위치로 귀속한 closure 또는 등록부의 심볼 의존성.
    public struct Dependency: Hashable, Sendable, Codable {
        public enum Scope: String, Hashable, Sendable, Codable {
            case handler
            case registration
        }

        public let kind: EdgeKind
        public let scope: Scope
        public let location: SourceLocation
        public let symbol: Symbol
        public let dispatchTargets: [Symbol]

        private enum CodingKeys: String, CodingKey { case kind, scope, location, symbol, dispatchTargets }

        public init(
            kind: EdgeKind,
            scope: Scope,
            location: SourceLocation,
            symbol: Symbol,
            dispatchTargets: [Symbol] = []
        ) {
            self.kind = kind
            self.scope = scope
            self.location = location
            self.symbol = symbol
            self.dispatchTargets = dispatchTargets.sorted { ($0.usr ?? "", $0.qualifiedName) < ($1.usr ?? "", $1.qualifiedName) }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(EdgeKind.self, forKey: .kind)
            scope = try container.decode(Scope.self, forKey: .scope)
            location = try container.decode(SourceLocation.self, forKey: .location)
            symbol = try container.decode(Symbol.self, forKey: .symbol)
            dispatchTargets = try container.decodeIfPresent([Symbol].self, forKey: .dispatchTargets) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(scope, forKey: .scope)
            try container.encode(location, forKey: .location)
            try container.encode(symbol, forKey: .symbol)
            try container.encodeIfPresent(dispatchTargets.isEmpty ? nil : dispatchTargets, forKey: .dispatchTargets)
        }
    }

    /// 사실의 종류. 교환 형식의 `kind` 값 그대로다.
    public enum Kind: String, Sendable, CaseIterable {
        /// 채널에 핸들러를 달았다(`setMethodCallHandler`, `addMethodCallDelegate`).
        ///
        /// 채널 객체를 만들기만 한 것은 사실이 아니다. 계약이 그렇게 정했고, 채널 이름은
        /// 생성자에서 등록 호출로 변수 참조를 따라 옮긴다.
        case channelRegister = "channel-register"
        /// 핸들러 안에서 메서드 이름으로 분기했다(`case "…"`) 또는 네이티브 메서드를 내보냈다.
        case methodHandle = "method-handle"
        /// BasicMessageChannel 에 메시지 핸들러를 달았다(`setMessageHandler`의 non-nil 등록).
        case messageHandle = "message-handle"
        /// EventChannel 에 스트림 핸들러를 달았다(`setStreamHandler`의 non-nil 등록).
        ///
        /// 스트림 핸들러는 클로저가 아니라 객체이므로 호출 지점에만 귀속한다. 핸들러 객체의
        /// `onListen`/`onCancel` 구현은 등록 선언의 인덱스 참조로 이어진다.
        case streamHandle = "stream-handle"
        /// 코어 RN 전역 이벤트의 실제 네이티브 방출 위치다.
        case eventEmit = "event-emit"
        /// React Native 모듈을 내보냈다(`@objc(Name)`, `RCT_EXPORT_MODULE`, Expo `Module`/`@ExpoModule`).
        case moduleExport = "module-export"
        /// React Native 뷰 매니저를 내보냈다(`RCT_EXPORT_VIEW_PROPERTY`, Expo `View` 정의).
        case componentExport = "component-export"
        /// 코드가 DB 관계(테이블·뷰)를 참조했다 — `relation-decl`은 schemagraph의 몫이다.
        ///
        /// `channel`은 관계 이름, `method`는 컬럼 이름이다. persistence 문서에서만 나온다.
        case relationUse = "relation-use"
    }

    /// 이름 경계 사실이 어느 React Native 해석 경로에 속하는지. 생략은 `core`다.
    ///
    /// 교환 형식은 이 필드를 이름 경계 사실(`module-*`·`component-*`)에만 허용하고
    /// `method-handle`·`channel-register` 등에는 싣지 않는다. 생략된 사실은 코어 RN
    /// 경로로 읽힌다 — Expo DSL로 만든 사실에만 `.expo` 를 단다.
    public enum Mechanism: String, Sendable, Codable {
        case core
        case expo
    }

    /// 이 사실이 어느 브리지 메커니즘에 속하는지.
    public enum Target: String, Sendable, CaseIterable {
        case flutter
        case reactNative = "react-native"
        /// 코드 ↔ DB 스키마 경계. 브리지 메커니즘은 아니지만 같은 교환 문서가 실는다.
        case persistence = "persistence"
    }

    /// 이 사실을 담고 있는 선언. 인덱스에서 찾았으면 USR 이 있다.
    ///
    /// 클로저 안의 `case "…"` 는 자기 USR 이 없다. 그때는 감싸는 함수나 타입을 적는다.
    /// isthmus 가 돌려주는 보존 근거가 이 USR 을 가리킨다.
    public struct Symbol: Hashable, Sendable, Codable {
        public let qualifiedName: String
        public let usr: String?

        public init(qualifiedName: String, usr: String?) {
            self.qualifiedName = qualifiedName
            self.usr = usr
        }
    }

    /// Swift 플랫폼 문서 안의 Objective-C 구현은 Swift 그래프의 보존 대상이 아니다.
    public enum SourceLanguage: String, Sendable, Codable {
        case objectiveC = "objective-c"
    }

    public let sourceLanguage: SourceLanguage?
    public let kind: Kind
    public let target: Target
    /// 코어 RN이면 nil(생략). Expo Modules DSL에서 온 이름 경계 사실만 `.expo`다.
    public let mechanism: Mechanism?
    /// 채널 이름 또는 모듈 이름. 알 수 없으면 nil, 리터럴이 아니면 원문 표현식.
    public let channel: String?
    /// `method-handle` 에만 있는 메서드 이름.
    public let method: String?
    /// 채널이나 메서드가 리터럴이 아니라 표현식이었는지 여부.
    public let isDynamic: Bool
    /// 동적 채널 표현식에서 AST가 확인한 선행 리터럴. BasicMessageChannel 문서에서만 쓴다.
    public let channelPrefix: String?
    public let handlerScope: HandlerScope?
    public let dependencies: [Dependency]?
    /// 채널을 핸들러 문맥이 아니라 "파일에 채널이 하나뿐" 이라는 추측으로 붙였는지 여부.
    ///
    /// 교환 형식에는 이 구분이 없다. 소비자가 추측과 사실을 가를 수 없으므로 문서 단위로
    /// 수를 세어 `limitations` 에 싣는다.
    public let isChannelInferred: Bool
    public let location: SourceLocation
    public let symbol: Symbol?

    public init(
        kind: Kind,
        target: Target,
        channel: String?,
        method: String? = nil,
        isDynamic: Bool = false,
        channelPrefix: String? = nil,
        handlerScope: HandlerScope? = nil,
        dependencies: [Dependency]? = nil,
        isChannelInferred: Bool = false,
        mechanism: Mechanism? = nil,
        location: SourceLocation,
        symbol: Symbol? = nil,
        sourceLanguage: SourceLanguage? = nil
    ) {
        self.sourceLanguage = sourceLanguage
        self.kind = kind
        self.target = target
        self.mechanism = mechanism
        self.channel = channel
        self.method = method
        self.isDynamic = isDynamic
        self.channelPrefix = channelPrefix
        self.handlerScope = handlerScope
        self.dependencies = dependencies?.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            if lhs.scope != rhs.scope { return lhs.scope.rawValue < rhs.scope.rawValue }
            return (lhs.symbol.usr ?? "") < (rhs.symbol.usr ?? "")
        }
        self.isChannelInferred = isChannelInferred
        self.location = location
        self.symbol = symbol
    }

    /// 같은 사실에 선언 정보만 붙인 사본.
    public func attaching(_ symbol: Symbol?) -> BridgeFact {
        BridgeFact(
            kind: kind,
            target: target,
            channel: channel,
            method: method,
            isDynamic: isDynamic,
            channelPrefix: channelPrefix,
            handlerScope: handlerScope,
            dependencies: dependencies,
            isChannelInferred: isChannelInferred,
            mechanism: mechanism,
            location: location,
            symbol: symbol,
            sourceLanguage: sourceLanguage
        )
    }

    /// 인덱스 결합 뒤 closure 의존성 근거를 덧붙인 사본.
    public func attachingExecution(
        handlerScope: HandlerScope?, dependencies: [Dependency]?
    ) -> BridgeFact {
        BridgeFact(
            kind: kind,
            target: target,
            channel: channel,
            method: method,
            isDynamic: isDynamic,
            channelPrefix: channelPrefix,
            handlerScope: handlerScope,
            dependencies: dependencies,
            isChannelInferred: isChannelInferred,
            mechanism: mechanism,
            location: location,
            symbol: symbol,
            sourceLanguage: sourceLanguage
        )
    }
}

extension BridgeFact: Comparable {
    /// 위치 순, 같은 위치면 종류·채널·메서드 순. 출력을 diff 할 수 있어야 한다.
    public static func < (lhs: BridgeFact, rhs: BridgeFact) -> Bool {
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.channel != rhs.channel { return (lhs.channel ?? "") < (rhs.channel ?? "") }
        if lhs.method != rhs.method { return (lhs.method ?? "") < (rhs.method ?? "") }
        if lhs.channelPrefix != rhs.channelPrefix { return (lhs.channelPrefix ?? "") < (rhs.channelPrefix ?? "") }
        if lhs.handlerScope != rhs.handlerScope { return (lhs.handlerScope?.start ?? .init(path: "", line: 0, column: 0)) < (rhs.handlerScope?.start ?? .init(path: "", line: 0, column: 0)) }
        if lhs.mechanism != rhs.mechanism { return (lhs.mechanism?.rawValue ?? "") < (rhs.mechanism?.rawValue ?? "") }
        if lhs.target != rhs.target { return lhs.target.rawValue < rhs.target.rawValue }
        if lhs.symbol?.usr != rhs.symbol?.usr { return (lhs.symbol?.usr ?? "") < (rhs.symbol?.usr ?? "") }
        return (lhs.sourceLanguage?.rawValue ?? "") < (rhs.sourceLanguage?.rawValue ?? "")
    }
}
