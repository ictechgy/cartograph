import CartographCore
import CartographSyntax
import CartographTestSupport
import CartographKit
import Foundation
import Testing

@Suite("명시적인 클로저 캡처")
struct ValueFlowCaptureTests {
    @Test("캡처 목록은 생성 당시 값을 복사하고 이후 바깥 변수 쓰기를 따라가지 않는다")
    func explicitCaptureSnapshot() throws {
        for (capture, returned, expected) in [("value", "value", "before"), ("snapshot = value", "snapshot", "before"),
            ("snapshot = \"literal\"", "snapshot", "literal")] {
            let source = """
                func invoke(_ body: () -> String) -> String { body() }
                public func make() -> String {
                    var value = "before"
                    let body = { [\(capture)] in \(returned) }
                    value = "after"
                    return invoke(body)
                }
                """
            let path = "/p/Capture.swift"
            let parsed = SwiftValueFlowParser().scan(source: source, path: path)
            let declarations = parsed.functions.filter { $0.kind == .function }
            let symbols = declarations.map {
                IndexedSymbol(usr: "s:" + $0.name, name: $0.indexName, kind: .function,
                    module: "Capture", location: $0.location)
            }
            let reference = IndexedReference(sourceUSR: "s:make", targetUSR: "s:invoke", kind: .call,
                location: SourceLocation(path: path, line: 6, column: 12))
            let snapshot = IndexSnapshot(symbols: symbols, references: [reference],
                indexedFileDates: [path: Date(timeIntervalSince1970: 2)])
            let files = InMemoryFileSystem(currentDirectoryPath: "/p", files: [path: source])
            files.setModificationDate(Date(timeIntervalSince1970: 1), for: path)
            let service = CartographService(configuration: .init(projectPath: "/p"), environment: .init(
                fileSystem: files, indexProviderOverride: StaticIndexProvider(snapshot), usesSyntaxCache: false))
            let document = try service.valueFlowDocument(symbol: "make")
            let context = try #require(document.graph.contexts.first { document.selectedContexts.contains($0.id) })
            #expect(context.result.singleString == expected)
        }
    }
}
