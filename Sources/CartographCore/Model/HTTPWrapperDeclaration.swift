/// 사용자가 선언한 HTTP 래퍼 하나(`http-wrappers` v1/v2, `../isthmus/docs/HTTP-WRAPPERS.md`).
///
/// 앱은 HTTP 라이브러리를 직접 부르지 않고 자체 래퍼를 거친다. 어느 인자가 경로이고 어느
/// 인자가 동사인지는 소스만 보고 일반적으로 추측할 수 없으므로 사용자가 선언하고, 생산자는
/// 선언과 일치하는 호출을 route-call 로 낸다. 파일 파싱은 입출력이라 `CartographKit` 이 맡는다.
public struct HTTPWrapperDeclaration: Hashable, Sendable {
    /// 래퍼 종류. 생성자면 이름이 Swift 의 `init` 이다.
    public enum Kind: String, Hashable, Sendable {
        case constructor
        case function
    }

    /// 인자 하나를 가리키는 방법. 레이블을 먼저 찾고, 없으면 위치로 찾는다.
    public struct ArgumentBinding: Hashable, Sendable {
        public let index: Int?
        public let label: String?

        public init(index: Int? = nil, label: String? = nil) {
            self.index = index
            self.label = label
        }
    }

    /// v2 래퍼가 기본 경로 뒤에 붙이는 segment 선언이다.
    public enum PathSuffix: Hashable, Sendable {
        /// 파일에 적힌 decoded segment 하나. 슬래시와 퍼센트 표기도 segment 원문이다.
        case literal(String)
        /// 호출 인자가 제공하는 segment. scalar는 정확히 하나, array는 배열 원소마다 하나다.
        case argument(ArgumentBinding, shape: ArgumentShape)

        /// 인자 값이 선언하는 segment 개수의 모양이다.
        public enum ArgumentShape: String, Hashable, Sendable {
            /// 런타임 값이어도 segment 하나라는 모델 선언이므로 빈 hole로 보존할 수 있다.
            case scalar
            /// 길이를 증명한 배열 리터럴만 원소별 segment로 펼친다.
            case array
        }
    }

    /// 한 wrapper가 선언할 수 있는 suffix 항목 수다.
    public static let maximumPathSuffixEntries = 32

    /// 호출 측 생산자 언어. 이 도구는 `swift` 선언만 쓴다.
    public let language: String
    public let kind: Kind
    /// 소유 타입(점으로 이은 이름) 또는 최상위 함수의 모듈 경로.
    public let owner: String
    public let name: String
    public let methodArg: ArgumentBinding?
    public let pathArg: ArgumentBinding
    public let defaultMethod: String?
    public let methodEnum: [String: String]
    public let pathAnchor: HTTPPathAnchor
    public let service: String?
    /// v2 경로 뒤에 선언 순서대로 붙일 segment 항목. v1은 항상 비어 있다.
    public let pathSuffix: [PathSuffix]

    public init(
        language: String, kind: Kind, owner: String, name: String,
        methodArg: ArgumentBinding?, pathArg: ArgumentBinding,
        defaultMethod: String? = nil, methodEnum: [String: String] = [:],
        pathAnchor: HTTPPathAnchor, service: String? = nil
    ) {
        self.init(
            language: language, kind: kind, owner: owner, name: name,
            methodArg: methodArg, pathArg: pathArg,
            defaultMethod: defaultMethod, methodEnum: methodEnum,
            pathAnchor: pathAnchor, service: service, pathSuffix: []
        )
    }

