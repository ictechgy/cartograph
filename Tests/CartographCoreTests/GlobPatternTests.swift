import CartographCore
import Foundation
import Testing

@Suite("GlobPattern")
struct GlobPatternTests {
    @Test("구분자 없는 패턴은 마지막 경로 요소에만 적용된다")
    func matchesLastComponentOnly() {
        let pattern = GlobPattern("*.swift")
        #expect(pattern.matches("Sources/App/Main.swift"))
        #expect(pattern.matches("Main.swift"))
        #expect(!pattern.matches("Sources/App/Main.m"))
    }

    @Test("단일 별표는 경로 구분자를 넘지 않는다")
    func singleStarDoesNotCrossSeparator() {
        let pattern = GlobPattern("Sources/*/Main.swift")
        #expect(pattern.matches("Sources/App/Main.swift"))
        #expect(!pattern.matches("Sources/App/Nested/Main.swift"))
    }

    @Test("이중 별표는 세그먼트를 0개 이상 소비한다")
    func doubleStarMatchesAnyDepth() {
        let pattern = GlobPattern("Sources/**/Main.swift")
        #expect(pattern.matches("Sources/Main.swift"))
        #expect(pattern.matches("Sources/App/Main.swift"))
        #expect(pattern.matches("Sources/App/Feature/Main.swift"))
        #expect(!pattern.matches("Tests/App/Main.swift"))
    }

    @Test("접미 이중 별표는 하위 전체를 포함한다")
    func trailingDoubleStar() {
        let pattern = GlobPattern("Sources/**")
        #expect(pattern.matches("Sources"))
        #expect(pattern.matches("Sources/App/Main.swift"))
        #expect(!pattern.matches("Tests/App/Main.swift"))
    }

    @Test("물음표는 문자 하나에만 대응한다")
    func questionMarkMatchesSingleCharacter() {
        let pattern = GlobPattern("File?.swift")
        #expect(pattern.matches("File1.swift"))
        #expect(!pattern.matches("File12.swift"))
        #expect(!pattern.matches("File.swift"))
    }

    @Test("정규식 특수문자는 문자 그대로 취급한다")
    func regexMetacharactersAreLiteral() {
        #expect(GlobPattern("a.b").matches("a.b"))
        #expect(!GlobPattern("a.b").matches("axb"))
        #expect(GlobPattern("Foo+Bar").matches("Foo+Bar"))
        #expect(GlobPattern("(x)").matches("(x)"))
    }

    @Test("백트래킹이 필요한 패턴도 해결한다")
    func backtracking() {
        #expect(GlobPattern("*View*Controller").matches("HomeViewSubController"))
        #expect(GlobPattern("*a*b*c").matches("xxaxxbxxc"))
        #expect(!GlobPattern("*a*b*c").matches("xxaxxb"))
    }

    @Test("빈 패턴 목록은 어떤 값과도 일치하지 않는다")
    func emptyPatternListMatchesNothing() {
        let patterns: [GlobPattern] = []
        #expect(!patterns.matchesAny("anything"))
    }

    @Test("문자열 리터럴과 코딩을 지원한다")
    func literalAndCodable() throws {
        let pattern: GlobPattern = "Sources/**"
        let data = try JSONEncoder().encode(pattern)
        let decoded = try JSONDecoder().decode(GlobPattern.self, from: data)
        #expect(decoded == pattern)
        #expect(decoded.pattern == "Sources/**")
    }
}

@Suite("PathFilter")
struct PathFilterTests {
    @Test("include 가 비면 exclude 만 적용된다")
    func excludeOnly() {
        let filter = PathFilter(exclude: ["**/.build/**"])
        #expect(filter.allows("Sources/App/Main.swift"))
        #expect(!filter.allows("project/.build/checkouts/Foo.swift"))
    }

    @Test("include 가 있으면 화이트리스트로 동작한다")
    func includeActsAsAllowList() {
        let filter = PathFilter(include: ["Sources/**"])
        #expect(filter.allows("Sources/App/Main.swift"))
        #expect(!filter.allows("Tests/AppTests/MainTests.swift"))
    }

