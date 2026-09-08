import CartographCore
import CartographSyntax
import Testing

@Suite("값 흐름으로 보강한 브리지 이름")
struct BridgeValueFlowTests {
    @Test("정확한 표현식 위치의 검증된 반환값만 동적 이름을 대체한다")
    func resolvedCall() {
        let source = "let channel = FlutterMethodChannel(name: makeName(), binaryMessenger: messenger)\nchannel.setMethodCallHandler { _, _ in }"
        let path = "/p/Bridge.swift"
        let start = source.range(of: "makeName()")!.lowerBound
        let column = source[..<start].utf8.count + 1
        let location = SourceLocation(path: path, line: 1, column: column)
        let scanner = BridgeFactScanner()
        let original = scanner.scan(source: source, path: path)
        #expect(original.facts.contains { $0.fact.isDynamic })
        let resolved = scanner.scan(source: source, path: path, resolvedValues: [location: "known-channel"])
        #expect(resolved.facts.contains { $0.fact.channel == "known-channel" && !$0.fact.isDynamic })
        let wrong = scanner.scan(source: source, path: path,
            resolvedValues: [SourceLocation(path: path, line: 1, column: column + 1): "wrong"])
        #expect(wrong.facts.contains { $0.fact.isDynamic })
    }
}
