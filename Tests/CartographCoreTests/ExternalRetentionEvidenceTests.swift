import CartographCore
import Testing

@Suite("외부 보존 근거 문장의 생략 호출 수 경계")
struct ExternalRetentionEvidenceTests {
    private static func caller(_ line: Int) -> ExternalRetention.Caller {
        .init(platform: "dart", path: "lib/c\(line).dart", line: line)
    }

    private static func retention(callerCount: Int, omitted: Int) -> ExternalRetention {
        let callers = (1...callerCount).map(caller)
        return ExternalRetention(
            symbol: .init(usr: "s:x", qualifiedName: nil),
            reason: "bridge",
            evidence: .init(channel: "c", method: "m", caller: callers[0], callers: callers, callersOmitted: omitted)
        )
    }

    /// 근거 파일은 다른 도구가 만든 신뢰할 수 없는 입력이다. 로더는 음수만 거부하므로
    /// 표시하지 못한 호출 수와 생산자의 생략 수를 더하는 순간 Int 범위를 넘을 수 있다.
    @Test("생산자의 생략 수가 Int 상한이어도 근거 문장은 트랩 없이 상한으로 포화한다",
          arguments: [(4, Int.max), (9, Int.max), (4, Int.max - 1)])
    func saturatesOverflowingOmittedCount(callerCount: Int, omitted: Int) {
        #expect(
            Self.retention(callerCount: callerCount, omitted: omitted).evidenceDescription
                == "dart lib/c1.dart:1, dart lib/c2.dart:2, dart lib/c3.dart:3, +\(Int.max) more "
                    + "invokes 'm' on channel 'c'"
        )
    }

    @Test("범위 안의 생략 수는 표시하지 못한 호출 수와 정확히 더한다")
    func addsOmittedCountWithinRange() {
        #expect(
            Self.retention(callerCount: 4, omitted: 5).evidenceDescription
                == "dart lib/c1.dart:1, dart lib/c2.dart:2, dart lib/c3.dart:3, +6 more invokes 'm' on channel 'c'"
        )
    }
}
