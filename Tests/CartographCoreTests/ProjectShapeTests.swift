import CartographCore
import Testing

@Suite("프로젝트 형태별 빌드 안내")
struct ProjectShapeTests {
    @Test("패키지 루트에는 swift build 만 안내한다")
    func packageRootGetsOnlySwiftBuild() {
        // 패키지에 xcodebuild 를 권하면 절반이 틀린 안내다.
        let shape = ProjectShape(hasPackageManifest: true)
        #expect(shape.remedy.contains("swift build"))
        #expect(!shape.remedy.contains("xcodebuild"))
    }

    @Test(".build 가 있으면 빌드가 아니라 해석만 됐던 것이라고 말한다")
    func buildDirectoryIsExplained() {
        let resolved = ProjectShape(hasPackageManifest: true, hasBuildDirectory: true)
        #expect(resolved.remedy.contains(".build"))

        let fresh = ProjectShape(hasPackageManifest: true)
        #expect(!fresh.remedy.contains(".build directory exists"))
    }

    @Test("Xcode 프로젝트에는 스킴을 실은 xcodebuild 만 안내한다")
    func xcodeRootGetsSchemeFlag() {
        // -scheme 없는 xcodebuild 는 그대로 실행하면 실패한다.
        let shape = ProjectShape(hasPackageManifest: false, xcodeDocuments: ["App.xcodeproj"])
        #expect(shape.remedy.contains("-project 'App.xcodeproj'"))
        #expect(shape.remedy.contains("-scheme"))
        #expect(shape.remedy.contains("COMPILER_INDEX_STORE_ENABLE"))
        #expect(shape.remedy.contains("xcodebuild -list"))
        #expect(!shape.remedy.contains("swift build"))
    }

    @Test("워크스페이스가 있으면 프로젝트 대신 워크스페이스로 빌드한다")
    func workspaceIsPreferredOverProject() {
        // 워크스페이스로 빌드해야 패키지까지 같이 인덱싱되는 구성이 흔하다.
        let shape = ProjectShape(
            hasPackageManifest: false,
            xcodeDocuments: ["App.xcworkspace", "App.xcodeproj"]
        )
        #expect(shape.remedy.contains("-workspace 'App.xcworkspace'"))
        #expect(!shape.remedy.contains("-project 'App.xcodeproj'"))
    }

    @Test("워크스페이스가 여럿이면 정렬 첫 개가 아니라 자리표시자를 둔다")
    func multipleWorkspacesGetAPlaceholder() {
        // 이름순 첫 워크스페이스를 고르면 사용자가 의도한 것이 아닐 수 있다 —
        // 문서가 여럿이면 어느 것을 빌드할지 사용자가 골라야 한다.
        let shape = ProjectShape(
            hasPackageManifest: false,
            xcodeDocuments: ["A.xcworkspace", "B.xcworkspace"]
        )
        #expect(shape.remedy.contains("-workspace <workspace>"))
        #expect(!shape.remedy.contains("A.xcworkspace"))
    }

    @Test("공백이 든 문서 이름은 따옴표로 감싸 명령이 깨지지 않게 한다")
    func spacedDocumentNameIsQuoted() {
        let shape = ProjectShape(
            hasPackageManifest: false,
            xcodeDocuments: ["My App.xcworkspace"]
        )
        #expect(shape.remedy.contains("-workspace 'My App.xcworkspace'"))
    }

    @Test("셸 특수문자가 든 이름도 확장·탈출 없이 인용된다")
    func shellMetacharactersStayQuoted() {
        // 큰따옴표 인용은 `$`·역따옴표를 여전히 확장하고 `"` 로 닫힌다.
        // 작은따옴표 + `'\''` 닫기는 어떤 이름이든 한 인자로 유지한다.
        let shape = ProjectShape(
            hasPackageManifest: false,
            xcodeDocuments: ["it's$HOME`x\"y\\z.xcodeproj"]
        )
        #expect(shape.remedy.contains("-project 'it'\\''s$HOME`x\"y\\z.xcodeproj'"))
    }

    @Test("문서가 여럿이면 어느 것인지 고르라는 자리표시자를 둔다")
    func multipleProjectsGetAPlaceholder() {
        let shape = ProjectShape(
            hasPackageManifest: false,
            xcodeDocuments: ["A.xcodeproj", "B.xcodeproj"]
        )
        #expect(shape.remedy.contains("-project <project>"))
    }

    @Test("패키지와 Xcode 문서가 함께 있으면 둘 다 보여 준다")
    func dualRootShowsBoth() {
        let shape = ProjectShape(hasPackageManifest: true, xcodeDocuments: ["App.xcodeproj"])
        #expect(shape.remedy.contains("swift build"))
        #expect(shape.remedy.contains("xcodebuild"))
    }

    @Test("빌드 진입점이 없으면 프로젝트 경로를 의심하게 한다")
    func unidentifiedRootSuspectsThePath() {
        // `ios/` 같은 하위 디렉터리를 가리킨 경우가 흔하다.
        let shape = ProjectShape(hasPackageManifest: false)
        #expect(shape.remedy.contains("--project"))
        #expect(shape.remedy.contains("--index-store"))
    }

    @Test("buildCommands 는 다른 문장에 끼울 명령 줄만 돌려준다")
    func buildCommandsAreBareLines() {
        let shape = ProjectShape(hasPackageManifest: true)
        #expect(shape.buildCommands == ["swift build"])

        let unknown = ProjectShape(hasPackageManifest: false)
        #expect(unknown.buildCommands.count == 2)
    }
}
