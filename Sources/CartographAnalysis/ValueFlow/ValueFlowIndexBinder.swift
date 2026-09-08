import CartographCore

/// SwiftSyntax가 만든 소스별 값 흐름 프로그램에 인덱스의 USR을 붙인다.
///
/// 이름이나 가장 가까운 선언은 대조 근거로 사용하지 않는다. 선언은 정확한
/// 위치·종류·신선한 파일 증거로만, 본문 참조는 정확한 발생 위치의 인덱스 관계로만
/// 결합한다. 근거가 없으면 USR을 추정하지 않고 분석 불가 상태를 남긴다.
public struct ValueFlowIndexBinder: Sendable {
    /// 순수한 인덱스 결합기를 만든다.
    public init() {}

    /// 인덱스 증거를 값 흐름 프로그램에 결합한다.
    public func bind(
        program: ValueFlowProgram,
        snapshot: IndexSnapshot,
        freshPaths: Set<String>
    ) -> ValueFlowProgram {
        ValueFlowIndexBinding.bind(program: program, snapshot: snapshot, freshPaths: freshPaths)
    }
}

private enum ValueFlowIndexBinding {
    private static let unavailable = "value-flow binding unavailable: stale, missing, or ambiguous index evidence"

    private struct ReferenceSite: Hashable {
        let source: String
        let location: SourceLocation
    }

    private struct Evidence {
        let symbolsByUSR: [String: [IndexedSymbol]]
        let symbolsByLocation: [SourceLocation: [IndexedSymbol]]
        let symbolsByParent: [String: [IndexedSymbol]]
        let symbolsByPath: [String: [IndexedSymbol]]
        let extendsByLocation: [SourceLocation: [IndexedReference]]
        let referencesBySource: [String: [IndexedReference]]
        let referencesBySite: [ReferenceSite: [IndexedReference]]
        let freshPaths: Set<String>

        func isFresh(_ location: SourceLocation) -> Bool {
            freshPaths.contains(location.path)
        }

        func symbol(_ usr: String) -> IndexedSymbol? {
            guard let candidates = symbolsByUSR[usr], candidates.count == 1 else { return nil }
            return candidates[0]
        }
    }

    private struct FunctionBinding {
        var symbolUSR: String?
        var ownerUSR: String?
        var invalid = false
    }

