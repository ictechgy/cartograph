import CartographCore

/// 영향 결과의 테스트 신원을 보존 정책과 분리한다. 이름이나 unitTest 비트만으로 실행 대상을 확정하지 않는다.
public struct TestCandidateIdentity: Sendable, Equatable {
    /// XCTest 상속/메서드 또는 명시적 Swift Testing 선언 표식으로 확인한 후보.
    /// 실제 실행과 빌드 타깃 소속을 증명하는 값은 아니다.
    public let confirmed: Set<NodeID>
    /// 보존할 이유는 있지만 테스트 프레임워크 신원을 확인하지 못한 후보.
    public let uncertain: Set<NodeID>
    public let xctest: XCTestIdentityFacts

    public init(snapshot: IndexSnapshot) {
        let xctest = XCTestIdentityFacts(snapshot: snapshot)
        self.xctest = xctest
        let explicit = Set(snapshot.symbols.filter {
            !$0.isExternal && ($0.attributes.contains(.testFunction) || $0.attributes.contains(.testSuite))
        }.map(\.usr))
        let known = xctest.classUSRs.union(xctest.methodUSRs).union(explicit)
        confirmed = Set(known.map { NodeID($0) })
        uncertain = Set(xctest.uncertainUSRs.subtracting(known).map { NodeID($0) })
    }

    /// 영향 범위에서 정체 불명의 표식과 수신자 미확인 dispatch 투영을 숨기지 않는다.
    public func limitations(for report: ImpactReport) -> [String] {
        var result: [String] = []
        let reached = Set(report.changed + report.affected.map(\.node))
        let count = reached.intersection(uncertain).count
        if count > 0 {
            result.append("unverified-test-markers: \(count) reached declaration(s) have only test-like compiler/legacy markers; "
                + "they remain uncertain candidates, not verified tests or permission to skip tests")
        }
        let dispatch = report.affected.filter { $0.relationship == .dispatchCaller }.count
        if dispatch > 0 {
            result.append("dispatch-receiver-uncertainty: \(dispatch) caller(s) were projected through a dispatch contract; "
                + "runtime receiver selection is not proven, so sibling receiver callers may remain candidates")
        }
        return result
    }
}
