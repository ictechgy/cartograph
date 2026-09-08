import CartographCore
import Foundation

/// Objective-C 구현의 관찰 사실과 확인하지 못한 핸들러 본문을 분리한다.
public struct ObjectiveCBridgeScanResult: Sendable, Equatable {
    public let facts: [BridgeFact]
    /// 선언 위치는 실제 Clang USR 조회에만 사용한다.
    public let scannedFacts: [ScannedBridgeFact]
    public let opaqueHandlerChannels: [String?]
}

/// 직접 채널 생성·블록 등록과 같은 파일의 FlutterPlugin 위임만 읽는다.
/// 전체 ObjC 분석을 주장하지 않으며 일반 objective-c-sources 한계는 계속 남긴다.
public struct ObjectiveCFlutterScanner: Sendable {
    public init() {}

    /// 조건부 컴파일·깨진 토큰·클래스 가림은 활성 코드나 API를 추측하지 않고 보류한다.
    public func scan(source: String, path: String) -> ObjectiveCBridgeScanResult {
        var lexer = ObjectiveCLexer(source)
        let tokens = lexer.tokenize()
        let stream = ObjectiveCTokenStream(tokens)
        guard lexer.isComplete, stream.isBalanced, !Self.hasConditionalOrShadowedAPI(tokens) else {
            return ObjectiveCBridgeScanResult(facts: [], scannedFacts: [], opaqueHandlerChannels: [])
        }
        return ObjectiveCFlutterCollector(stream: stream, path: path).collect()
    }

    private static func hasConditionalOrShadowedAPI(_ tokens: [ObjectiveCToken]) -> Bool {
        for index in tokens.indices {
            if tokens[index].text == "#", index + 1 < tokens.count,
               ["if", "ifdef", "ifndef", "elif", "else", "define", "undef"].contains(tokens[index + 1].text) { return true }
            if tokens[index].text == "@", index + 2 < tokens.count,
               ["interface", "implementation", "protocol"].contains(tokens[index + 1].text),
               ["FlutterMethodChannel", "FlutterMethodCall", "FlutterPluginRegistrar"].contains(tokens[index + 2].text) {
                return true
            }
        }
        return false
    }
}

private struct ObjectiveCMethod {
    let className: String
    let selector: String
    let body: Range<Int>
    let callParameter: String?
    let registrarParameter: String?
    let isClassMethod: Bool
    let line: Int
}

private struct ObjectiveCChannelName {
    let text: String
    let dynamic: Bool
}

/// 토큰 관계를 계산하는 값 타입. 각 메서드의 변수는 다른 메서드와 섞지 않는다.
private struct ObjectiveCFlutterCollector {
    let stream: ObjectiveCTokenStream
    let path: String
    private var tokens: [ObjectiveCToken] { stream.tokens }
    private var constants: [String: String] = [:]

    init(stream: ObjectiveCTokenStream, path: String) {
        self.stream = stream
        self.path = path
        constants = Self.stringConstants(in: stream)
        // 인스턴스 메서드의 bare 이름은 헤더에 선언된 ivar일 수도 있다.
        let instanceNames = Set(methods().filter { !$0.isClassMethod }.flatMap { stream.texts($0.body) })
        constants = constants.filter { !instanceNames.contains($0.key) }
    }

    /// 파일 범위의 불변 NSString 포인터 한 단계만 푼다. 같은 이름의 지역 선언이 있으면 쓰지 않는다.
    private static func stringConstants(in stream: ObjectiveCTokenStream) -> [String: String] {
        let tokens = stream.tokens
        var declarations: [String: Int] = [:]
        var escaped: Set<String> = []
        for index in tokens.indices where index > 0 {
            if ["*", "const", "id", ")"].contains(tokens[index - 1].text) { declarations[tokens[index].text, default: 0] += 1 }
            if tokens[index - 1].text == "&" { escaped.insert(tokens[index].text) }
        }
        var result: [String: String] = [:]
        for index in tokens.indices where index + 7 < tokens.count && stream.braceDepths[index] == 0 {
            guard stream.texts(index..<(index + 4)) == ["static", "NSString", "*", "const"],
                  tokens[index + 5].text == "=", tokens[index + 7].text == ";",
                  tokens[index + 6].text.hasPrefix("@\""), let value = tokens[index + 6].literal else { continue }
            let name = tokens[index + 4].text
            if declarations[name] == 1 && !escaped.contains(name) { result[name] = value }
        }
        return result
    }