    static func bind(
        program: ValueFlowProgram,
        snapshot: IndexSnapshot,
        freshPaths: Set<String>
    ) -> ValueFlowProgram {
        let extends: [(SourceLocation, IndexedReference)] = snapshot.references.compactMap { reference in
            guard reference.kind == .extends, let location = reference.location else { return nil }
            return (location, reference)
        }
        let locatedReferences = snapshot.references.compactMap { reference in
            reference.location.map { (ReferenceSite(source: reference.sourceUSR, location: $0), reference) }
        }
        let evidence = Evidence(
            symbolsByUSR: Dictionary(grouping: snapshot.symbols, by: \.usr),
            symbolsByLocation: Dictionary(grouping: snapshot.symbols, by: \.location),
            symbolsByParent: Dictionary(grouping: snapshot.symbols.compactMap { symbol in
                symbol.parentUSR.map { ($0, symbol) }
            }, by: \.0).mapValues { $0.map(\.1) },
            symbolsByPath: Dictionary(grouping: snapshot.symbols, by: { $0.location.path }),
            extendsByLocation: Dictionary(grouping: extends, by: { $0.0 }).mapValues { $0.map(\.1) },
            referencesBySource: Dictionary(grouping: snapshot.references, by: \.sourceUSR),
            referencesBySite: Dictionary(grouping: locatedReferences, by: \.0).mapValues { $0.map(\.1) },
            freshPaths: freshPaths
        )
        let typeBindings = bindTypes(program.types, evidence: evidence)
        let fieldBindings = bindFields(program.fields, typeBindings: typeBindings, evidence: evidence)
        let functionBindings = bindFunctions(
            program.functions,
            types: program.types,
            typeBindings: typeBindings,
            fields: program.fields,
            fieldBindings: fieldBindings,
            evidence: evidence
        )
        let referenceResult = bindReferences(
            program.functions,
            functionBindings: functionBindings,
            typeBindings: typeBindings,
            fields: program.fields,
            fieldBindings: fieldBindings,
            evidence: evidence
        )
        let dispatch = bindDispatch(
            program.functions,
            functionBindings: functionBindings,
            typeBindings: typeBindings,
            evidence: evidence
        )

        var limitations = Set(program.limitations)
        if !typeBindings.values.allSatisfy(\.isBound)
            || !fieldBindings.values.allSatisfy(\.isBound)
            || functionBindings.values.contains(where: { $0.invalid })
            || !referenceResult.invalidFunctions.isEmpty
            || referenceResult.hasInvalidReferences {
            limitations.insert(unavailable)
        }

        let functions = program.functions.map { function in
            var result = ValueFlowFunction(
                id: function.id,
                symbolUSR: function.symbolUSR,
                name: function.name,
                indexName: function.indexName,
                location: function.location,
                kind: function.kind,
                parameters: function.parameters,
                blocks: function.blocks,
                entry: function.entry,
                ownerType: function.ownerType.flatMap { typeBindings[$0]?.canonicalOwner },
                isStatic: function.isStatic,
                isEntryPoint: function.isEntryPoint,
                mayBeCalledExternally: function.mayBeCalledExternally,
                unavailableReason: function.unavailableReason
                    ?? function.ownerType.flatMap { typeBindings[$0]?.unavailableReason },
                returnType: function.returnType
            )
            if let binding = functionBindings[function.id] {
                result.symbolUSR = binding.symbolUSR
                if binding.invalid { result.unavailableReason = result.unavailableReason ?? unavailable }
            }
            if referenceResult.invalidFunctions.contains(function.id) {
                result.unavailableReason = result.unavailableReason ?? unavailable
            }
            result.blocks = function.blocks.map { block in
                ValueFlowBlock(
                    id: block.id,
                    instructions: block.instructions.map {
                        ValueFlowInstruction(
                            id: $0.id,
                            operation: referenceResult.operations[function.id]?[$0.id] ?? $0.operation,
                            location: $0.location
                        )
                    },
                    terminator: block.terminator
                )
            }
            return result
        }

        let fields = program.fields.map { field in
            if let binding = fieldBindings[field.id] {
                return ValueFlowField(
                    id: field.id,
                    symbolUSR: binding.symbolUSR,
                    name: field.name,
                    location: field.location,
                    declaredType: field.declaredType,
                    ownerType: binding.ownerType,
                    isStatic: field.isStatic,
                    isMutable: field.isMutable,
                    initializer: field.initializer,
                    getter: field.getter,
                    setter: field.setter,
                    hasUnknownObservers: field.hasUnknownObservers
                )
            }
            return field
        }

        let types = program.types.map { type in
            if let binding = typeBindings[type.id] {
                return ValueFlowType(
                    id: type.id,
                    symbolUSR: binding.symbolUSR,
                    name: type.name,
                    location: type.location,
                    isReferenceType: type.isReferenceType,
                    isFinal: type.isFinal,
                    hasExternalBase: type.hasExternalBase,
                    isExtension: type.isExtension,
                    unavailableReason: type.unavailableReason ?? binding.unavailableReason
                )
            }
            return type
        }

        let bound = ValueFlowProgram(
            functions: functions,
            fields: fields,
            types: types,
            dispatch: dispatch,
            limitations: limitations.sorted()
        )
        return ValueFlowLiteralBinder(program: bound, snapshot: snapshot, freshPaths: freshPaths).bind()
    }

    private struct TypeBinding {
        var symbolUSR: String?
        var canonicalOwner: String?
        var unavailableReason: String?

        var isBound: Bool { symbolUSR != nil }
    }

    private struct FieldBinding {
        var symbolUSR: String?
        var ownerType: String?
        var invalid: Bool

