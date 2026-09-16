import CartographCore
import CartographSyntax
import Testing

@Suite("import 스캔")
struct ImportScannerTests {
    private let analyzer = SwiftSyntaxAnalyzer()

    private func imports(in source: String) -> [IndexedImport] {
        analyzer.analyze(source: source, path: "/p/A.swift").imports ?? []
    }

    @Test("평범한 import의 모듈 경로와 위치를 읽는다")
    func readsPlainImport() {
        let facts = imports(in: "import Foundation\nimport CartographCore\n")
        #expect(facts.count == 2)
        #expect(facts[0].modulePath == ["Foundation"])
        #expect(facts[0].location.line == 1)
        #expect(facts[1].modulePath == ["CartographCore"])
        #expect(!facts[0].isConditional && !facts[0].isReexported && !facts[0].isIgnored)
        #expect(facts[0].scopedKind == nil)
    }

    @Test("하위 경로와 선언 종류 좁힘을 구분한다")
    func readsScopedAndSubmoduleImports() {
        let facts = imports(in: "import struct Foundation.Bundle\nimport Foundation.Networking\n")
        #expect(facts[0].modulePath == ["Foundation", "Bundle"])
        #expect(facts[0].scopedKind == "struct")
        #expect(facts[0].module == "Foundation")
        // 진단 메시지에는 소스에 적힌 좁힌 형태 그대로를 쓴다.
        #expect(facts[0].spelling == "struct Foundation.Bundle")
        #expect(facts[1].modulePath == ["Foundation", "Networking"])
        #expect(facts[1].scopedKind == nil)
        #expect(facts[1].spelling == "Foundation.Networking")
    }

    @Test("@_exported와 public import를 재수출로 표시한다")
    func marksReexportingImports() {
        let facts = imports(in: """
            @_exported import Foundation
            public import CartographCore
            internal import CartographSyntax
            @_implementationOnly import CartographAnalysis
            @testable import CartographKit
            """)
        #expect(facts.map(\.isReexported) == [true, true, false, false, false])
    }

    @Test("#if 절 안쪽의 import를 조건부로 표시한다")
    func marksConditionalImports() {
        let facts = imports(in: """
            import Foundation
            #if canImport(UIKit)
            import UIKit
            #else
            import Glibc
            #endif
            """)
        #expect(facts.map(\.module) == ["Foundation", "UIKit", "Glibc"])
        #expect(facts.map(\.isConditional) == [false, true, true])
    }

    @Test("무시 주석이 붙은 import를 표시한다")
    func marksIgnoredImports() {
        let facts = imports(in: "import Foundation // cartograph:ignore\nimport CartographCore\n")
        #expect(facts.map(\.isIgnored) == [true, false])
    }

    @Test("import가 없는 파일은 빈 목록을 준다")
    func noImports() {
        #expect(imports(in: "let x = 1\n").isEmpty)
    }
}
