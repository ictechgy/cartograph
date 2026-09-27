import CartographCore
@testable import CartographSyntax
import CryptoKit
import Foundation
import Testing

/// isthmus 가 소유하는 http 공유 적합성 벡터(`conformance/`)를 제품 코드로 실행한다.
///
/// 벡터는 벤더링한 사본이고 정본은 isthmus 저장소다. `conformance/conformance.lock` 이 가져온
/// 커밋과 파일별 sha256 을 적는다. 사본을 손으로 고치면 해시 대조가, 규칙 구현이 벡터와 어긋나면
/// 케이스 실행이 실패한다. 새 규칙 식별자가 벡터에 생기면 "실행기 없음"으로 실패해 구현을 강제한다.
@Suite("http 공유 적합성 벡터")
struct HTTPConformanceTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("conformance")

    private static func load(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(name))
    }

    private static func cases(_ suite: String) throws -> [[String: Any]] {
        let document = try #require(try JSONSerialization.jsonObject(with: load(suite + ".json")) as? [String: Any])
        #expect(document["format"] as? String == "isthmus-conformance")
        #expect(document["suite"] as? String == suite)
        return try #require(document["cases"] as? [[String: Any]])
    }

    /// `producer` 또는 이 도구 이름을 지목한 케이스만 생산자가 통과해야 한다.
    private static func appliesToProducer(_ testCase: [String: Any]) -> Bool {
        let targets = testCase["appliesTo"] as? [String] ?? []
        return targets.contains("producer") || targets.contains("producer:\(Cartograph.toolName)")
    }

    @Test("벤더링한 벡터가 잠금 파일의 sha256 과 같다")
    func vendoredFilesMatchLock() throws {
        let lock = try #require(try JSONSerialization.jsonObject(with: Self.load("conformance.lock")) as? [String: Any])
        let files = try #require(lock["files"] as? [String: String])
        #expect(Set(files.keys) == ["http-template.json", "url-compose.json"])
        for (name, expected) in files {
            let digest = SHA256.hash(data: try Self.load(name)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == expected, "\(name) differs from conformance.lock; re-vendor both files from isthmus")
        }
    }

    @Test("생산자 케이스를 모두 제품 규칙으로 통과한다")
    func producerCasesPass() throws {
        var executed = 0
        for suite in ["http-template", "url-compose"] {
            for testCase in try Self.cases(suite) where Self.appliesToProducer(testCase) {
                let label = "\(suite)#\(testCase["id"] as? String ?? "?")"
                let actual = try run(testCase, label: label)
                compare(actual, with: testCase, label: label)
                for template in [actual["template"], actual["channelPrefix"]].compactMap({ $0 as? String }) {
                    #expect(HTTPRouteTemplate.validate(template) == nil, "\(label): \(template) is not canonical")
                }
                executed += 1
            }
        }
        // 생산자 케이스가 조용히 0건이 되면 이 테스트는 아무것도 증명하지 않는다.
        #expect(executed >= 70)
    }

    // MARK: - 실행기

    private func run(_ testCase: [String: Any], label: String) throws -> [String: Any] {
        let input = testCase["input"] as? [String: Any] ?? [:]
        switch testCase["ruleId"] as? String {
        case "template.grammar":
            let reason = HTTPRouteTemplate.validate(input["template"] as? String ?? "")
            return reason.map { ["valid": false, "reason": $0.rawValue] } ?? ["valid": true]
        case "template.normalize":
            return ["template": HTTPRouteTemplate.normalize(input["path"] as? String ?? "")]
        case "compose.interpolation", "compose.query-tail", "compose.suffix", "compose.normalize":
            return composed(input["parts"] as? [[String: Any]] ?? [])
        case "compose.base-join":
            return baseJoined(input)
        case "compose.strip":
            let stripped = try #require(HTTPRouteComposer.strip(url: input["url"] as? String ?? ""), "\(label)")
            var result: [String: Any] = ["template": stripped.template, "authority": stripped.authority]
            if stripped.queryTailStripped { result["queryTailStripped"] = true }
            return result
        case "compose.mask":
            let masked = HTTPRouteTemplate.mask(input["template"] as? String ?? "", authority: input["authority"] as? String)
            return ["template": masked.template, "maskedSegments": masked.maskedSegments]
        case "wrapper.method":
            return boundMethod(input)
        case "wrapper.location":
            return try scannedLocation(input, label: label)
        case let rule:
            Issue.record("\(label): no runner for ruleId \(rule ?? "nil")")
            return [:]
        }
    }

    private func composed(_ parts: [[String: Any]]) -> [String: Any] {
        let converted: [HTTPURLPart] = parts.map { part in
            if let literal = part["literal"] as? String { return .literal(literal) }
            return part["queryTail"] != nil ? .queryTail : .value
        }
        switch HTTPRouteComposer.compose(converted) {
        case let .template(template, stripped):
            return stripped ? ["template": template, "queryTailStripped": true] : ["template": template]
        case let .dynamic(prefix):
            return prefix.map { ["dynamic": true, "channelPrefix": $0] } ?? ["dynamic": true]
        }
    }

    private func baseJoined(_ input: [String: Any]) -> [String: Any] {
        let kind = HTTPRouteComposer.BaseJoinKind(rawValue: input["join"] as? String ?? "") ?? .rfc3986
        let resolution = HTTPRouteComposer.baseJoin(kind, base: input["base"] as? String, path: input["path"] as? String ?? "")
        var result: [String: Any] = ["pathAnchor": resolution.pathAnchor.rawValue]
        if let template = resolution.template { result["template"] = template } else { result["dynamic"] = true }
        if let limitation = resolution.limitation { result["limitation"] = limitation }
        return result
    }

    private func boundMethod(_ input: [String: Any]) -> [String: Any] {
        let declaration = input["declaration"] as? [String: Any] ?? [:]
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .function, owner: "Vector", name: "call",
            methodArg: (declaration["methodArg"] as? [String: Any]).map(Self.binding),
            pathArg: .init(label: "path"), defaultMethod: declaration["defaultMethod"] as? String,
            methodEnum: declaration["methodEnum"] as? [String: String] ?? [:], pathAnchor: .root
        )
        let arguments = ((input["call"] as? [String: Any])?["args"] as? [[String: Any]] ?? []).map { argument in
            let value = argument["value"] as? [String: Any] ?? [:]
            let converted: HTTPWrapperCallArgument.Value = if let literal = value["literal"] as? String { .literal(literal) }
                else if let name = value["enumCase"] as? String { .enumCase(name) } else { .opaque }
            return HTTPWrapperCallArgument(label: argument["label"] as? String, value: converted)
        }
        return HTTPWrapperBinding.method(for: wrapper, arguments: arguments).map { ["method": $0] } ?? ["dynamic": true]
    }

    private static func binding(_ object: [String: Any]) -> HTTPWrapperDeclaration.ArgumentBinding {
        .init(index: object["index"] as? Int, label: object["label"] as? String)
    }

    /// 벡터의 줄 번호대로 여러 줄 호출을 합성해 실제 스캐너가 보고하는 줄을 잰다.
    private func scannedLocation(_ input: [String: Any], label: String) throws -> [String: Any] {
        let start = try #require(input["callStartLine"] as? Int, "\(label)")
        let methodLine = try #require(input["methodArgLine"] as? Int, "\(label)")
        let pathLine = try #require(input["pathArgLine"] as? Int, "\(label)")
        var lines = Array(repeating: "", count: max(start, methodLine, pathLine) + 2)
        lines[0] = "struct Endpoint { init(method: String, path: String) {} }"
        lines[start - 2] = "func make() -> Endpoint {"
        lines[start - 1] = "    Endpoint("
        lines[methodLine - 1] = "        method: \"GET\","
        lines[pathLine - 1] = "        path: \"/x\""
        lines[pathLine] = "    )"
        lines[pathLine + 1] = "}"
        let wrapper = HTTPWrapperDeclaration(
            language: "swift", kind: .constructor, owner: "Endpoint", name: "init",
            methodArg: .init(label: "method"), pathArg: .init(label: "path"), pathAnchor: .root
        )
        let result = HTTPRouteCallScanner(wrappers: [wrapper]).scan(source: lines.joined(separator: "\n"), path: "/p/E.swift")
        let fact = try #require(result.calls.first?.fact, "\(label): the synthetic call was not recognized")
        return ["line": fact.location.line]
    }

    // MARK: - 비교

    /// 적힌 키만 비교한다. dynamic 여부와 기대 한계 접두사는 항상 비교한다.
    private func compare(_ actual: [String: Any], with testCase: [String: Any], label: String) {
        let expectsDynamic = testCase["expectDynamic"] as? Bool == true
        #expect((actual["dynamic"] as? Bool == true) == expectsDynamic, "\(label): dynamic")
        if let limitation = testCase["expectLimitation"] as? String {
            #expect(actual["limitation"] as? String == limitation, "\(label): limitation")
        }
        for (key, expected) in testCase["expect"] as? [String: Any] ?? [:] {
            #expect(Self.same(actual[key], expected), "\(label): \(key) expected \(expected) but got \(actual[key] ?? "nil")")
        }
    }

    private static func same(_ actual: Any?, _ expected: Any) -> Bool {
        guard let actual else { return false }
        return (actual as AnyObject).isEqual(expected as AnyObject)
    }
}