        var isBound: Bool { symbolUSR != nil && !invalid }
    }

    private struct ReferenceResult {
        var operations: [String: [Int: ValueFlowOperation]] = [:]
        var invalidFunctions: Set<String> = []
        var hasInvalidReferences = false
    }

    private static func bindTypes(
        _ types: [ValueFlowType],
        evidence: Evidence
    ) -> [String: TypeBinding] {
        var result: [String: TypeBinding] = [:]
        for type in types {
            guard !type.isExtension else { continue }
            let candidates = declarationCandidates(
                at: type.location,
                names: [lastName(of: type.name)],
                kinds: typeKinds(for: type),
                evidence: evidence
            )
            guard candidates.count == 1, let symbol = candidates.first else {
                result[type.id] = TypeBinding(
                    symbolUSR: nil,
                    canonicalOwner: nil,
                    unavailableReason: unavailable
                )
                continue
            }
            result[type.id] = TypeBinding(
                symbolUSR: symbol.usr,
                canonicalOwner: type.id,
                unavailableReason: type.unavailableReason
            )
        }
        for type in types where type.isExtension {
            result[type.id] = bindExtension(type, bindings: result, evidence: evidence)
        }
        return result
    }

    private static func bindExtension(
        _ type: ValueFlowType,
        bindings: [String: TypeBinding],
        evidence: Evidence
    ) -> TypeBinding {
        let extends = evidence.extendsByLocation[type.location, default: []]
        let candidates = extends.filter { reference in
            guard let source = evidence.symbol(reference.sourceUSR),
                  source.kind == .extensionDeclaration,
                  evidence.isFresh(source.location),
                  let target = evidence.symbol(reference.targetUSR)
            else { return false }
            return target.isExternal || evidence.isFresh(target.location)
        }
        let targets = unique(candidates.map(\.targetUSR))
        let sources = unique(candidates.map(\.sourceUSR))
        guard !candidates.isEmpty, sources.count == 1, targets.count == 1, let extensionUSR = sources.first,
              let targetUSR = targets.first
        else {
            return TypeBinding(symbolUSR: nil, canonicalOwner: nil, unavailableReason: unavailable)
        }
        let canonical = bindings.first(where: { $0.value.symbolUSR == targetUSR })?.key ?? targetUSR
        return TypeBinding(symbolUSR: extensionUSR, canonicalOwner: canonical, unavailableReason: type.unavailableReason)
    }

    private static func bindFields(
        _ fields: [ValueFlowField],
        typeBindings: [String: TypeBinding],
        evidence: Evidence
    ) -> [String: FieldBinding] {
        var result: [String: FieldBinding] = [:]
        for field in fields {
            let ownerType = field.ownerType.flatMap { typeBindings[$0]?.canonicalOwner }
            let candidates = declarationCandidates(
                at: field.location,
                names: [field.name],
                kinds: [.property, .variable],
                evidence: evidence
            )
            guard candidates.count == 1, let symbol = candidates.first else {
                result[field.id] = FieldBinding(symbolUSR: nil, ownerType: ownerType, invalid: true)
                continue
            }
            result[field.id] = FieldBinding(symbolUSR: symbol.usr, ownerType: ownerType, invalid: false)
        }
        return result
    }