    @Test("exclude 가 include 보다 우선한다")
    func excludeWinsOverInclude() {
        let filter = PathFilter(include: ["Sources/**"], exclude: ["**/Generated/**"])
        #expect(!filter.allows("Sources/Generated/API.swift"))
    }

    @Test("passthrough 는 아무것도 거르지 않는다")
    func passthroughAllowsEverything() {
        #expect(PathFilter.passthrough.allows("any/path.swift"))
    }
}

@Suite("PathFilter 상대 경로 매칭")
struct PathFilterRelativeMatchingTests {
    @Test("프로젝트 기준 상대 글롭이 절대 경로에도 적용된다")
    func relativeGlobMatchesAbsolutePath() {
        // 인덱스는 절대 경로를 주지만 사용자는 Sources/** 처럼 쓴다.
        // 이 매칭이 없으면 설정이 조용히 아무것도 고르지 않아 정점이 0개가 된다.
        let filter = PathFilter(include: ["Sources/**"], basePath: "/Users/me/project")
        #expect(filter.allows("/Users/me/project/Sources/App/Main.swift"))
        #expect(!filter.allows("/Users/me/project/Tests/AppTests/MainTests.swift"))
    }

    @Test("기준 밖의 경로는 절대 경로로만 판단한다")
    func pathsOutsideBaseUseAbsoluteFormOnly() {
        let filter = PathFilter(include: ["Sources/**"], basePath: "/Users/me/project")
        #expect(!filter.allows("/elsewhere/Sources/App/Main.swift"))
        #expect(PathFilter(include: ["**/Sources/**"], basePath: "/Users/me/project")
            .allows("/elsewhere/Sources/App/Main.swift"))
    }

    @Test("상대 글롭으로도 제외할 수 있다")
    func relativeExclude() {
        let filter = PathFilter(exclude: ["Generated/**"], basePath: "/p")
        #expect(!filter.allows("/p/Generated/API.swift"))
        #expect(filter.allows("/p/Sources/API.swift"))
    }

    @Test("기준이 없으면 절대 경로만 본다")
    func withoutBasePath() {
        let filter = PathFilter(include: ["Sources/**"])
        #expect(!filter.allows("/p/Sources/A.swift"))
        #expect(filter.allows("Sources/A.swift"))
    }

    @Test("기준 경로의 마지막 슬래시 유무는 결과를 바꾸지 않는다")
    func trailingSlashIsIrrelevant() {
        #expect(PathFilter(include: ["Sources/**"], basePath: "/p/").allows("/p/Sources/A.swift"))
        #expect(PathFilter(include: ["Sources/**"], basePath: "/p").allows("/p/Sources/A.swift"))
    }
}

@Suite("경로 정규화")
struct PathNormalizationTests {
    @Test("심볼릭 링크로 지정한 기준 경로도 매칭된다")
    func symlinkedBasePathMatches() {
        // macOS 의 /tmp 는 /private/tmp 로의 심볼릭 링크다. 기준 경로 하나만 보면
        // 접두사가 맞지 않아 include 가 아무것도 고르지 않고 "정점 0개"가 된다.
        let filter = PathFilter(include: ["Sources/**"], basePath: "/tmp")
        #expect(filter.allows("/private/tmp/Sources/A.swift"))
        #expect(filter.allows("/tmp/Sources/A.swift"))
        #expect(!filter.allows("/private/tmp/Tests/A.swift"))
    }

    @Test("물결표 기준 경로도 풀어서 본다")
    func tildeBasePathIsExpanded() {
        let home = NSHomeDirectory()
        let filter = PathFilter(include: ["Sources/**"], basePath: "~")
        #expect(filter.allows("\(home)/Sources/A.swift"))
    }

    @Test("빈 패턴은 크래시하지 않고 아무것도 고르지 않는다")
    func emptyPatternIsSafe() {
        // 빈 패턴은 실질적으로 아무것도 고르지 않는다. 크래시하지 않는 것이 요점이다.
        #expect(!GlobPattern("").matches("Sources/A.swift"))
        #expect(!GlobPattern("").matches("A.swift"))
        #expect(PathFilter(include: [""]).allows("Sources/A.swift") == false)
    }
}
