import CartographCore
@testable import CartographSyntax
import SwiftOperators
import SwiftParser
import SwiftSyntax
import Testing

/// 런타임 이름을 푸는 비용이 별칭 사슬 길이에 비례하는지 해석 횟수와 근거 수로 확인한다. 시간은 재지 않는다.
///
/// `x1 = x0 + x0` 처럼 앞 별칭을 두 번 쓰는 사슬은 메모가 없으면 단계마다 해석과 이름 근거가 두 배가 된다.
/// 빈 문자열에서 시작하면 4096바이트 상한에도 걸리지 않아, 25줄짜리 파일 하나로 기본 분석 경로가 수십 GB 를 썼다.
@Suite("런타임 이름 해석 비용")
struct RuntimeNameResolutionCostTests {
    private let path = "/p/Names.swift"

    private static func plus(_: Int, _ previous: String) -> String { "\(previous) + \(previous)" }
    private static func interpolation(_: Int, _ previous: String) -> String { "\"\\(\(previous))\\(\(previous))\"" }
    private static func mixed(_ step: Int, _ previous: String) -> String {
        step.isMultiple(of: 2) ? plus(step, previous) : interpolation(step, previous)
    }

    /// `seed` 에서 시작해 단계마다 앞 별칭으로 새 식을 만드는 사슬.
    private func chain(_ count: Int, seed: String = "", _ step: (Int, String) -> String) -> [String] {
        ["let x0 = \"\(seed)\""] + (1...count).map { "let x\($0) = \(step($0, "x\($0 - 1)"))" }
    }

    /// 사슬 끝 별칭을 파일 범위 클래스 조회 인자로 풀고, 실제로 계산한 해석 횟수와 보간이 만든 가장 긴 글자의
    /// 바이트 수를 함께 돌려준다.
    private func resolve(
        _ lines: [String]
    ) throws -> (name: RuntimeResolvedName?, evaluations: Int, largestInterpolation: Int) {
        let source = (lines + ["_ = NSClassFromString(x\(lines.count - 1))"]).joined(separator: "\n")
        let parsed = Parser.parse(source: source)
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }.as(SourceFileSyntax.self) ?? parsed
        let bindings = RuntimeBindingCollector(converter: SourceLocationConverter(fileName: path, tree: tree))
        bindings.walk(tree)
        let finder = LookupArgumentFinder()
        finder.walk(tree)
        let argument = try #require(finder.argument)
        let name = bindings.resolveName(argument, in: .init(scopes: [], types: []))
        return (name, bindings.resolutionCount, bindings.largestInterpolatedByteCount)
    }

    private func lookup(_ lines: [String]) -> RuntimeBoundary? {
        RuntimeFactScanner().scan(source: lines.joined(separator: "\n"), path: path)
            .boundaries.first { $0.kind == .classLookup }
    }

    @Test("앞 별칭을 두 번 쓰는 사슬은 바인딩마다 한 번만 풀어 해석 횟수가 단계 수에 비례한다")
    func branchingChainsResolveEachBindingOnce() throws {
        for (label, step) in [("plus", Self.plus), ("interpolation", Self.interpolation), ("mixed", Self.mixed)] {
            for count in [6, 12] {
                let result = try resolve(chain(count, step))
                #expect(result.name?.text == "", "\(label) \(count)")
                // 메모가 없으면 단계마다 두 배가 되어 2^(단계+1) 번 남짓 푼다.
                #expect(result.evaluations <= 6 * count + 6, "\(label) \(count): \(result.evaluations)")
            }
        }
    }

    @Test("갈라지는 사슬의 이름 근거는 연산자마다 한 번씩 처음 나온 순서로 싣는다")
    func branchingChainsKeepEachProofOnce() {
        // 중복을 지우지 않으면 2¹² - 1 개가 실린다. 근거는 모두 검증할 집합이라 하나씩이면 판정이 같다.
        let plus = lookup(chain(12, Self.plus) + ["_ = NSClassFromString(x12)"])
        #expect(plus?.name == "")
        #expect(plus?.nameAPIReferences?.map(\.api) == Array(repeating: "String.+", count: 12))
        #expect(plus?.nameAPIReferences?.map(\.location.line) == Array(2...13))
        // 보간 결합도 같은 근거를 두 번 싣지 않는다. `+` 는 짝수 단계(3, 5, …, 13번째 줄)에만 있다.
        let mixed = lookup(chain(12, Self.mixed) + ["_ = NSClassFromString(x12)"])
        #expect(mixed?.name == "")
        #expect(mixed?.nameAPIReferences?.map(\.location.line) == Array(stride(from: 3, through: 13, by: 2)))
    }

    @Test("한 번에 셋으로 갈라지는 보간 사슬도 4096바이트를 넘으면 더 붙이지 않고 동적 이름으로 남긴다")
    func wideInterpolationStopsAtByteLimit() throws {
        // 상한이 빠져도 답(동적 이름·이유)은 같고 붙잡는 글자만 커진다. 그래서 만든 글자의 최대 바이트 수를
        // 직접 본다. 상한이 없어도 수십 KB 로 끝나는 10단계(3¹⁰ = 59,049바이트)라 실패도 단언으로 드러난다.
        let wide = chain(10, seed: "a") { _, previous in "\"\\(\(previous))\\(\(previous))\\(\(previous))\"" }
        let result = try resolve(wide)
        #expect(result.largestInterpolation <= RuntimeResolvedName.maximumByteCount, "\(result.largestInterpolation)")
        #expect(result.name?.text == nil)
        #expect(result.name?.origin == .dynamic)
        #expect(result.name?.reason == "runtime-name-exceeds-4096-bytes")
        let boundary = lookup(wide + ["_ = NSClassFromString(x10)"])
        #expect(boundary?.name == nil)
        #expect(boundary?.reason == "runtime-name-exceeds-4096-bytes")
        // 상한 바로 아래(3⁷ = 2187 바이트)는 지금처럼 그대로 풀리고, 관찰 지점도 그 길이를 센다.
        let narrow = try resolve(
            chain(7, seed: "a") { _, previous in "\"\\(\(previous))\\(\(previous))\\(\(previous))\"" }
        )
        #expect(narrow.name?.text == String(repeating: "a", count: 2_187))
        #expect(narrow.largestInterpolation == 2_187)
    }

    @Test("메모가 있어도 별칭 깊이 예산은 호출 자리마다 그대로 적용된다")
    func memoKeepsAliasDepthBudget() {
        // a63 까지는 예산 64 안에서 풀리고 a64 는 넘친다. 넘친 자리를 먼저 풀어도 뒤 자리의 답이 바뀌면 안 된다.
        let aliases = ["let a1 = \"App.Controller\""] + (2...64).map { "let a\($0) = a\($0 - 1)" }
        let source = aliases + ["_ = NSClassFromString(a64)", "_ = NSClassFromString(a63)"]
        let lookups = RuntimeFactScanner().scan(source: source.joined(separator: "\n"), path: path)
            .boundaries.filter { $0.kind == .classLookup }
        #expect(lookups.map(\.name) == [nil, "App.Controller"])
    }
}

/// 파일의 첫 `NSClassFromString` 인자를 찾는다.
private final class LookupArgumentFinder: SyntaxVisitor {
    private(set) var argument: ExprSyntax?

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if argument == nil, node.calledExpression.trimmedDescription == "NSClassFromString" {
            argument = node.arguments.first?.expression
        }
        return .visitChildren
    }
}