    func collect() -> ObjectiveCBridgeScanResult {
        let methods = methods()
        let handlersByType = Dictionary(grouping: methods.filter { $0.selector == "handleMethodCall:result:" }, by: \.className)
        var facts: [BridgeFact] = []
        var opaque: [String?] = []
        for method in methods {
            let mutations = variableMutations(in: method.body)
            let bindings = channelBindings(in: method.body, mutations: mutations)
            let instances = instanceBindings(in: method.body, mutations: mutations)
            let depth = method.body.isEmpty ? 0 : stream.braceDepths[method.body.lowerBound]
            for index in method.body where tokens[index].text == "[" && stream.braceDepths[index] == depth {
                guard let message = stream.message(at: index) else { continue }
                if message.selector == "setMethodCallHandler:", let argument = message.arguments["setMethodCallHandler"],
                   !isNullHandler(argument),
                   let channel = resolveChannel(message.receiver, bindings: bindings) {
                    facts.append(fact(.channelRegister, channel: channel, at: index))
                    if let handler = blockHandler(argument) {
                        let scanned = handlerFacts(body: handler.body, parameter: handler.parameter, channel: channel)
                        facts += scanned.facts
                        if scanned.opaque { opaque.append(channel.dynamic ? nil : channel.text) }
                    } else { opaque.append(channel.dynamic ? nil : channel.text) }
                } else if message.selector == "addMethodCallDelegate:channel:",
                          stream.texts(message.receiver) == [method.registrarParameter ?? ""],
                          let channelArgument = message.arguments["channel"],
                          let channel = resolveChannel(channelArgument, bindings: bindings),
                          let delegate = message.arguments["addMethodCallDelegate"] {
                    facts.append(fact(.channelRegister, channel: channel, at: index))
                    let type = instanceType(delegate, instances: instances)
                    let handlers = type.flatMap { handlersByType[$0] } ?? []
                    if handlers.count == 1, let handler = handlers.first, let parameter = handler.callParameter {
                        let scanned = handlerFacts(body: handler.body, parameter: parameter, channel: channel)
                        facts += scanned.facts
                        if scanned.opaque { opaque.append(channel.dynamic ? nil : channel.text) }
                    } else { opaque.append(channel.dynamic ? nil : channel.text) }
                }
            }
        }
        let sorted = facts.sorted()
        let scanned = sorted.map { fact in
            let owners = methods.filter { method in
                guard let first = method.body.first, let last = method.body.last else { return false }
                return fact.location.line >= tokens[first].line && fact.location.line <= tokens[last].line
            }
            let declaration = owners.count == 1 ? owners.first.map { method in
                EnclosingDeclaration(name: method.selector, indexName: method.selector,
                    qualifiedName: method.className + "." + method.selector, line: method.line)
            } : nil
            return ScannedBridgeFact(fact: fact, declaration: declaration)
        }
        return ObjectiveCBridgeScanResult(facts: sorted, scannedFacts: scanned, opaqueHandlerChannels: opaque)
    }

