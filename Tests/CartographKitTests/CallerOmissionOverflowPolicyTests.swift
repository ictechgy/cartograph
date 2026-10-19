import CartographCore
@testable import CartographKit
import CartographTestSupport
import Testing

/// 외부 근거의 호출자 생략 수가 넘칠 때 `impact` 와 `dead --explain` 이 같은 정책으로 답하는지 고정한다.
///
/// 생략 수는 다른 도구가 쓴 값이라 상한이 없다. 한 경로는 거부하고 다른 경로는 Int.max 로 포화하면,
/// 같은 근거 파일에 한 명령은 종료 코드 2 를, 다른 명령은 정확해 보이는 하한을 낸다.
@Suite("외부 근거 호출자 생략 수의 넘침 정책")
struct CallerOmissionOverflowPolicyTests {
    /// 두 경로가 함께 던져야 하는 오류. 영향 경로가 먼저 정한 문장이다.
    private static let overflow = CartographError.invalidConfiguration(
        path: "/p", reason: "Runtime evidence caller omission count exceeds the supported range."
    )

    /// 핸들러 하나를 다른 플랫폼의 호출 `callerCount` 개와 생산자 생략 수 `omitted` 로 살리는 근거 파일.
    private static func retentions(callerCount: Int, omitted: Int) -> String {
        let callers = (1...callerCount).map { #"{"platform":"dart","path":"lib/c\#($0).dart","line":\#($0)}"# }
        return #"{"format":"external-retentions","version":0,"retentions":[{"symbol":{"usr":"s:handle"},"#
            + #""reason":"bridge","evidence":{"channel":"c","method":"m","caller":\#(callers[0]),"#
            + #""callers":[\#(callers.joined(separator: ","))],"callersOmitted":\#(omitted)}}]}"#
    }

    /// 같은 근거 파일과 같은 인덱스로 두 명령을 모두 부르는 서비스.
    private static func makeService(callerCount: Int, omitted: Int) -> CartographService {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 7, parent: "s:CameraPlugin")
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.externalRetentionsPath = "/p/retentions.json"
        let file = retentions(callerCount: callerCount, omitted: omitted)
        return CartographService(configuration: configuration, environment: CartographEnvironment(
            fileSystem: InMemoryFileSystem(files: ["/p/retentions.json": file]),
            indexProviderOverride: StaticIndexProvider(builder.build())
        ))
    }

    @Test("생략 수가 넘치는 근거 파일에는 impact 와 dead --explain 이 같은 오류로 거부한다")
    func bothPathsRejectOverflowWithTheSameError() {
        let service = Self.makeService(callerCount: 4, omitted: .max)
        #expect(throws: Self.overflow) { try service.impactDocument(symbols: ["s:handle"], limit: 1) }
        #expect(throws: Self.overflow) { try service.explainRetention(of: "s:handle") }
        // 멤버의 근거로 산 타입의 설명도 같은 근거 문장을 인용하므로 함께 거부한다.
        #expect(throws: Self.overflow) { try service.explainRetention(of: "CameraPlugin") }
    }

    @Test("각 경로는 자기가 적을 수가 넘칠 때만 거부하고, 범위 안이면 정확한 수를 적는다")
    func eachPathRejectsOnlyItsOwnUnrepresentableCount() throws {
        // 호출 4개·생략 Int.max-1: 설명은 호출 1개를 숨겨 정확히 Int.max 를 적는다. impact --limit 1 은
        // 3개를 숨겨 넘치므로 거부하고, 기본 한도는 숨기는 호출이 없어 생산자의 수를 그대로 싣는다.
        let boundary = Self.makeService(callerCount: 4, omitted: .max - 1)
        #expect(try boundary.explainRetention(of: "s:handle").output.contains(", +\(Int.max) more invokes 'm'"))
        #expect(throws: Self.overflow) { try boundary.impactDocument(symbols: ["s:handle"], limit: 1) }
        let uncapped = try boundary.impactDocument(symbols: ["s:handle"])
        #expect(uncapped.runtimeReview.first?.externalEvidence.first?.callersOmitted == .max - 1)

        let small = Self.makeService(callerCount: 4, omitted: 5)
        #expect(try small.explainRetention(of: "s:handle").output.contains(", +6 more invokes 'm'"))
        let capped = try small.impactDocument(symbols: ["s:handle"], limit: 1)
        #expect(capped.runtimeReview.first?.externalEvidence.first?.callersOmitted == 8)
    }
}