    private static func bindFunctions(
        _ functions: [ValueFlowFunction],
        types: [ValueFlowType],
        typeBindings: [String: TypeBinding],
        fields: [ValueFlowField],
        fieldBindings: [String: FieldBinding],
        evidence: Evidence
    ) -> [String: FunctionBinding] {
        var result: [String: FunctionBinding] = [:]
        for function in functions {
            let ownerUSR = function.ownerType.flatMap { typeBindings[$0]?.symbolUSR }
            if function.kind == .closure {
                continue
            }
            if function.kind == .getter || function.kind == .setter || isFieldInitializer(function, fields: fields) {
                let field = fields.first { $0.getter == function.id || $0.setter == function.id || $0.initializer == function.id }
                guard let field, let binding = fieldBindings[field.id], binding.isBound else {
                    result[function.id] = FunctionBinding(symbolUSR: nil, ownerUSR: ownerUSR, invalid: true)
                    continue
                }
                result[function.id] = FunctionBinding(symbolUSR: nil, ownerUSR: ownerUSR, invalid: false)
                continue
            }
            if function.kind == .global {
                let candidates = evidence.symbolsByPath[function.location.path, default: []].filter {
                    $0.usr.hasPrefix("cartograph:top-level-code:") && $0.kind == .function
                        && $0.location.path == function.location.path && evidence.isFresh($0.location)
                }
                if candidates.count == 1, let topLevel = candidates.first {
                    result[function.id] = FunctionBinding(
                        symbolUSR: topLevel.usr,
                        ownerUSR: nil,
                        invalid: false
                    )
                } else {
                    result[function.id] = FunctionBinding(symbolUSR: nil, ownerUSR: nil, invalid: true)
                }
                continue
            }
            if function.ownerType != nil && ownerUSR == nil {
                result[function.id] = FunctionBinding(symbolUSR: nil, ownerUSR: nil, invalid: true)
                continue
            }
            if isSyntheticInitializer(function) {
                result[function.id] = bindSyntheticInitializer(
                    function,
                    ownerUSR: ownerUSR,
                    types: types,
                    typeBindings: typeBindings,
                    evidence: evidence
                )
                continue
            }
            let candidates = declarationCandidates(
                at: function.location,
                names: [function.indexName, function.name],
                kinds: functionKinds(function),
                evidence: evidence
            ).filter { symbol in
                guard let ownerUSR else { return symbol.parentUSR == nil }
                return symbol.parentUSR == ownerUSR
            }
            guard candidates.count == 1, let symbol = candidates.first else {
                result[function.id] = FunctionBinding(symbolUSR: nil, ownerUSR: ownerUSR, invalid: true)
                continue
            }
            if function.kind == .initializer, let ownerUSR,
               hasLocalSuperclass(ownerUSR: ownerUSR, evidence: evidence) {
                result[function.id] = FunctionBinding(symbolUSR: symbol.usr, ownerUSR: ownerUSR, invalid: true)
                continue
            }
            result[function.id] = FunctionBinding(symbolUSR: symbol.usr, ownerUSR: ownerUSR, invalid: false)
        }
        return result
    }

    private static func bindSyntheticInitializer(
        _ function: ValueFlowFunction,
        ownerUSR: String?,
        types: [ValueFlowType],
        typeBindings: [String: TypeBinding],
        evidence: Evidence
    ) -> FunctionBinding {
        guard let ownerUSR else {
            return FunctionBinding(symbolUSR: nil, ownerUSR: nil, invalid: true)
        }
        let candidates = evidence.symbolsByParent[ownerUSR, default: []].filter {
            $0.kind == .initializer
                && $0.parentUSR == ownerUSR
                && evidence.isFresh($0.location)
                && nameMatches($0.name, names: [function.indexName, function.name])
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return FunctionBinding(symbolUSR: nil, ownerUSR: ownerUSR, invalid: true)
        }
        let invalid = hasLocalSuperclass(ownerUSR: ownerUSR, evidence: evidence)
        _ = types
        _ = typeBindings
        return FunctionBinding(symbolUSR: candidate.usr, ownerUSR: ownerUSR, invalid: invalid)
    }