    /// v2 suffix를 요구하는 overload다. 기존 initializer 호출 시그니처와 suffix 없는 동작을 유지한다.
    public init(
        language: String, kind: Kind, owner: String, name: String,
        methodArg: ArgumentBinding?, pathArg: ArgumentBinding,
        defaultMethod: String? = nil, methodEnum: [String: String] = [:],
        pathAnchor: HTTPPathAnchor, service: String? = nil,
        pathSuffix: [PathSuffix]
    ) {
        self.language = language
        self.kind = kind
        self.owner = owner
        self.name = name
        self.methodArg = methodArg
        self.pathArg = pathArg
        self.defaultMethod = defaultMethod
        self.methodEnum = methodEnum
        self.pathAnchor = pathAnchor
        self.service = service
        self.pathSuffix = pathSuffix
    }

    /// 한계 문구에 쓰는 표기. 사용자가 선언한 이름뿐이라 경로·비밀을 담지 않는다.
    public var displayName: String { "\(owner).\(name)" }

    /// 소유 타입 이름의 구성 요소(`Network.Endpoint` → `["Network", "Endpoint"]`).
    public var ownerComponents: [String] {
        owner.split(separator: ".").map(String.init)
    }

    /// 점으로 이은 타입 사슬이 소유 타입을 가리키는지. 한쪽이 다른 쪽의 구성 요소 단위 접미사면 같다.
    ///
    /// 선언은 `Network.Endpoint` 처럼 모듈을 붙여 쓸 수 있고, 호출 지점은 `Endpoint(` 처럼 짧게
    /// 쓸 수 있다. 반대로 `Other.Endpoint` 처럼 다르게 한정된 이름은 같은 타입이 아니다.
    public func ownerMatches(_ chain: [String]) -> Bool {
        let owner = ownerComponents
        guard !chain.isEmpty, !owner.isEmpty else { return false }
        return owner.count >= chain.count ? Array(owner.suffix(chain.count)) == chain
            : Array(chain.suffix(owner.count)) == owner
    }
}

/// v2 wrapper suffix를 기존 main-path 해석 결과에 붙이는 순수 규칙이다.
public enum HTTPWrapperSuffixComposer {
    /// suffix 인자 하나를 펼친 segment다.
    public enum Segment: Hashable, Sendable {
        /// 퍼센트 인코딩 전 decoded segment.
        case literal(String)
        /// 값은 모르지만 모델이 segment 하나라고 보장한 자리.
        case value
    }

    /// Syntax 생산자가 증명한 전체 suffix 또는 적용할 수 없다는 사실이다.
    public enum Expansion: Hashable, Sendable {
        case segments([Segment])
        case dynamic
    }

    /// 한 호출에서 펼칠 수 있는 suffix segment 수다.
    public static let maximumExpandedSegments = 64

    /// main path의 query와 fragment 제거 상태를 보존하면서 suffix를 경로 끝에 붙인다.
    ///
    /// main path가 이미 dynamic이면 suffix로 정적으로 승격하지 않는다. suffix가 불확실하거나
    /// 확장 한도를 넘으면 기존 정적 main path만 channelPrefix로 남긴다.
    public static func append(_ expansion: Expansion, to base: HTTPRouteResolution) -> HTTPRouteResolution {
        guard let template = base.template else { return base }
        guard case let .segments(segments) = expansion,
              segments.count <= maximumExpandedSegments else {
            return dynamic(after: base, prefix: template)
        }
        guard !segments.isEmpty else { return base }
        var path = template
        for (index, segment) in segments.enumerated() {
            if index > 0 || !path.hasSuffix("/") { path += "/" }
            switch segment {
            case let .literal(text):
                guard let encoded = encodeSegment(text) else {
                    return dynamic(after: base, prefix: template)
                }
                path += encoded
            case .value:
                path += "{}"
            }
        }
        let masked = HTTPRouteTemplate.mask(path, authority: base.authority)
        guard HTTPRouteTemplate.validate(masked.template) == nil else {
            return dynamic(after: base, prefix: template)
        }
        return HTTPRouteResolution(
            template: masked.template,
            pathAnchor: base.pathAnchor,
            authority: base.authority,
            queryTailStripped: base.queryTailStripped,
            maskedSegments: base.maskedSegments + masked.maskedSegments,
            limitation: base.limitation
        )
    }

