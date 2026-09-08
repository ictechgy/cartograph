import CartographCore
import Foundation

/// 소스 리터럴은 Swift.String 문맥을 증명한 뒤에만 신뢰된 값 명령으로 바꾼다.
struct ValueFlowLiteralBinder {
    let program: ValueFlowProgram
    let snapshot: IndexSnapshot
    let freshPaths: Set<String>

    func bind() -> ValueFlowProgram {
        let functions = Dictionary(program.functions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byUSR = Dictionary(grouping: program.functions.filter { $0.symbolUSR != nil }, by: { $0.symbolUSR! })
            .compactMapValues { $0.count == 1 ? $0[0] : nil }
        let fields = Dictionary(grouping: program.fields.filter { $0.symbolUSR != nil }, by: { $0.symbolUSR! })
            .compactMapValues { $0.count == 1 ? $0[0] : nil }
        let literalKinds = ["stringLiteral", "unicodeScalarLiteral", "extendedGraphemeClusterLiteral",
                            "integerLiteral", "floatLiteral", "booleanLiteral", "nilLiteral"]
        let literalInitializers = Set(snapshot.symbols.filter { symbol in
            literalKinds.contains { symbol.name.hasPrefix("init(\($0):") }
        }.map(\.usr))
        let conversionSites = Set(snapshot.references.compactMap { reference -> SourceLocation? in
            guard [.call, .reference].contains(reference.kind),
                  literalInitializers.contains(reference.targetUSR) else { return nil }
            return reference.location
        })
        let shadowedString = snapshot.symbols.contains {
            !$0.isExternal && $0.name == "String" && $0.usr != "s:SS"
        }
        let closureTypes = closureReturnTypes(functions: functions, byUSR: byUSR)
        var result = program
        var literalLimitations: Set<String> = []
        result.functions = program.functions.map { function in
            let instructions = Dictionary(function.blocks.flatMap(\.instructions).map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })
            var uses: [Int: [String]] = [:]
            for instruction in instructions.values {
                switch instruction.operation {
                case let .call(callee, arguments, _, _):
                    let target = targetFunction(callee, instructions: instructions, functions: functions, byUSR: byUSR)
                    for (index, argument) in arguments.enumerated() {
                        let type = target.flatMap { $0.parameters.indices.contains(index) ? $0.parameters[index].declaredType : nil }
                        uses[argument, default: []].append(type ?? "<unknown>")
                    }
                case let .write(address, value):
                    let type = valueType(address, function: function, instructions: instructions, fields: fields,
                        functions: functions, byUSR: byUSR, remaining: 32)
                    uses[value, default: []].append(type ?? "<unknown>")
                default: break
                }
            }
            var updated = function
            updated.blocks = function.blocks.map { block in
                let lowered = block.instructions.map { instruction -> ValueFlowInstruction in
                    if case .literal = instruction.operation, conversionSites.contains(instruction.location) {
                        literalLimitations.insert("contextual-literal-conversion")
                        return ValueFlowInstruction(id: instruction.id,
                            operation: .unknown(reason: "contextual-literal-conversion", inputs: [], mayWrite: true),
                            location: instruction.location)
                    }
                    guard case let .stringLiteral(value, expectedType, inferred) = instruction.operation else { return instruction }
                    let candidates: [String]
                    if let expectedType { candidates = [expectedType] }
                    else if inferred { candidates = ["Swift.String"] }
                    else if let typedUses = uses[instruction.id] { candidates = typedUses }
                    else if case let .return(value) = block.terminator, value == instruction.id {
                        candidates = function.returnType.map { [$0] } ?? closureTypes[function.id] ?? []
                    } else { candidates = [] }
                    let known = freshPaths.contains(instruction.location.path)
                        && !conversionSites.contains(instruction.location) && !candidates.isEmpty
                        && candidates.allSatisfy { isString($0, shadowed: shadowedString) }
                    if !known { literalLimitations.insert("contextual-string-literal") }
                    return ValueFlowInstruction(id: instruction.id,
                        operation: known ? .literal(.string(value))
                            : .unknown(reason: "contextual-string-literal", inputs: [], mayWrite: true),
                        location: instruction.location)
                }
                return ValueFlowBlock(id: block.id, instructions: lowered, terminator: block.terminator)
            }
            return updated
        }
        result.limitations = Array(Set(result.limitations).union(literalLimitations)).sorted()
        return result
    }

    private func isString(_ type: String, shadowed: Bool) -> Bool {
        let normalized = type.hasPrefix("inout ") ? String(type.dropFirst(6)) : type
        return normalized == "Swift.String" || (normalized == "String" && !shadowed)
    }

    private func source(_ id: Int, instructions: [Int: ValueFlowInstruction]) -> ValueFlowInstruction? {
        var current = id
        var visited: Set<Int> = []
        while visited.insert(current).inserted, let instruction = instructions[current] {
            switch instruction.operation {
            case let .read(address), let .copy(address): current = address
            case let .local(_, initial?, _): current = initial
            default: return instruction
            }
        }
        return nil
    }

    private func targetFunction(_ id: Int, instructions: [Int: ValueFlowInstruction],
                                functions: [String: ValueFlowFunction], byUSR: [String: ValueFlowFunction])
        -> ValueFlowFunction? {
        guard let instruction = source(id, instructions: instructions) else { return nil }
        switch instruction.operation {
        case let .symbol(reference), let .member(_, reference): return reference.usr.flatMap { byUSR[$0] }
        case let .closure(function, _): return functions[function]
        default: return nil
        }
    }

    private func valueType(_ id: Int, function: ValueFlowFunction, instructions: [Int: ValueFlowInstruction],
                           fields: [String: ValueFlowField], functions: [String: ValueFlowFunction],
                           byUSR: [String: ValueFlowFunction], remaining: Int) -> String? {
        guard remaining > 0, let instruction = source(id, instructions: instructions) else { return nil }
        switch instruction.operation {
        case let .stringLiteral(_, expected, inferred): return expected ?? (inferred ? "Swift.String" : nil)
        case .literal(.string): return "Swift.String"
        case let .parameter(index): return function.parameters.indices.contains(index) ? function.parameters[index].declaredType : nil
        case let .symbol(reference), let .member(_, reference): return reference.usr.flatMap { fields[$0]?.declaredType }
        case let .call(callee, _, _, _):
            return targetFunction(callee, instructions: instructions, functions: functions, byUSR: byUSR)?.returnType
        default: return nil
        }
    }

    private func closureReturnTypes(functions: [String: ValueFlowFunction], byUSR: [String: ValueFlowFunction])
        -> [String: [String]] {
        var result: [String: [String]] = [:]
        for function in functions.values {
            let instructions = Dictionary(function.blocks.flatMap(\.instructions).map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })
            for instruction in instructions.values {
                guard case let .call(callee, arguments, _, _) = instruction.operation else { continue }
                let target = targetFunction(callee, instructions: instructions, functions: functions, byUSR: byUSR)
                for (index, argument) in arguments.enumerated() {
                    guard let operation = source(argument, instructions: instructions)?.operation,
                          case let .closure(id, _) = operation else { continue }
                    let type = target.flatMap { $0.parameters.indices.contains(index) ? $0.parameters[index].declaredType : nil }
                    let returned = type?.components(separatedBy: "->").last?.trimmingCharacters(in: .whitespaces)
                    result[id, default: []].append(returned ?? "<unknown>")
                }
            }
        }
        return result
    }
}
