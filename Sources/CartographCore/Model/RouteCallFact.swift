/// 클라이언트 코드가 HTTP 요청을 만든 곳 하나(교환 형식의 `route-call`).
///
/// isthmus 가 서버 선언·스펙 operation 과 (동사, 정규 경로 템플릿)으로 조인한다. 여기서는
/// 판정하지 않는다. 경로를 정적으로 확정하지 못한 호출도 버리지 않고 `isDynamic` 으로 남긴다 —
/// 소비자가 그 수를 호출 측 공백으로 세야 "호출 없음"과 "못 봤음"을 가를 수 있다.
public struct RouteCallFact: Hashable, Sendable {
    /// 계약 동사. nil 이면 동사가 정적으로 확정되지 않았다(`methodDynamic`).
    public let method: String?
    /// 정규 경로 템플릿. dynamic 이면 원문 식(가린 뒤)이거나 nil.
    public let channel: String?
    public let isDynamic: Bool
    /// dynamic 호출에서 증명한 리터럴 접두사 템플릿.
    public let channelPrefix: String?
    public let pathAnchor: HTTPPathAnchor
    public let authority: String?
    public let service: String?
    public let queryTailStripped: Bool
    /// 가린 세그먼트 수. 없으면 0 이며 문서에는 싣지 않는다.
    public let maskedSegments: Int
    /// `--include-tests` 로 읽은 테스트 소스의 호출인지.
    public let isTestSource: Bool
    /// 이 문서에서 한계로 세야 하는 결합 문제(`ambiguous-base-join:`)가 있으면 그 접두사.
    public let limitation: String?
    /// 호출식이 시작하는 위치. 열은 UTF-8 바이트 기준이다.
    public let location: SourceLocation
    /// 호출을 감싸는 선언. 인덱스에서 찾았으면 USR 이 있다.
    public let symbol: BridgeFact.Symbol?

    public init(
        method: String?, channel: String?, isDynamic: Bool, channelPrefix: String? = nil,
        pathAnchor: HTTPPathAnchor, authority: String? = nil, service: String? = nil,
        queryTailStripped: Bool = false, maskedSegments: Int = 0, isTestSource: Bool = false,
        limitation: String? = nil, location: SourceLocation, symbol: BridgeFact.Symbol? = nil
    ) {
        self.method = method
        self.channel = channel
        self.isDynamic = isDynamic
        self.channelPrefix = channelPrefix
        self.pathAnchor = pathAnchor
        self.authority = authority
        self.service = service
        self.queryTailStripped = queryTailStripped
        self.maskedSegments = maskedSegments
        self.isTestSource = isTestSource
        self.limitation = limitation
        self.location = location
        self.symbol = symbol
    }

    /// 조립 결과에서 사실을 만든다. dynamic 원문은 호출자가 가린 뒤 넘긴다.
    public init(
        resolution: HTTPRouteResolution, method: String?, dynamicText: String?,
        service: String?, isTestSource: Bool, location: SourceLocation
    ) {
        self.init(
            method: method, channel: resolution.template ?? dynamicText, isDynamic: resolution.isDynamic,
            channelPrefix: resolution.channelPrefix, pathAnchor: resolution.pathAnchor,
            authority: resolution.authority, service: service,
            queryTailStripped: resolution.queryTailStripped, maskedSegments: resolution.maskedSegments,
            isTestSource: isTestSource, limitation: resolution.limitation, location: location
        )
    }

    /// 같은 사실에 선언 정보만 붙인 사본.
    public func attaching(_ symbol: BridgeFact.Symbol?) -> RouteCallFact {
        RouteCallFact(
            method: method, channel: channel, isDynamic: isDynamic, channelPrefix: channelPrefix,
            pathAnchor: pathAnchor, authority: authority, service: service,
            queryTailStripped: queryTailStripped, maskedSegments: maskedSegments,
            isTestSource: isTestSource, limitation: limitation, location: location, symbol: symbol
        )
    }
}

extension RouteCallFact: Comparable {
    /// 위치 순, 같은 위치면 템플릿·동사 순. 두 실행의 출력을 diff 할 수 있어야 한다.
    public static func < (lhs: RouteCallFact, rhs: RouteCallFact) -> Bool {
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        if lhs.channel != rhs.channel { return (lhs.channel ?? "") < (rhs.channel ?? "") }
        if lhs.method != rhs.method { return (lhs.method ?? "") < (rhs.method ?? "") }
        if lhs.pathAnchor != rhs.pathAnchor { return lhs.pathAnchor.rawValue < rhs.pathAnchor.rawValue }
        return (lhs.symbol?.usr ?? lhs.symbol?.qualifiedName ?? "") < (rhs.symbol?.usr ?? rhs.symbol?.qualifiedName ?? "")
    }
}