    private static func dynamic(after base: HTTPRouteResolution, prefix: String) -> HTTPRouteResolution {
        HTTPRouteResolution(
            template: nil,
            channelPrefix: prefix,
            pathAnchor: base.pathAnchor,
            authority: base.authority,
            queryTailStripped: base.queryTailStripped,
            maskedSegments: base.maskedSegments,
            limitation: base.limitation
        )
    }

    /// decoded 단일 segment를 RFC 3986 unreserved만 남기고 UTF-8 대문자 percent 형식으로 바꾼다.
    private static func encodeSegment(_ text: String) -> String? {
        guard !text.isEmpty, text != ".", text != "..",
              !text.unicodeScalars.contains(where: {
                $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
                    || (0xD800...0xDFFF).contains($0.value)
              }) else { return nil }
        return text.unicodeScalars.map { scalar in
            if HTTPRouteTemplate.isUnreserved(scalar) { return String(Character(scalar)) }
            return String(Character(scalar)).utf8.map { "%" + hexByte($0) }.joined()
        }
        .joined()
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}

/// 래퍼 호출의 인자 하나를 구문과 무관하게 적은 것. 공유 벡터와 스캐너가 같은 바인딩 규칙을 쓴다.
public struct HTTPWrapperCallArgument: Hashable, Sendable {
    /// 인자 값의 모양. 동사 판정에 필요한 만큼만 구분한다.
    public enum Value: Hashable, Sendable {
        /// 문자열 리터럴(같은 파일 상수를 치환한 것 포함).
        case literal(String)
        /// 열거형 case 나 상수 이름(`.get`, `HTTPMethod.get`).
        case enumCase(String)
        /// 그 밖의 식.
        case opaque
    }

    public let label: String?
    public let value: Value

    public init(label: String?, value: Value) {
        self.label = label
        self.value = value
    }
}

/// 동사와 인자 바인딩 규칙(`wrapper.*`).
public enum HTTPWrapperBinding {
    /// 선언의 바인딩으로 인자의 위치를 찾는다.
    ///
    /// 레이블이 있으면 같은 레이블을 먼저 찾는다. 없으면 `index` 위치의 인자를 쓰되, 그 인자가
    /// 다른 레이블을 달고 있으면 쓰지 않는다. 위치만 믿으면 기본값을 건너뛴 레이블 인자를
    /// 엉뚱한 자리의 인자로 읽는다.
    public static func argumentIndex(for binding: HTTPWrapperDeclaration.ArgumentBinding, labels: [String?]) -> Int? {
        if let label = binding.label, let found = labels.firstIndex(of: label) { return found }
        guard let index = binding.index, index < labels.count else { return nil }
        return labels[index] == nil || labels[index] == binding.label ? index : nil
    }

    /// 호출의 동사. nil 이면 `methodDynamic` 이다.
    ///
    /// 인자를 찾지 못하면 선언의 기본값을 쓴다. 인자가 있는데 리터럴·enum 이 아니면 기본값을 쓰지
    /// 않는다 — 기본값은 인자를 생략했을 때만의 사실이다. 문자열 리터럴은 계약 동사와 정확히
    /// 같을 때만 동사이고, enum 은 `methodEnum` 으로만 바꾼다.
    public static func method(for declaration: HTTPWrapperDeclaration, arguments: [HTTPWrapperCallArgument]) -> String? {
        guard let binding = declaration.methodArg,
              let index = argumentIndex(for: binding, labels: arguments.map(\.label)) else {
            return declaration.defaultMethod
        }
        let verb: String? = switch arguments[index].value {
        case let .literal(text): text
        case let .enumCase(name): declaration.methodEnum[name]
        case .opaque: nil
        }
        return verb.flatMap { HTTPRouteTemplate.methods.contains($0) ? $0 : nil }
    }
}