    private func methods() -> [ObjectiveCMethod] {
        var result: [ObjectiveCMethod] = []
        var className: String?
        var index = 0
        while index < tokens.count {
            if tokens[index].text == "@", index + 1 < tokens.count {
                if tokens[index + 1].text == "implementation", index + 2 < tokens.count { className = tokens[index + 2].text }
                if tokens[index + 1].text == "end" { className = nil }
            }
            guard let name = className, ["+", "-"].contains(tokens[index].text),
                  index + 1 < tokens.count, tokens[index + 1].text == "(", let typeEnd = stream.pairs[index + 1]
            else { index += 1; continue }
            var opening = typeEnd + 1
            while opening < tokens.count && !["{", ";", "@"].contains(tokens[opening].text) { opening += 1 }
            guard opening < tokens.count, tokens[opening].text == "{", let end = stream.pairs[opening]
            else { index += 1; continue }
            let header = (typeEnd + 1)..<opening
            let selector = selector(in: header)
            result.append(ObjectiveCMethod(
                className: name, selector: selector, body: (opening + 1)..<end,
                callParameter: parameter(in: header, type: "FlutterMethodCall"),
                registrarParameter: parameter(in: header, type: "FlutterPluginRegistrar"),
                isClassMethod: tokens[index].text == "+", line: tokens[typeEnd + 1].line
            ))
            index = end + 1
        }
        return result
    }

    private func selector(in header: Range<Int>) -> String {
        var names: [String] = []
        var index = header.lowerBound
        while index < header.upperBound {
            if let end = stream.pairs[index] { index = end + 1; continue }
            if index + 1 < header.upperBound && tokens[index + 1].text == ":" { names.append(tokens[index].text) }
            index += 1
        }
        return names.isEmpty ? (header.first.map { tokens[$0].text } ?? "") : names.joined(separator: ":") + ":"
    }

    private func parameter(in header: Range<Int>, type: String) -> String? {
        for index in header where tokens[index].text == "(" {
            guard let end = stream.pairs[index], end + 1 < header.upperBound,
                  stream.texts((index + 1)..<end).contains(type) else { continue }
            return tokens[end + 1].text
        }
        return nil
    }

    /// 재대입이나 안쪽의 동명 선언이 있으면 첫 채널 이름을 재사용하지 않고 불명으로 되돌린다.
    private func channelBindings(in body: Range<Int>, mutations: Set<String>) -> [String: ObjectiveCChannelName] {
        var result: [String: ObjectiveCChannelName] = [:]
        guard let first = body.first else { return result }
        for index in body where tokens[index].text == "=" && stream.braceDepths[index] == stream.braceDepths[first] {
            guard index >= body.lowerBound + 2, index + 1 < body.upperBound,
                  tokens[index - 2].text == "*" || tokens[index - 2].text == "id",
                  let end = stream.pairs[index + 1], end + 1 < body.upperBound, tokens[end + 1].text == ";",
                  let name = channelConstruction((index + 1)..<(end + 1)) else { continue }
            let identifier = tokens[index - 1].text
            result[identifier] = mutations.contains(identifier) ? ObjectiveCChannelName(text: identifier, dynamic: true) : name
        }
        return result
    }

    private func instanceBindings(in body: Range<Int>, mutations: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        guard let first = body.first else { return result }
        for index in body where tokens[index].text == "=" && stream.braceDepths[index] == stream.braceDepths[first] {
            guard index > body.lowerBound, index + 1 < body.upperBound, let end = stream.pairs[index + 1],
                  end + 1 < body.upperBound, tokens[end + 1].text == ";",
                  let type = allocatedType((index + 1)..<(end + 1)) else { continue }
            let name = tokens[index - 1].text
            if !mutations.contains(name) { result[name] = type }
        }
        return result
    }

