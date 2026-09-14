/// 컴파일러의 일반 호출 간선만으로 설명되지 않는 경계를 분류한다.
public enum RuntimeBoundaryKind: String, Codable, Sendable, CaseIterable {
    case classLookup, protocolLookup, selectorLookup, selectorReference
    case selectorInvocation, selectorRegistration
    case notificationPost, notificationObserver, notificationSubscription
    case coreDataEntityClass, coreDataContainer, coreDataFetch
    case keyValueRead, keyValueWrite, keyPathRead, keyPathWrite
    case interfaceBuilderClass, interfaceBuilderAction, interfaceBuilderOutlet
    case bridgeHandler
    case registryEntry, registryLookup, registryAlias
}

/// 이름을 알아낸 방법과 아직 계산하지 못한 값을 구분한다.
public enum RuntimeNameOrigin: String, Codable, Sendable {
    case literal, constant, selector, dynamic, resource, bridge
}

/// KVC와 predicate가 공유하는 제한된 점 구분 property 경로 문법이다.
public enum RuntimeKeyPath {
    /// SELF 접두사를 제외한 최대 16개의 ASCII Swift 식별자만 경로로 인정한다.
    public static func components(of path: String) -> [String]? {
        guard path.utf8.count <= 512 else { return nil }
        var components = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if components.first?.uppercased() == "SELF" { components.removeFirst() }
        guard !components.isEmpty, components.count <= 16,
              components.allSatisfy({ component in
                  guard let first = component.first, isIdentifierStart(first) else { return false }
                  return component.allSatisfy(isIdentifierContinuation)
              }) else { return nil }
        return components
    }

    private static func isIdentifierStart(_ value: Character) -> Bool {
        value.isASCII && (value.isLetter || value == "_")
    }

    private static func isIdentifierContinuation(_ value: Character) -> Bool {
        isIdentifierStart(value) || value.isASCII && value.isNumber
    }
}

/// 사용자가 선언한 계약, 자동 정적 발견, 실행 관측을 서로 다른 근거로 보존한다.
public enum RuntimeEvidenceOrigin: String, Codable, Sendable {
    case declared, automatic, observed
}

/// 큰 실행 기록을 영향 경로마다 복사하지 않고 원래 근거를 가리킨다.
public struct RuntimeEvidenceReference: Codable, Sendable, Hashable {
    public let id: String
    public let origin: RuntimeEvidenceOrigin
    public let kind: RuntimeBoundaryKind?

    public init(id: String, origin: RuntimeEvidenceOrigin, kind: RuntimeBoundaryKind? = nil) {
        self.id = id
        self.origin = origin
        self.kind = kind
    }
}

/// 수신자 타입의 구문 근거. 실제 심볼 신원은 인덱스와 따로 대조한다.
public enum RuntimeReceiverOrigin: String, Codable, Sendable {
    case enclosingType, annotation, construction, explicitTarget, unknown
}

/// 상수 값을 해석할 때 사용한 생성자도 실제 시스템 API인지 확인할 수 있게 한다.
public struct RuntimeNameAPIReference: Codable, Sendable, Equatable, Hashable {
    public let api: String
    public let location: SourceLocation

    public init(api: String, location: SourceLocation) {
        self.api = api
        self.location = location
    }
}

/// publisher 생성과 실제 소비 연산을 구분할 컴파일러 위치 증거다.
public struct RuntimeSubscriptionConsumerReference: Codable, Sendable, Equatable, Hashable {
    public let api: String
    public let location: SourceLocation

    public init(api: String, location: SourceLocation) {
        self.api = api
        self.location = location
    }
}

/// 지역 observer token 제거가 등록과 게시 사이에 있었는지 compiler 위치로 검증한다.
public struct RuntimeNotificationRemovalReference: Codable, Sendable, Equatable, Hashable {
    public let registrationLocation: SourceLocation
    public let removalLocation: SourceLocation
    public let notificationCenterLocation: SourceLocation
    public let notificationCenterOwnerLocation: SourceLocation?