    private static func bindReferences(
        _ functions: [ValueFlowFunction],
        functionBindings: [String: FunctionBinding],
        typeBindings: [String: TypeBinding],
        fields: [ValueFlowField],
        fieldBindings: [String: FieldBinding],
        evidence: Evidence
    ) -> ReferenceResult {
        var result = ReferenceResult()
        for function in functions {
            let sourceUSR = functionBindings[function.id]?.symbolUSR
                ?? syntheticSourceUSR(
                    function,
                    functions: functions,
                    bindings: functionBindings,
                    fields: fields,
                    fieldBindings: fieldBindings
                )
            guard let sourceUSR else {
                if !function.blocks.flatMap(\.instructions).isEmpty { result.invalidFunctions.insert(function.id) }
                continue
            }
            let instructions = function.blocks.flatMap(\.instructions)
            let instructionsByID = Dictionary(uniqueKeysWithValues: instructions.map { ($0.id, $0) })
            var callCallees: Set<Int> = []
            for instruction in instructions {
                guard case .call(let callee, _, _, _) = instruction.operation else { continue }
                callCallees.formUnion(calleeInstructionIDs(callee, instructions: instructionsByID))
            }
            for instruction in function.blocks.flatMap(\.instructions) {
                switch instruction.operation {
                case .symbol(let reference):
                    let expected = callCallees.contains(instruction.id) ? EdgeKind.call : EdgeKind.reference
                    let bound = bindReference(reference, sourceUSR: sourceUSR, expected: expected, evidence: evidence)
                    if bound.valid {
                        result.operations[function.id, default: [:]][instruction.id] = .symbol(bound.reference)
                    } else {
                        result.operations[function.id, default: [:]][instruction.id] = .unknown(
                            reason: unavailable, inputs: [], mayWrite: true
                        )
                        result.hasInvalidReferences = true
                    }
                case .member(let base, let reference):
                    let expected = callCallees.contains(instruction.id) ? EdgeKind.call : EdgeKind.reference
                    let bound = bindReference(reference, sourceUSR: sourceUSR, expected: expected, evidence: evidence)
                    if bound.valid {
                        result.operations[function.id, default: [:]][instruction.id] = .member(base: base, symbol: bound.reference)
                    } else {
                        result.operations[function.id, default: [:]][instruction.id] = .unknown(
                            reason: unavailable, inputs: [base], mayWrite: true
                        )
                        result.hasInvalidReferences = true
                    }
                default:
                    break
                }
            }
        }
        _ = typeBindings
        return result
    }

    private struct BoundReference {
        let reference: ValueFlowSymbolReference
        let valid: Bool
    }

    private static func bindReference(
        _ reference: ValueFlowSymbolReference,
        sourceUSR: String,
        expected: EdgeKind,
        evidence: Evidence
    ) -> BoundReference {
        let site = ReferenceSite(source: sourceUSR, location: reference.location)
        let candidates = evidence.referencesBySite[site, default: []].filter {
            $0.kind == expected && $0.location == reference.location
        }
        let targetUSRs = unique(candidates.map(\.targetUSR))
        let targets = targetUSRs.compactMap { evidence.symbol($0) }
        guard targetUSRs.count == 1, targets.count == 1, let symbol = targets.first else {
            return BoundReference(reference: ValueFlowSymbolReference(
                location: reference.location,
                spelling: reference.spelling
            ), valid: false)
        }
        return BoundReference(reference: ValueFlowSymbolReference(
            location: reference.location,
            spelling: reference.spelling,
            usr: targetUSRs[0],
            kind: symbol.kind
        ), valid: true)
    }

    private static func calleeInstructionIDs(
        _ id: Int,
        instructions: [Int: ValueFlowInstruction],
        visited: inout Set<Int>
    ) -> Set<Int> {
        guard visited.insert(id).inserted else { return [] }
        guard let instruction = instructions[id] else { return [id] }
        var result: Set<Int> = [id]
        switch instruction.operation {
        case .read(let address):
            result.formUnion(calleeInstructionIDs(address, instructions: instructions, visited: &visited))
        case .copy(let source):
            result.formUnion(calleeInstructionIDs(source, instructions: instructions, visited: &visited))
        case .local(_, let initial, _):
            if let initial {
                result.formUnion(calleeInstructionIDs(initial, instructions: instructions, visited: &visited))
            }
        default:
            break
        }
        return result
    }

    private static func calleeInstructionIDs(
        _ id: Int,
        instructions: [Int: ValueFlowInstruction]
    ) -> Set<Int> {
        var visited: Set<Int> = []
        return calleeInstructionIDs(id, instructions: instructions, visited: &visited)
    }

