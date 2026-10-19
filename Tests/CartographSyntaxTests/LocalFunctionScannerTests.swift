import CartographCore
@testable import CartographSyntax
import SwiftParser
import SwiftSyntax
import Testing

/// 지역 함수 스캐너가 지역 함수 후보가 있는 본문만 깊이 훑는지 본문 순회 횟수로 확인한다. 시간은 재지 않는다.
///
/// 바깥 함수의 99% 는 지역 함수가 없다. 그 본문마다 참조 위치를 전부 모았다가 버리면 콜드 실행의 구문 분석
/// 단계 약 1/4 을 쓴다.
@Suite("지역 함수 스캐너")
struct LocalFunctionScannerTests {
    private let path = "/p/Local.swift"

    /// 분석기처럼 변환기를 넘겨 훑고, 본문을 끝까지 훑은 횟수를 함께 돌려준다.
    private func scan(_ source: String) -> (scopes: [LocalFunctionScopeFacts], bodyWalks: Int) {
        let tree = Parser.parse(source: source)
        var walks = 0
        let scopes = LocalFunctionScanner().scan(
            tree: tree, path: path, converter: SourceLocationConverter(fileName: path, tree: tree),
            onBodyWalk: { walks += 1 }
        )
        return (scopes, walks)
    }

    @Test("함수 선언이 없는 바깥 함수 본문은 참조를 모으려고 훑지 않는다")
    func walksOnlyBodiesWithNestedFunctions() {
        let plain = (0..<40).map {
            "func plain\($0)(value: Int) -> Int { let doubled = value * 2; return [doubled].map { $0 + \($0) }[0] }"
        }
        let source = (plain + ["func outer() {\n    func local() {}\n    local()\n}"]).joined(separator: "\n")
        let result = scan(source)
        #expect(result.scopes.map(\.ownerName) == ["outer"])
        #expect(result.scopes.first?.functions.map(\.name) == ["local"])
        #expect(result.bodyWalks == 1)
    }

    @Test("지역 타입·매크로 안에만 func 가 있으면 지금처럼 범위를 만들지 않는다")
    func ignoresFunctionsOnlyInsideLocalTypesAndMacros() {
        // 사전 검사는 이런 func 도 세는 과대 근사다. 본문을 끝까지 훑어도 지역 함수가 없어야 결과가 같다.
        let result = scan("""
            func typed() {
                struct Local { func method() {} }
                _ = Local()
            }
            func expanded() {
                #stringify({ func inner() {}; inner() })
            }
            """)
        #expect(result.scopes.isEmpty)
        #expect(result.bodyWalks == 2)
    }

    @Test("위치 재지정이 있는 파일의 지역 함수 범위는 그 이유를 그대로 싣는다")
    func keepsSourceLocationRemappingReason() {
        let result = scan("""
            func plain() -> Int { 1 }
            #sourceLocation(file: "Generated.swift", line: 10)
            func outer() {
                func local() {}
                local()
            }
            #sourceLocation()
            """)
        #expect(result.scopes.map(\.reason) == [.sourceLocationRemapping])
        #expect(result.scopes.first?.hasUnsupportedSyntax == true)
        #expect(result.bodyWalks == 1)
    }

    @Test("지역 함수가 없는 파일은 위치 재지정이 있어도 빈 결과다")
    func emptyWithoutLocalFunctions() {
        let result = scan("""
            #sourceLocation(file: "Generated.swift", line: 10)
            func plain() -> Int { let value = 1; return value }
            struct Holder { init() { _ = plain() }; deinit {} }
            #sourceLocation()
            """)
        #expect(result.scopes.isEmpty)
        #expect(result.bodyWalks == 0)
    }
}