    /// 제거 API와 같은 센터를 compiler reference로 다시 확인할 위치 묶음을 만든다.
    public init(
        registrationLocation: SourceLocation,
        removalLocation: SourceLocation,
        notificationCenterLocation: SourceLocation,
        notificationCenterOwnerLocation: SourceLocation? = nil
    ) {
        self.registrationLocation = registrationLocation
        self.removalLocation = removalLocation
        self.notificationCenterLocation = notificationCenterLocation
        self.notificationCenterOwnerLocation = notificationCenterOwnerLocation
    }
}

/// 직접 Combine 구독 token 취소를 등록 위치와 exact compiler call 위치로 보존한다.
public struct RuntimeNotificationCancellationReference: Codable, Sendable, Equatable, Hashable {
    public let registrationLocation: SourceLocation
    public let cancellationLocation: SourceLocation

    /// 구독 생성과 취소 호출의 순서를 compiler reference로 다시 확인할 위치를 만든다.
    public init(registrationLocation: SourceLocation, cancellationLocation: SourceLocation) {
        self.registrationLocation = registrationLocation
        self.cancellationLocation = cancellationLocation
    }
}

/// 구문 스캐너가 관찰한 경계 하나. 이 값 자체는 실행이나 연결 성공을 뜻하지 않는다.
public struct RuntimeBoundary: Codable, Sendable, Equatable, Hashable {
    public let kind: RuntimeBoundaryKind
    public let api: String
    public let location: SourceLocation
    /// 시스템 API와 동명 사용자 함수를 구분할 컴파일러 참조의 정확한 위치.
    public let calleeLocation: SourceLocation?
    public let enclosingDeclarationLocation: SourceLocation?
    public let name: String?
    public let nameOrigin: RuntimeNameOrigin
    public let receiverTypeName: String?
    public let receiverOrigin: RuntimeReceiverOrigin
    public let receiverTypeLocation: SourceLocation?
    /// #selector의 Swift 선언 참조. 문자열 selector 이름을 추측하는 데 쓰지 않는다.
    public let referencedTargetLocation: SourceLocation?
    public let targetMemberName: String?
    /// 리소스에서 객체 소유자를 구분하거나 브리지의 정확한 핸들러를 보존한다.
    public let targetUSR: String?
    public let resourceObjectID: String?
    public let coreDataCodeGeneration: String?
    /// 실제 앱 번들에서 검증한 모델 이름이며 소스 경로의 basename 추측이 아니다.
    public let coreDataModelName: String?
    /// 기본 fetch가 포함하는 하위 엔티티의 클래스도 영향 경로에 남긴다.
    public let coreDataSuperentityName: String?
    /// 모델 선택에 사용한 생성자·context·request의 정확한 compiler 위치다.
    public let coreDataContainerLocation: SourceLocation?
    public let coreDataContextLocation: SourceLocation?
    public let coreDataRequestLocation: SourceLocation?
    public let coreDataResultTypeLocation: SourceLocation?
    /// 불변 사전 선언과 그 사전을 참조한 위치를 이름 매칭 없이 결합한다.
    public let registryDeclarationLocation: SourceLocation?
    public let registryReferenceLocation: SourceLocation?
    public let notificationName: String?
    public let notificationNameLocation: SourceLocation?
    public let notificationCenterLocation: SourceLocation?
    public let notificationCenterOwnerLocation: SourceLocation?
    public let notificationObjectIsNil: Bool?
    public let notificationObjectLocation: SourceLocation?
    public let notificationRemovalReferences: [RuntimeNotificationRemovalReference]?
    public let notificationCancellationReferences: [RuntimeNotificationCancellationReference]?
    public let keyPaths: [String]?
    public let nameAPIReferences: [RuntimeNameAPIReference]?
    public let subscriptionConsumer: RuntimeSubscriptionConsumerReference?
    public let reason: String?