    /// 변수별로 본문을 다시 훑지 않는다. 주소 전달·재대입·중첩 선언은 한 번의 순회로 모은다.
    private func variableMutations(in body: Range<Int>) -> Set<String> {
        var writes: [String: Int] = [:]
        var declarations: [String: Int] = [:]
        var uncertain: Set<String> = []
        for index in body where index > body.lowerBound {
            let previous = tokens[index - 1].text
            let current = tokens[index].text
            if ["=", "+=", "-=", "*=", "/=", "++", "--"].contains(current) { writes[previous, default: 0] += 1 }
            if ["*", "id"].contains(previous) { declarations[current, default: 0] += 1 }
            if ["&", "++", "--"].contains(previous) { uncertain.insert(current) }
        }
        uncertain.formUnion(writes.filter { $0.value > 1 }.keys)
        uncertain.formUnion(declarations.filter { $0.value > 1 }.keys)
        return uncertain
    }

    private func resolveChannel(_ expression: Range<Int>, bindings: [String: ObjectiveCChannelName]) -> ObjectiveCChannelName? {
        if expression.count == 1 { return bindings[tokens[expression.lowerBound].text] }
        return channelConstruction(expression)
    }

    private func channelConstruction(_ expression: Range<Int>) -> ObjectiveCChannelName? {
        guard let start = expression.first, let message = stream.message(at: start),
              stream.pairs[start] == expression.upperBound - 1 else { return nil }
        let direct = stream.texts(message.receiver) == ["FlutterMethodChannel"]
        let allocated = allocationReceiver(message.receiver) == "FlutterMethodChannel"
        let key = direct ? "methodChannelWithName" : "initWithName"
        guard direct || allocated, message.selector.hasPrefix(key + ":"), let value = message.arguments[key] else { return nil }
        return resolvedName(value)
    }

    private func allocationReceiver(_ expression: Range<Int>) -> String? {
        guard let start = expression.first, let message = stream.message(at: start),
              stream.pairs[start] == expression.upperBound - 1,
              ["alloc", "new"].contains(message.selector), message.receiver.count == 1 else { return nil }
        return tokens[message.receiver.lowerBound].text
    }

    private func allocatedType(_ expression: Range<Int>) -> String? {
        guard let start = expression.first, let message = stream.message(at: start),
              stream.pairs[start] == expression.upperBound - 1 else { return nil }
        if message.selector == "new", message.receiver.count == 1 { return tokens[message.receiver.lowerBound].text }
        return message.selector.hasPrefix("init") ? allocationReceiver(message.receiver) : nil
    }

    private func instanceType(_ expression: Range<Int>, instances: [String: String]) -> String? {
        if expression.count == 1 { return instances[tokens[expression.lowerBound].text] }
        return allocatedType(expression)
    }

    /// 단순 괄호와 nil의 타입 캐스트를 벗긴다. 계산식의 결과까지 nil이라고 추측하지 않는다.
    private func isNullHandler(_ expression: Range<Int>) -> Bool {
        var range = expression
        while let first = range.first, tokens[first].text == "(", let end = stream.pairs[first] {
            range = end == range.upperBound - 1 ? (first + 1)..<end : (end + 1)..<range.upperBound
        }
        return range.count == 1 && ["nil", "NULL", "0", "nullptr"].contains(tokens[range.lowerBound].text)
    }

    private func blockHandler(_ expression: Range<Int>) -> (body: Range<Int>, parameter: String)? {
        guard let first = expression.first, tokens[first].text == "^",
              let opening = expression.first(where: { tokens[$0].text == "(" }), let end = stream.pairs[opening],
              let bodyStart = expression.first(where: { $0 > end && tokens[$0].text == "{" }),
              let bodyEnd = stream.pairs[bodyStart], bodyEnd == expression.upperBound - 1 else { return nil }
        let parameters = (opening + 1)..<end
        guard let comma = parameters.first(where: { tokens[$0].text == "," }), comma > opening + 1,
              stream.texts((opening + 1)..<comma).contains("FlutterMethodCall") else { return nil }
        return ((bodyStart + 1)..<bodyEnd, tokens[comma - 1].text)
    }

