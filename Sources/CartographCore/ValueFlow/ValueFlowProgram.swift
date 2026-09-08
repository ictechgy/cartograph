import Foundation

/// 값 관계는 심볼 의존 간선과 분리해 보관한다. 숫자 ID는 함수 안에서만 유일하다.
public struct ValueFlowInstruction: Hashable, Sendable, Codable {
    public let id: Int
    public var operation: ValueFlowOperation
    public let location: SourceLocation

    /// 함수 내부의 안정적인 명령 번호로 간선의 양 끝을 연결한다.
    public init(id: Int, operation: ValueFlowOperation, location: SourceLocation) {
        self.id = id
        self.operation = operation
        self.location = location
    }
}

/// 컴파일러 참조를 대조할 자리. 이름만으로 다른 함수의 요약을 적용하지 않게 한다.
public struct ValueFlowSymbolReference: Hashable, Sendable, Codable {
    public let location: SourceLocation
    public let spelling: String
    public var usr: String?
    public var kind: SymbolKind?

    /// 컴파일러 식별자를 붙이기 전후에도 동일한 소스 발생을 가리킨다.
    public init(location: SourceLocation, spelling: String, usr: String? = nil, kind: SymbolKind? = nil) {
        self.location = location
        self.spelling = spelling
        self.usr = usr
        self.kind = kind
    }
}

/// 스칼라와 포인터/함수 값의 이름 공간을 분리해 같은 문자열을 같은 값으로 오인하지 않는다.
public enum ValueFlowLiteral: Hashable, Sendable, Codable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null
    case unit
}

/// 함수 본문을 평평한 값 노드로 낮춘다. 피연산자는 같은 함수의 노드 ID다.
public enum ValueFlowOperation: Hashable, Sendable, Codable {
    case literal(ValueFlowLiteral)
    case stringLiteral(String, expectedType: String?, inferred: Bool)
    /// 미확인 연산자는 피연산자의 주소와 공유 상태만 변경할 수 있다.
    case operatorApplication(String, inputs: [Int])
    case parameter(Int)
    case receiver
    case capture(Int)
    case local(name: String, initial: Int?, mutable: Bool)
    case read(address: Int)
    case write(address: Int, value: Int)
    case symbol(ValueFlowSymbolReference)
    case member(base: Int, symbol: ValueFlowSymbolReference)
    case closure(function: String, captures: [Int])
    case call(callee: Int, arguments: [Int], argumentLabels: [String], isAwait: Bool)
    /// 해석하지 못한 식도 입력/변경 가능성을 버리지 않고 그래프에 남긴다.
    case unknown(reason: String, inputs: [Int], mayWrite: Bool)
    case copy(Int)
}

/// 제어 흐름을 합칠 때 조건을 모르면 양쪽 가능성을 보존한다.
public enum ValueFlowTerminator: Hashable, Sendable, Codable {
    case `return`(Int?)
    case jump(Int)
    case branch(condition: Int, then: Int, otherwise: Int)
    case stop(reason: String)
}

/// 루프와 분기를 재귀 AST 순회가 아닌 작업 목록으로 평가할 수 있는 블록.
public struct ValueFlowBlock: Hashable, Sendable, Codable {
    public let id: Int
    public var instructions: [ValueFlowInstruction]
    public var terminator: ValueFlowTerminator

    /// 정상 반환과 분기 합류를 명령 순서와 구분해 보관한다.
    public init(id: Int, instructions: [ValueFlowInstruction] = [], terminator: ValueFlowTerminator) {
        self.id = id
        self.instructions = instructions
        self.terminator = terminator
    }
}

/// 인자 순서와 inout 여부를 보존해야 호출마다 요약을 올바르게 적용할 수 있다.
public struct ValueFlowParameter: Hashable, Sendable, Codable {
    public let name: String
    public let label: String
    public let isInout: Bool
    public let isFunction: Bool
    public let declaredType: String?

    /// 인자 위치와 inout 여부를 호출 문맥에 그대로 적용한다.
    public init(name: String, label: String = "", isInout: Bool = false, isFunction: Bool = false,
                declaredType: String? = nil) {
        self.name = name
        self.label = label
        self.isInout = isInout
        self.isFunction = isFunction
        self.declaredType = declaredType
    }
}