    /// 모든 출처가 같은 경계 모델을 쓰되 알 수 없는 신원을 nil로 남긴다.
    public init(
        kind: RuntimeBoundaryKind, api: String, location: SourceLocation,
        calleeLocation: SourceLocation? = nil, enclosingDeclarationLocation: SourceLocation? = nil,
        name: String? = nil, nameOrigin: RuntimeNameOrigin = .dynamic,
        receiverTypeName: String? = nil, receiverOrigin: RuntimeReceiverOrigin = .unknown,
        receiverTypeLocation: SourceLocation? = nil, referencedTargetLocation: SourceLocation? = nil,
        targetMemberName: String? = nil, targetUSR: String? = nil,
        resourceObjectID: String? = nil, coreDataCodeGeneration: String? = nil,
        coreDataModelName: String? = nil,
        coreDataSuperentityName: String? = nil,
        coreDataContainerLocation: SourceLocation? = nil, coreDataContextLocation: SourceLocation? = nil,
        coreDataRequestLocation: SourceLocation? = nil, coreDataResultTypeLocation: SourceLocation? = nil,
        registryDeclarationLocation: SourceLocation? = nil, registryReferenceLocation: SourceLocation? = nil,
        notificationName: String? = nil,
        notificationNameLocation: SourceLocation? = nil, notificationCenterLocation: SourceLocation? = nil,
        notificationCenterOwnerLocation: SourceLocation? = nil,
        notificationObjectIsNil: Bool? = nil, notificationObjectLocation: SourceLocation? = nil,
        notificationRemovalReferences: [RuntimeNotificationRemovalReference]? = nil,
        notificationCancellationReferences: [RuntimeNotificationCancellationReference]? = nil,
        keyPaths: [String]? = nil,
        nameAPIReferences: [RuntimeNameAPIReference]? = nil,
        subscriptionConsumer: RuntimeSubscriptionConsumerReference? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.api = api
        self.location = location
        self.calleeLocation = calleeLocation
        self.enclosingDeclarationLocation = enclosingDeclarationLocation
        self.name = name
        self.nameOrigin = nameOrigin
        self.receiverTypeName = receiverTypeName
        self.receiverOrigin = receiverOrigin
        self.receiverTypeLocation = receiverTypeLocation
        self.referencedTargetLocation = referencedTargetLocation
        self.targetMemberName = targetMemberName
        self.targetUSR = targetUSR
        self.resourceObjectID = resourceObjectID
        self.coreDataCodeGeneration = coreDataCodeGeneration
        self.coreDataModelName = coreDataModelName
        self.coreDataSuperentityName = coreDataSuperentityName
        self.coreDataContainerLocation = coreDataContainerLocation
        self.coreDataContextLocation = coreDataContextLocation
        self.coreDataRequestLocation = coreDataRequestLocation
        self.coreDataResultTypeLocation = coreDataResultTypeLocation
        self.registryDeclarationLocation = registryDeclarationLocation
        self.registryReferenceLocation = registryReferenceLocation
        self.notificationName = notificationName
        self.notificationNameLocation = notificationNameLocation
        self.notificationCenterLocation = notificationCenterLocation
        self.notificationCenterOwnerLocation = notificationCenterOwnerLocation
        self.notificationObjectIsNil = notificationObjectIsNil
        self.notificationObjectLocation = notificationObjectLocation
        self.notificationRemovalReferences = notificationRemovalReferences
        self.notificationCancellationReferences = notificationCancellationReferences
        self.keyPaths = keyPaths
        self.nameAPIReferences = nameAPIReferences
        self.subscriptionConsumer = subscriptionConsumer
        self.reason = reason
    }

