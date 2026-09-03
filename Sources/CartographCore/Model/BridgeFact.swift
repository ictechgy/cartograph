/// 언어 경계(브리지)에서 이 도구가 Swift 쪽에서 본 사실 하나.
///
/// isthmus 가 Dart·JS·Kotlin 쪽 사실과 조인해 "이 Swift 핸들러를 Dart 가 부른다"를
/// 만든다. 그래서 여기서는 **판정하지 않는다.** 리터럴이 아닌 이름도 버리지 않고
/// `isDynamic` 으로 표시한다. isthmus 가 조인하지 못한 사실을 한계로 세는 데 필요하다.
///
/// 교환 형식(`../isthmus/docs/GRAPH-EXCHANGE.md` 초안 0)의 직렬화 모양은 이 타입이
/// 아니라 `CartographKit` 의 문서 타입이 정한다. 여기서는 스캐너가 알아낸 것을 그대로 담는다.
public struct BridgeFact: Hashable, Sendable {
    /// 사실의 종류. 교환 형식의 `kind` 값 그대로다.
    public enum Kind: String, Sendable, CaseIterable {
        /// 채널에 핸들러를 달았다(`setMethodCallHandler`, `addMethodCallDelegate`).
        ///
        /// 채널 객체를 만들기만 한 것은 사실이 아니다. 계약이 그렇게 정했고, 채널 이름은
        /// 생성자에서 등록 호출로 변수 참조를 따라 옮긴다.
        case channelRegister = "channel-register"
        /// 핸들러 안에서 메서드 이름으로 분기했다(`case "…"`) 또는 네이티브 메서드를 내보냈다.
        case methodHandle = "method-handle"
        /// React Native 모듈을 내보냈다(`@objc(Name)`, `RCT_EXPORT_MODULE`).
        case moduleExport = "module-export"
        /// React Native 뷰 매니저를 내보냈다(`RCT_EXPORT_VIEW_PROPERTY`).
        case componentExport = "component-export"
    }

    /// 이 사실이 어느 브리지 메커니즘에 속하는지.
    public enum Target: String, Sendable, CaseIterable {
        case flutter
        case reactNative = "react-native"
    }

    /// 이 사실을 담고 있는 선언. 인덱스에서 찾았으면 USR 이 있다.
    ///
    /// 클로저 안의 `case "…"` 는 자기 USR 이 없다. 그때는 감싸는 함수나 타입을 적는다.
    /// isthmus 가 돌려주는 보존 근거가 이 USR 을 가리킨다.
    public struct Symbol: Hashable, Sendable {
        public let qualifiedName: String
        public let usr: String?

        public init(qualifiedName: String, usr: String?) {
            self.qualifiedName = qualifiedName
            self.usr = usr
        }
    }

    public let kind: Kind
    public let target: Target
    /// 채널 이름 또는 모듈 이름. 알 수 없으면 nil, 리터럴이 아니면 원문 표현식.
    public let channel: String?
    /// `method-handle` 에만 있는 메서드 이름.
    public let method: String?
    /// 채널이나 메서드가 리터럴이 아니라 표현식이었는지 여부.
    public let isDynamic: Bool
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
        isChannelInferred: Bool = false,
        location: SourceLocation,
        symbol: Symbol? = nil
    ) {
        self.kind = kind
        self.target = target
        self.channel = channel
        self.method = method
        self.isDynamic = isDynamic
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
            isChannelInferred: isChannelInferred,
            location: location,
            symbol: symbol
        )
    }
}

extension BridgeFact: Comparable {
    /// 위치 순, 같은 위치면 종류·채널·메서드 순. 출력을 diff 할 수 있어야 한다.
    public static func < (lhs: BridgeFact, rhs: BridgeFact) -> Bool {
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.channel != rhs.channel { return (lhs.channel ?? "") < (rhs.channel ?? "") }
        return (lhs.method ?? "") < (rhs.method ?? "")
    }
}