    private static func bindDispatch(
        _ functions: [ValueFlowFunction],
        functionBindings: [String: FunctionBinding],
        typeBindings: [String: TypeBinding],
        evidence: Evidence
    ) -> [ValueFlowDispatch] {
        var result: [ValueFlowDispatch] = []
        for function in functions {
            guard let implementation = functionBindings[function.id]?.symbolUSR,
                  let ownerType = function.ownerType.flatMap({ typeBindings[$0]?.canonicalOwner })
            else { continue }
            for reference in evidence.referencesBySource[implementation] ?? [] where reference.kind == .overrides {
                result.append(ValueFlowDispatch(
                    requirementUSR: reference.targetUSR,
                    implementation: function.id,
                    ownerType: ownerType
                ))
            }
        }
        return Array(Set(result)).sorted {
            ($0.ownerType, $0.implementation, $0.requirementUSR)
                < ($1.ownerType, $1.implementation, $1.requirementUSR)
        }
    }

    private static func declarationCandidates(
        at location: SourceLocation,
        names: [String],
        kinds: Set<SymbolKind>,
        evidence: Evidence
    ) -> [IndexedSymbol] {
        guard evidence.freshPaths.contains(location.path) else { return [] }
        return evidence.symbolsByLocation[location, default: []].filter {
            !$0.isExternal && $0.location == location && kinds.contains($0.kind) && nameMatches($0.name, names: names)
        }
    }

    private static func functionKinds(_ function: ValueFlowFunction) -> Set<SymbolKind> {
        switch function.kind {
        case .initializer: return [.initializer]
        case .function: return function.ownerType == nil ? [.function] : [.method]
        default: return [.function, .method]
        }
    }

    private static func typeKinds(for type: ValueFlowType) -> Set<SymbolKind> {
        if type.isExtension { return [.extensionDeclaration] }
        return [.classType, .structType, .enumType, .protocolType, .typeAlias]
    }

    private static func nameMatches(_ candidate: String, names: [String]) -> Bool {
        names.contains { name in
            candidate == name || candidate == lastName(of: name)
        }
    }

    private static func lastName(of name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func isSyntheticInitializer(_ function: ValueFlowFunction) -> Bool {
        function.kind == .initializer && function.id.contains("#synthetic-initializer:")
    }

    private static func isFieldInitializer(_ function: ValueFlowFunction, fields: [ValueFlowField]) -> Bool {
        fields.contains { $0.initializer == function.id }
    }

    private static func syntheticSourceUSR(
        _ function: ValueFlowFunction,
        functions: [ValueFlowFunction],
        bindings: [String: FunctionBinding],
        fields: [ValueFlowField],
        fieldBindings: [String: FieldBinding]
    ) -> String? {
        if function.kind == .getter || function.kind == .setter {
            return fields.first(where: {
                ($0.getter == function.id || $0.setter == function.id)
                    && fieldBindings[$0.id]?.isBound == true
            }).flatMap { fieldBindings[$0.id]?.symbolUSR }
        }
        if let field = fields.first(where: {
            $0.initializer == function.id && fieldBindings[$0.id]?.isBound == true
        }) {
            return fieldBindings[field.id]?.symbolUSR
        }
        for parent in functions {
            guard let parentUSR = bindings[parent.id]?.symbolUSR else { continue }
            for block in parent.blocks {
                for instruction in block.instructions {
                    if case .closure(let closureID, _) = instruction.operation, closureID == function.id {
                        return parentUSR
                    }
                }
            }
        }
        return nil
    }

    private static func hasLocalSuperclass(ownerUSR: String, evidence: Evidence) -> Bool {
        (evidence.referencesBySource[ownerUSR] ?? []).contains { reference in
            guard reference.kind == .inheritance, let target = evidence.symbol(reference.targetUSR) else { return false }
            return !target.isExternal
        }
    }
}
