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

    @Test("연속된 이중 별표는 하나와 같다")
    func consecutiveDoubleStarsCollapse() {
        let collapsed = GlobPattern("**/Main.swift")
        let spread = GlobPattern("**/**/**/Main.swift")
        let values = [
            "Main.swift", "Sources/Main.swift", "Sources/App/Feature/Main.swift",
            "Sources/App/Main.m", "Tests/App/Main.swift",
        ]
        for value in values {
            #expect(spread.matches(value) == collapsed.matches(value))
        }
        #expect(spread.matches("Sources/App/Feature/Main.swift"))
        #expect(!spread.matches("Sources/App/Feature/Main.m"))
    }

    @Test("떨어진 이중 별표는 각각 살아 있다")
    func separatedDoubleStarsSurvive() {
        let pattern = GlobPattern("**/a/**/b")
        #expect(pattern.matches("x/a/b"))
        #expect(pattern.matches("x/a/y/b"))
        #expect(!pattern.matches("x/c/b"))
        #expect(!pattern.matches("x/a/y/c"))
    }

    @Test("연속된 이중 별표가 많아도 매칭이 끝나야 한다")
    func manyConsecutiveDoubleStarsTerminate() {
        let deep = (0..<25).map { "dir\($0)" }.joined(separator: "/") + "/file.swift"
        let pattern = GlobPattern(Array(repeating: "**", count: 8).joined(separator: "/") + "/nomatch==")
        let start = Date()
        #expect(!pattern.matches(deep))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("떨어진 이중 별표도 실패 경로에서 조합 폭발하지 않는다")
    func manySeparatedDoubleStarsTerminate() {
        let prefix = Array(repeating: "**/a", count: 10).joined(separator: "/")
        let path = Array(repeating: "a", count: 25).joined(separator: "/")
        let clock = ContinuousClock()
        let start = clock.now
        #expect(!GlobPattern(prefix + "/missing").matches(path))
        #expect(clock.now - start < .seconds(1))
        // 실패를 빨리 돌려주는 것만으로는 부족하다. 같은 탐색의 성공도 남긴다.
        #expect(GlobPattern(prefix + "/missing").matches(path + "/missing"))
    }

    @Test("이중 별표는 빈 세그먼트와 절대 경로의 경계를 보존한다")
    func emptyAndAbsoluteSegments() {
        #expect(GlobPattern("/**/a/**/b").matches("/a/b"))
        #expect(GlobPattern("/**/a/**/b").matches("/x/a//y/b"))
        #expect(!GlobPattern("/**/a/**/b").matches("x/a/b"))
        #expect(GlobPattern("a/**/").matches("a/"))
        #expect(!GlobPattern("a/**/").matches("a"))
        #expect(GlobPattern("a/**/b?/*").matches("a/x/b1/"))
    }

    @Test("원문 글롭은 직렬화 왕복에도 보존된다")
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

    @Test("프로젝트 루트가 DerivedData 아래여도 소스가 제외되지 않는다")
    func defaultExcludesDoNotMatchAncestorDirectories() {
        // 제외를 절대 경로에도 물리면 프로젝트 루트의 *조상* 이름이 패턴에 걸린다.
        // 그러면 모든 파일이 제외되어 정점 0개가 되고, --strict 가 아무것도 분석하지
        // 않은 채 통과한다. 같은 패키지를 이름만 다른 디렉터리 아래에 두고 재현했다.
        let filter = PathFilter(
            exclude: CartographConfiguration.defaultExcludes,
            basePath: "/Users/me/DerivedData/App"
        )
        #expect(filter.allows("/Users/me/DerivedData/App/Sources/A.swift"))
        // 프로젝트 *안*의 빌드 산출물은 여전히 제외된다.
        #expect(!filter.allows("/Users/me/DerivedData/App/.build/checkouts/Y/Node.swift"))
    }

    @Test("프로젝트 밖의 체크아웃은 절대 경로로 계속 제외된다")
    func excludesStillApplyOutsideTheProject() {
        // 기준 밖의 경로에는 상대 후보가 없다. 절대 경로로 판단하지 않으면
        // 프로젝트 밖에 체크아웃된 의존성을 걸러 내지 못한다.
        let filter = PathFilter(exclude: CartographConfiguration.defaultExcludes, basePath: "/Users/me/App")
        #expect(
            !filter.allows(
                "/Users/me/Library/Developer/Xcode/DerivedData/App-abc/SourcePackages/checkouts/Y/N.swift"
            )
        )
    }

    @Test("사용자가 쓴 제외 글롭도 조상 디렉터리에 걸리지 않는다")
    func userExcludesDoNotMatchAncestorDirectories() {
        // 기본 목록만의 문제가 아니다. cartograph init 이 써 주는 템플릿도 같은 모양이라,
        // 한쪽만 고치면 설정을 한 번 만든 순간 결함이 되살아난다.
        let filter = PathFilter(exclude: ["**/Normal/**"], basePath: "/x/Normal/proj")
        #expect(filter.allows("/x/Normal/proj/Sources/A.swift"))
        #expect(!filter.allows("/x/Normal/proj/Normal/B.swift"))
    }

    @Test("절대 경로로 쓴 제외 글롭은 그대로 적용된다")
    func absoluteExcludePatternsStillMatchAbsolutePaths() {
        // 절대 경로를 일부러 적은 사람의 의도는 분명하다. 상대 후보로만 보면 그 의도가 사라진다.
        let filter = PathFilter(exclude: ["/x/App/Vendor/**"], basePath: "/x/App")
        #expect(!filter.allows("/x/App/Vendor/Lib.swift"))
        #expect(filter.allows("/x/App/Sources/A.swift"))
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
    @Test("슬래시 없는 패턴은 경로의 어느 요소에나 맞는다")
    func slashlessPatternMatchesAnyComponent() {
        // gitignore 는 디렉터리 이름 하나로 그 아래 전부를 잡는다. 마지막 요소만
        // 보면 `retained_files: ["Generated"]` 가 아무것도 보존하지 못해, 지켜
        // 달라고 지정한 파일이 미사용으로 보고된다.
        #expect(GlobPattern("Pods").matches("/x/App/Pods/Alamofire/Source/Request.swift"))
        #expect(GlobPattern("Pods").matches("/x/App/Pods"))
        #expect(GlobPattern("Generated").matches("/x/App/Generated/API.swift"))
        #expect(!GlobPattern("Pods").matches("/x/App/PodsHelper/A.swift"))
        #expect(!GlobPattern("Pods").matches("/x/App/Sources/A.swift"))
        // 파일 이름 패턴은 그대로 동작한다.
        #expect(GlobPattern("*.swift").matches("/x/a/b.swift"))
        // 심볼 이름에는 구분자가 없어 영향이 없다.
        #expect(GlobPattern("*ViewController").matches("HomeViewController"))
    }

}