/// 클로저의 구문 ID는 심볼 USR인 척하지 않는다. 실제 선언만 선택적 USR을 가진다.
public struct ValueFlowFunction: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case function, initializer, getter, setter, closure, global }
    public let id: String
    public var symbolUSR: String?
    public let name: String
    public let indexName: String
    public let location: SourceLocation
    public let kind: Kind
    public let parameters: [ValueFlowParameter]
    public let returnType: String?
    public var blocks: [ValueFlowBlock]
    public let entry: Int
    public let ownerType: String?
    public let isStatic: Bool
    public let isEntryPoint: Bool
    public let mayBeCalledExternally: Bool
    public var unavailableReason: String?

    /// 컴파일러 선언과 구문 본문을 별도로 보존해 미상 결합을 표현한다.
    public init(id: String, symbolUSR: String? = nil, name: String, indexName: String,
                location: SourceLocation, kind: Kind = .function, parameters: [ValueFlowParameter] = [],
                blocks: [ValueFlowBlock], entry: Int = 0, ownerType: String? = nil, isStatic: Bool = false,
                isEntryPoint: Bool = false, mayBeCalledExternally: Bool = false, unavailableReason: String? = nil,
                returnType: String? = nil) {
        self.id = id
        self.symbolUSR = symbolUSR
        self.name = name
        self.indexName = indexName
        self.location = location
        self.kind = kind
        self.parameters = parameters
        self.returnType = returnType
        self.blocks = blocks
        self.entry = entry
        self.ownerType = ownerType
        self.isStatic = isStatic
        self.isEntryPoint = isEntryPoint
        self.mayBeCalledExternally = mayBeCalledExternally
        self.unavailableReason = unavailableReason
    }


}

/// 필드의 실제 선언과 초기화/접근자 요약을 연결한다.
public struct ValueFlowField: Hashable, Sendable, Codable {
    public let id: String
    public var symbolUSR: String?
    public let name: String
    public let location: SourceLocation
    public let declaredType: String?
    public let ownerType: String?
    public let isStatic: Bool
    public let isMutable: Bool
    public let initializer: String?
    public let getter: String?
    public let setter: String?
    public let hasUnknownObservers: Bool

    /// 저장소와 접근자 요약을 같은 필드 식별자로 연결한다.
    public init(id: String, symbolUSR: String? = nil, name: String, location: SourceLocation,
                declaredType: String? = nil, ownerType: String? = nil, isStatic: Bool = false, isMutable: Bool = false,
                initializer: String? = nil, getter: String? = nil, setter: String? = nil,
                hasUnknownObservers: Bool = false) {
        self.id = id
        self.symbolUSR = symbolUSR
        self.name = name
        self.location = location
        self.declaredType = declaredType
        self.ownerType = ownerType
        self.isStatic = isStatic
        self.isMutable = isMutable
        self.initializer = initializer
        self.getter = getter
        self.setter = setter
        self.hasUnknownObservers = hasUnknownObservers
    }


}

/// 참조형 객체의 할당 종류를 보관한다. 값 타입 복사를 참조 별칭으로 해석하지 않는다.
public struct ValueFlowType: Hashable, Sendable, Codable {
    public let id: String
    public var symbolUSR: String?
    public let name: String
    public let location: SourceLocation
    public let isReferenceType: Bool
    public let isFinal: Bool
    public let hasExternalBase: Bool
    public let isExtension: Bool
    public let unavailableReason: String?

    /// 생성자 분석에서 참조형과 미지원 타입을 구별한다.
    public init(id: String, symbolUSR: String? = nil, name: String, location: SourceLocation,
                isReferenceType: Bool = false, isFinal: Bool = false, hasExternalBase: Bool = false,
                isExtension: Bool = false, unavailableReason: String? = nil) {
        self.id = id
        self.symbolUSR = symbolUSR
        self.name = name
        self.location = location
        self.isReferenceType = isReferenceType
        self.isFinal = isFinal
        self.hasExternalBase = hasExternalBase
        self.isExtension = isExtension
        self.unavailableReason = unavailableReason
    }
}

/// 인덱스가 확인한 오버라이드/증인만 수신자 타입별 호출 후보로 삼는다.
public struct ValueFlowDispatch: Hashable, Sendable, Codable {
    public let requirementUSR: String
    public let implementation: String
    public let ownerType: String

    /// 구현의 source-local ID를 실제 요구사항 USR에 연결한다.
    public init(requirementUSR: String, implementation: String, ownerType: String) {
        self.requirementUSR = requirementUSR
        self.implementation = implementation
        self.ownerType = ownerType
    }
}

/// 순수 분석 입력. Syntax가 본문을 낮추고 Kit가 인덱스의 실제 USR을 붙인다.
public struct ValueFlowProgram: Sendable, Codable {
    public var functions: [ValueFlowFunction]
    public var fields: [ValueFlowField]
    public var types: [ValueFlowType]
    public var dispatch: [ValueFlowDispatch]
    public var limitations: [String]

    /// 한 분석에 필요한 본문과 인덱스 결합 결과를 값으로 고정한다.
    public init(functions: [ValueFlowFunction] = [], fields: [ValueFlowField] = [], types: [ValueFlowType] = [],
                dispatch: [ValueFlowDispatch] = [], limitations: [String] = []) {
        self.functions = functions
        self.fields = fields
        self.types = types
        self.dispatch = dispatch
        self.limitations = limitations
    }
}
