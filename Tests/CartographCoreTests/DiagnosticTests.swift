import CartographCore
import Testing

@Suite("Diagnostic")
struct DiagnosticTests {
    @Test("심각도가 높은 진단이 먼저 온다")
    func severityOrdering() {
        let warning = Diagnostic(ruleIdentifier: "a", severity: .warning, message: "w")
        let error = Diagnostic(ruleIdentifier: "z", severity: .error, message: "e")
        #expect([warning, error].sorted() == [error, warning])
        #expect(Diagnostic.Severity.info < .warning)
        #expect(Diagnostic.Severity.warning < .error)
    }

    @Test("같은 심각도면 규칙 식별자와 위치 순으로 정렬된다")
    func ruleAndLocationOrdering() {
        let first = Diagnostic(
            ruleIdentifier: "cycle",
            severity: .warning,
            message: "m",
            location: SourceLocation(path: "A.swift", line: 1, column: 1)
        )
        let second = Diagnostic(
            ruleIdentifier: "cycle",
            severity: .warning,
            message: "m",
            location: SourceLocation(path: "A.swift", line: 9, column: 1)
        )
        #expect([second, first].sorted() == [first, second])
    }

    @Test("위치가 있는 진단이 위치 없는 진단보다 앞선다")
    func locatedBeforeUnlocated() {
        let located = Diagnostic(
            ruleIdentifier: "r",
            severity: .warning,
            message: "m",
            location: SourceLocation(path: "A.swift", line: 1, column: 1)
        )
        let unlocated = Diagnostic(ruleIdentifier: "r", severity: .warning, message: "m")
        #expect([unlocated, located].sorted() == [located, unlocated])
    }

    @Test("지문은 줄 번호에 영향받지 않는다")
    func fingerprintIgnoresLineNumbers() {
        let makeDiagnostic = { (line: Int) in
            Diagnostic(
                ruleIdentifier: "unused-symbol",
                severity: .warning,
                message: "unused",
                location: SourceLocation(path: "A.swift", line: line, column: 1),
                subject: "s:3App3FooV"
            )
        }
        #expect(makeDiagnostic(1).fingerprint == makeDiagnostic(120).fingerprint)
        #expect(makeDiagnostic(1).fingerprint == "unused-symbol|s:3App3FooV")
    }

    @Test("subject 가 없으면 메시지로 지문을 만든다")
    func fingerprintFallsBackToMessage() {
        let diagnostic = Diagnostic(ruleIdentifier: "cycle", severity: .error, message: "A -> B -> A")
        #expect(diagnostic.fingerprint == "cycle|A -> B -> A")
    }

    @Test("상대 경로 변환은 위치만 바꾼다")
    func relativeConversion() {
        let diagnostic = Diagnostic(
            ruleIdentifier: "r",
            severity: .warning,
            message: "m",
            location: SourceLocation(path: "/project/A.swift", line: 2, column: 1),
            subject: "s"
        )
        let relative = diagnostic.relative(to: "/project")
        #expect(relative.location?.path == "A.swift")
        #expect(relative.subject == "s")
        #expect(relative.message == "m")
    }
}