    private func handlerFacts(body: Range<Int>, parameter: String, channel: ObjectiveCChannelName) -> (facts: [BridgeFact], opaque: Bool) {
        if body.contains(where: { index in
            guard tokens[index].text == parameter, index > body.lowerBound else { return false }
            let previous = tokens[index - 1].text
            let next = index + 1 < body.upperBound ? tokens[index + 1].text : ""
            if ["*", "id", "auto", "&", "++", "--"].contains(previous) { return true }
            if ["=", "+=", "-=", "++", "--"].contains(next) { return true }
            let typeLike = previous.first?.isLetter == true || [">", ")", "}"].contains(previous)
            return typeLike && !["return", "throw", "case", "goto"].contains(previous)
                && [";", ",", ")", "("].contains(next)
        }) { return ([], true) }
        var facts: [BridgeFact] = []
        var opaque = false
        var understoodMethodReads: Set<Int> = []
        for index in body where tokens[index].text == "if" && index + 1 < body.upperBound {
            guard tokens[index + 1].text == "(", let end = stream.pairs[index + 1] else { continue }
            let condition = (index + 2)..<end
            if let comparison = methodComparison(condition, parameter: parameter) {
                facts.append(fact(.methodHandle, channel: channel, method: comparison.name, at: comparison.site))
                understoodMethodReads.formUnion(condition)
            } else if stream.texts(condition).contains(parameter) { opaque = true }
        }
        // 한 홉 더 위임한 본문에는 이 파일이 열거하지 못한 메서드가 있을 수 있다.
        for index in body where tokens[index].text == parameter && index > body.lowerBound {
            if !understoodMethodReads.contains(index), index + 1 < body.upperBound,
               ![".", "->"].contains(tokens[index - 1].text) {
                let getter = tokens[index - 1].text == "[" && tokens[index + 1].text == "method"
                let property = index + 2 < body.upperBound && stream.texts((index + 1)..<(index + 3)) == [".", "method"]
                if getter || property { opaque = true }
            }
            if [":", "(", ","].contains(tokens[index - 1].text),
               index + 1 < body.upperBound, tokens[index + 1].text != "." { opaque = true }
        }
        return (facts, opaque || facts.isEmpty)
    }

    private func methodComparison(_ expression: Range<Int>, parameter: String) -> (name: ObjectiveCChannelName, site: Int)? {
        guard let start = expression.first, let message = stream.message(at: start),
              stream.pairs[start] == expression.upperBound - 1,
              message.selector == "isEqualToString:", let value = message.arguments["isEqualToString"] else { return nil }
        if isMethod(message.receiver, parameter: parameter) { return (resolvedName(value), value.lowerBound) }
        if isMethod(value, parameter: parameter) { return (resolvedName(message.receiver), message.receiver.lowerBound) }
        return nil
    }

    private func isMethod(_ expression: Range<Int>, parameter: String) -> Bool {
        let texts = stream.texts(expression)
        return texts == [parameter, ".", "method"] || texts == ["[", parameter, "method", "]"]
    }

    private func resolvedName(_ expression: Range<Int>) -> ObjectiveCChannelName {
        let token = tokens[expression.lowerBound]
        if expression.count == 1, token.text.hasPrefix("@\""), let value = token.literal {
            return ObjectiveCChannelName(text: value, dynamic: false)
        }
        if expression.count == 1, let value = constants[token.text] {
            return ObjectiveCChannelName(text: value, dynamic: false)
        }
        let raw = stream.texts(expression).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return ObjectiveCChannelName(text: raw, dynamic: true)
    }

    private func fact(_ kind: BridgeFact.Kind, channel: ObjectiveCChannelName,
                      method: ObjectiveCChannelName? = nil, at index: Int) -> BridgeFact {
        let token = tokens[index]
        return BridgeFact(
            kind: kind, target: .flutter, channel: channel.text, method: method?.text,
            isDynamic: channel.dynamic || (method?.dynamic ?? false),
            location: SourceLocation(path: path, line: token.line, column: token.column), sourceLanguage: .objectiveC
        )
    }
}
