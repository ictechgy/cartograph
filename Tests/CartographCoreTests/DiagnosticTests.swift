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

@Suite("DerivedData 탐색 결과 문장")
struct DerivedDataSearchTests {
    private func search(
        rootExists: Bool = true,
        matched: Int,
        withStore: Int
    ) -> DerivedDataSearch {
        DerivedDataSearch(
            root: "/dd",
            rootExists: rootExists,
            names: ["HealthMap", "ios"],
            matchedDirectoryCount: matched,
            storeDirectoryCount: withStore
        )
    }

    @Test("루트가 없으면 그것만 말한다")
    func missingRoot() {
        let explanation = search(rootExists: false, matched: 0, withStore: 0).explanation
        #expect(explanation.contains("no DerivedData directory at /dd"))
    }

    @Test("이름이 하나도 안 맞으면 시도한 이름을 전부 알린다")
    func nothingMatched() {
        // 이름이 안 맞으면 후보 경로가 한 줄도 생기지 않아, 검색 목록만으로는
        // 도구가 그곳을 보기라도 했는지 알 수 없었다.
        let explanation = search(matched: 0, withStore: 0).explanation
        #expect(explanation.contains("'HealthMap', 'ios'"))
        #expect(explanation.contains("after the document it opened"))
    }

    @Test("이름은 맞았는데 스토어가 없으면 빌드를 먼저 가리킨다")
    func matchedButNeverBuilt() {
        // 여기서 빌드 설정부터 시키면 안 된다. Xcode 의 보통 빌드는 그 설정 없이도
        // 인덱스를 남기므로, 흔한 원인은 아직 빌드하지 않았거나 DerivedData 를 지운 것이다.
        let explanation = search(matched: 2, withStore: 0).explanation
        #expect(explanation.contains("has not been built there yet"))
        #expect(explanation.contains("DerivedData was cleaned"))
    }

    @Test("스토어는 있는데 남의 것이면 그렇게 말한다")
    func matchedButNotOwned() {
        let explanation = search(matched: 2, withStore: 2).explanation
        #expect(explanation.contains("names a different project"))
        #expect(explanation.contains("--index-store"))
    }
}