    /// 경계 위치와 종류로 안정적인 출처 키를 만든다. 이름이나 경로의 구분자 충돌을 피한다.
    public var id: String {
        [location.path, String(location.line), String(location.column), kind.rawValue, api]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// Objective-C 노출명과 정확한 선언 위치를 보존해 가까운 동명 선언으로 잘못 결합하지 않는다.
public struct RuntimeDeclaration: Codable, Sendable, Equatable, Hashable {
    public let name: String
    public let indexName: String
    public let qualifiedName: String
    public let kind: SymbolKind
    public let location: SourceLocation
    public let endLocation: SourceLocation
    public let parentLocation: SourceLocation?
    public let objectiveCName: String?
    public let attributes: [SymbolAttribute]
    public let isTypeMember: Bool
    public let isStatic: Bool
    public let isImmutable: Bool
    public let isSettable: Bool
    public let isFinal: Bool
    public let valueTypeName: String?
    public let valueTypeLocation: SourceLocation?

    private enum CodingKeys: String, CodingKey {
        case name, indexName, qualifiedName, kind, location, endLocation, parentLocation
        case objectiveCName, attributes, isTypeMember, isStatic, isImmutable, isSettable, isFinal
        case valueTypeName, valueTypeLocation
    }

    /// 이름 추론과 컴파일러 신원 대조를 분리할 선언 사실을 만든다.
    public init(
        name: String, indexName: String, qualifiedName: String, kind: SymbolKind,
        location: SourceLocation, endLocation: SourceLocation, parentLocation: SourceLocation? = nil,
        objectiveCName: String? = nil, attributes: Set<SymbolAttribute> = [],
        isTypeMember: Bool = false, isStatic: Bool = false, isImmutable: Bool = false,
        isSettable: Bool = false, isFinal: Bool = false,
        valueTypeName: String? = nil, valueTypeLocation: SourceLocation? = nil
    ) {
        self.name = name
        self.indexName = indexName
        self.qualifiedName = qualifiedName
        self.kind = kind
        self.location = location
        self.endLocation = endLocation
        self.parentLocation = parentLocation
        self.objectiveCName = objectiveCName
        self.attributes = attributes.sorted { $0.rawValue < $1.rawValue }
        self.isTypeMember = isTypeMember
        self.isStatic = isStatic
        self.isImmutable = isImmutable
        self.isSettable = isSettable
        self.isFinal = isFinal
        self.valueTypeName = valueTypeName
        self.valueTypeLocation = valueTypeLocation
    }

    /// 이전 v2 스냅샷에 없던 보수적 선언 증거는 거짓으로 복원한다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        indexName = try container.decode(String.self, forKey: .indexName)
        qualifiedName = try container.decode(String.self, forKey: .qualifiedName)
        kind = try container.decode(SymbolKind.self, forKey: .kind)
        location = try container.decode(SourceLocation.self, forKey: .location)
        endLocation = try container.decode(SourceLocation.self, forKey: .endLocation)
        parentLocation = try container.decodeIfPresent(SourceLocation.self, forKey: .parentLocation)
        objectiveCName = try container.decodeIfPresent(String.self, forKey: .objectiveCName)
        attributes = try container.decodeIfPresent([SymbolAttribute].self, forKey: .attributes) ?? []
        isTypeMember = try container.decodeIfPresent(Bool.self, forKey: .isTypeMember) ?? false
        isStatic = try container.decodeIfPresent(Bool.self, forKey: .isStatic) ?? false
        isImmutable = try container.decodeIfPresent(Bool.self, forKey: .isImmutable) ?? false
        isSettable = try container.decodeIfPresent(Bool.self, forKey: .isSettable) ?? false
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
        valueTypeName = try container.decodeIfPresent(String.self, forKey: .valueTypeName)
        valueTypeLocation = try container.decodeIfPresent(SourceLocation.self, forKey: .valueTypeLocation)
    }
}

/// 소스나 리소스 한 개의 자동 발견 입력. 캐시와 과거 스냅샷에서도 같은 사실을 재사용한다.
public struct RuntimeFileFacts: Codable, Sendable, Equatable {
    public let path: String
    public let declarations: [RuntimeDeclaration]
    public let boundaries: [RuntimeBoundary]
    public let limitations: [String]

    /// 아무 경계도 없었던 파일과 아직 스캔하지 않은 파일을 구분한다.
    public init(path: String, declarations: [RuntimeDeclaration] = [],
                boundaries: [RuntimeBoundary] = [], limitations: [String] = []) {
        self.path = path
        self.declarations = declarations
        self.boundaries = boundaries
        self.limitations = limitations
    }
}
