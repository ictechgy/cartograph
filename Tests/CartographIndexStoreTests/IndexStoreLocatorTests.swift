import CartographCore
@testable import CartographIndexStore
import CartographTestSupport
import Foundation
import Testing

@Suite("인덱스 스토어 탐색")
struct IndexStoreLocatorTests {
    @Test("명시 경로는 존재하면 그대로 쓴다")
    func explicitPathIsUsedAsIs() throws {
        let fileSystem = InMemoryFileSystem(files: ["/store/units/a": ""])
        let locator = IndexStoreLocator(fileSystem: fileSystem)
        #expect(try locator.locate(explicitPath: "/store", projectPath: "/p") == "/store")
    }

    @Test("명시 경로가 없으면 그 경로만 담은 오류가 난다")
    func missingExplicitPathThrows() {
        let locator = IndexStoreLocator(fileSystem: InMemoryFileSystem())
        #expect(throws: CartographError.self) {
            try locator.locate(explicitPath: "/nope", projectPath: "/p")
        }
    }

    @Test("SwiftPM 의 여러 인덱스 위치를 후보로 본다")
    func swiftPackageManagerCandidates() {
        let candidates = IndexStoreLocator().projectCandidates(projectPath: "/p")
        #expect(candidates.contains("/p/.build/index/store"))
        #expect(candidates.contains("/p/.build/debug/index/store"))
        #expect(candidates.contains("/p/.build/out"))
        #expect(candidates.contains("/p/.index-store"))
    }

    @Test("존재하는 후보 중 가장 최근 것을 고른다")
    func picksMostRecentCandidate() throws {
        // 오래된 인덱스로 분석하면 결과가 조용히 틀린다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/.build/index/store/units/a": "",
            "/p/.build/out/units/a": "",
        ])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 100), for: "/p/.build/index/store")
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 900), for: "/p/.build/out")

        let located = try IndexStoreLocator(fileSystem: fileSystem).locate(explicitPath: nil, projectPath: "/p")
        #expect(located == "/p/.build/out")
    }

    @Test("어디에도 없으면 찾아본 경로를 모두 알려 준다")
    func reportsSearchedPaths() {
        let locator = IndexStoreLocator(fileSystem: InMemoryFileSystem())
        do {
            _ = try locator.locate(explicitPath: nil, projectPath: "/p")
            Issue.record("오류가 발생해야 한다")
        } catch let error as CartographError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("/p/.build/index/store"))
            // 안내는 실제로 인덱스를 만드는 명령이어야 한다. -Xswiftc -index-store-path 는
            // Swift 6.4 기본 빌드 시스템에서 무시되므로 그것만 알려 주면 사용자가 막힌다.
            #expect(description.contains("swift build"))
            #expect(description.contains("-index-store-path is"))
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test("DerivedData 는 Xcode 14 이후와 이전 경로를 모두 본다")
    func derivedDataCandidatesCoverBothLayouts() {
        let fileSystem = InMemoryFileSystem(files: [
            "/dd/MyApp-abcdef/Index.noindex/DataStore/units/a": "",
            "/dd/Other-123/Index.noindex/DataStore/units/a": "",
        ])
        let candidates = IndexStoreLocator(fileSystem: fileSystem)
            .derivedDataCandidates(projectNames: ["MyApp"], derivedDataPath: "/dd")
        #expect(candidates.contains("/dd/MyApp-abcdef/Index.noindex/DataStore"))
        #expect(candidates.contains("/dd/MyApp-abcdef/Index/DataStore"))
        #expect(!candidates.contains { $0.contains("Other-123") })
    }

    @Test("DerivedData 디렉터리가 없으면 후보도 없다")
    func missingDerivedDataYieldsNoCandidates() {
        #expect(
            IndexStoreLocator(fileSystem: InMemoryFileSystem())
                .derivedDataCandidates(projectNames: ["MyApp"], derivedDataPath: "/nope")
                .isEmpty
        )
    }

    @Test("DerivedData 후보도 탐색에 포함된다")
    func derivedDataIsSearched() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/dd/p-abc/Index.noindex/DataStore/units/a": ""
        ])
        let located = try IndexStoreLocator(fileSystem: fileSystem)
            .locate(explicitPath: nil, projectPath: "/p", derivedDataPath: "/dd")
        #expect(located == "/dd/p-abc/Index.noindex/DataStore")
    }

    @Test("libIndexStore 는 개발자 디렉터리부터 찾는다")
    func libraryCandidatesStartWithDeveloperDirectory() {
        let candidates = IndexStoreLocator().libraryCandidates(developerDirectory: "/Xcode.app/Contents/Developer")
        #expect(candidates.first == "/Xcode.app/Contents/Developer"
            + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib")
        #expect(candidates.contains("/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib"))
    }

    @Test("존재하는 첫 라이브러리를 고르고 없으면 오류를 낸다")
    func locatesLibrary() throws {
        let path = "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib"
        let fileSystem = InMemoryFileSystem(files: [path: ""])
        let locator = IndexStoreLocator(fileSystem: fileSystem)
        #expect(try locator.locateLibrary(explicitPath: nil, developerDirectory: nil) == path)
        #expect(try locator.locateLibrary(explicitPath: path, developerDirectory: nil) == path)
        #expect(throws: CartographError.self) {
            try locator.locateLibrary(explicitPath: "/nope.dylib", developerDirectory: nil)
        }
        #expect(throws: CartographError.self) {
            try IndexStoreLocator(fileSystem: InMemoryFileSystem())
                .locateLibrary(explicitPath: nil, developerDirectory: nil)
        }
    }

    @Test("개발자 디렉터리는 환경 변수를 우선한다")
    func developerDirectoryPrefersEnvironment() {
        #expect(XcodeEnvironment.developerDirectory(environment: ["DEVELOPER_DIR": "/custom"]) == "/custom")
        #expect(XcodeEnvironment.developerDirectory(environment: ["DEVELOPER_DIR": ""]) != "")
    }
}

@Suite("DerivedData 이름 대조")
struct DerivedDataMatchingTests {
    @Test("이름이 접두사로 겹치는 다른 프로젝트를 집어삼키지 않는다")
    func prefixCollisionIsRejected() {
        // 접두사만 보면 App 이 App-Extension 의 디렉터리까지 가져가, 더 최근에
        // 빌드된 다른 프로젝트를 분석하게 된다.
        #expect(IndexStoreLocator.isDerivedDataDirectory("App-abcdefghijklmnop", forProject: "App"))
        #expect(!IndexStoreLocator.isDerivedDataDirectory("App-Extension-abcdef", forProject: "App"))
        #expect(!IndexStoreLocator.isDerivedDataDirectory("Application-abcdef", forProject: "App"))
        #expect(!IndexStoreLocator.isDerivedDataDirectory("App", forProject: "App"))
        #expect(!IndexStoreLocator.isDerivedDataDirectory("App-", forProject: "App"))
    }

    @Test("대소문자만 다른 표기도 같은 프로젝트로 본다")
    func matchingIsCaseInsensitive() {
        // APFS 는 기본이 대소문자 구분 없음이라 표기가 어긋나는 경우가 흔하다.
        #expect(IndexStoreLocator.isDerivedDataDirectory("cartograph-abcdef", forProject: "Cartograph"))
        #expect(IndexStoreLocator.isDerivedDataDirectory("Cartograph-abcdef", forProject: "cartograph"))
    }

    @Test("이름이 같은 다른 체크아웃의 DerivedData 를 쓰지 않는다")
    func picksTheDerivedDataDirectoryOfThisCheckout() {
        // 같은 프로젝트를 두 곳에 체크아웃하면 이름만으로는 구분되지 않는다.
        // 최근 빌드된 쪽을 고르는 규칙 때문에 다른 브랜치의 인덱스로 분석하고도
        // 아무 표시가 나지 않는다.
        let fileSystem = InMemoryFileSystem(files: [
            "/dd/App-aaaaaa/info.plist": Self.infoPlist(workspacePath: "/src/main/App/App.xcodeproj"),
            "/dd/App-aaaaaa/Index.noindex/DataStore/units/a": "",
            "/dd/App-bbbbbb/info.plist": Self.infoPlist(workspacePath: "/src/feature/App/App.xcodeproj"),
            "/dd/App-bbbbbb/Index.noindex/DataStore/units/a": "",
        ])
        let candidates = IndexStoreLocator(fileSystem: fileSystem)
            .derivedDataCandidates(projectNames: ["App"], derivedDataPath: "/dd", projectPath: "/src/main/App")
        #expect(candidates.contains("/dd/App-aaaaaa/Index.noindex/DataStore"))
        #expect(candidates.allSatisfy { !$0.contains("App-bbbbbb") })
    }

    @Test("표기가 달라도 같은 체크아웃으로 알아본다")
    func ownershipSurvivesSpellingDifferences() {
        // 대소문자, XML 엔티티, 끝 슬래시 중 하나만 어긋나도 소유권 판정이 통째로
        // 무효가 되어, 막으려던 "이름이 같은 다른 체크아웃" 상황으로 되돌아간다.
        #expect(IndexStoreLocator.workspacePath("/src/App/App.xcodeproj", belongsTo: "/src/App"))
        #expect(IndexStoreLocator.workspacePath("/SRC/app/App.xcodeproj", belongsTo: "/src/App"))
        #expect(IndexStoreLocator.workspacePath("/src/App", belongsTo: "/src/App/"))
        #expect(!IndexStoreLocator.workspacePath("/src/Other/App.xcodeproj", belongsTo: "/src/App"))
        // 접두사만 겹치는 다른 디렉터리를 삼키지 않는다.
        #expect(!IndexStoreLocator.workspacePath("/src/AppExtra/App.xcodeproj", belongsTo: "/src/App"))
    }

    @Test("속성 목록의 XML 엔티티를 되돌린다")
    func decodesPropertyListEntities() {
        let plist = "<key>WorkspacePath</key><string>/work/R&amp;D/App.xcodeproj</string>"
        #expect(
            IndexStoreLocator.stringValue(forKey: "WorkspacePath", inPropertyList: plist)
                == "/work/R&D/App.xcodeproj"
        )
    }

    @Test("info.plist 를 읽을 수 없으면 예전처럼 모두 후보로 둔다")
    func keepsEveryCandidateWhenOwnershipIsUnknown() {
        // 예전 Xcode 는 이 파일을 남기지 않는다. 못 읽는다고 후보를 다 버리면
        // 멀쩡히 있는 인덱스를 못 찾는다.
        let fileSystem = InMemoryFileSystem(files: [
            "/dd/App-aaaaaa/Index.noindex/DataStore/units/a": "",
            "/dd/App-bbbbbb/Index.noindex/DataStore/units/a": "",
        ])
        let candidates = IndexStoreLocator(fileSystem: fileSystem)
            .derivedDataCandidates(projectNames: ["App"], derivedDataPath: "/dd", projectPath: "/src/main/App")
        #expect(candidates.contains("/dd/App-aaaaaa/Index.noindex/DataStore"))
        #expect(candidates.contains("/dd/App-bbbbbb/Index.noindex/DataStore"))
    }

    @Test("트리플 디렉터리 아래의 인덱스도 후보로 본다")
    func perTripleCandidatesAreIncluded() throws {
        // 예전 SwiftPM 은 `.build/<트리플>/debug/index/store` 에 인덱스를 뒀다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/.build/arm64-apple-macosx/debug/index/store/units/a": "",
            "/p/.build/checkouts/other/file": "",
        ])
        let locator = IndexStoreLocator(fileSystem: fileSystem)
        let candidates = locator.projectCandidates(projectPath: "/p")
        #expect(candidates.contains("/p/.build/arm64-apple-macosx/debug/index/store"))
        // 트리플이 아닌 디렉터리는 오류 메시지를 늘리지 않도록 제외한다.
        #expect(candidates.allSatisfy { !$0.contains("checkouts") })

        let located = try locator.locate(explicitPath: nil, projectPath: "/p")
        #expect(located == "/p/.build/arm64-apple-macosx/debug/index/store")
    }

    /// DerivedData 디렉터리에 Xcode 가 남기는 속성 목록.
    private static func infoPlist(workspacePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        \t<key>LastAccessedDate</key>
        \t<date>2026-09-01T16:45:55Z</date>
        \t<key>WorkspacePath</key>
        \t<string>\(workspacePath)</string>
        </dict>
        </plist>
        """
    }

    @Test("폴더 이름이 달라도 루트의 .xcodeproj 이름으로 DerivedData 를 찾는다")
    func namesComeFromTheProjectDocument() throws {
        // Xcode 는 그 디렉터리를 연 문서의 이름으로 짓는다. Flutter·React Native 앱은
        // 전부 `ios/<이름>.xcodeproj` 라 폴더 이름은 `ios` 이고, 그것만 보면 못 찾는다.
        // 이 머신의 실제 앱 프로젝트 셋이 전부 그 모양이었다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/ios/HealthMap.xcodeproj/project.pbxproj": "",
            "/dd/HealthMap-abcdef/Index.noindex/DataStore/units/a": "",
        ])
        let located = try IndexStoreLocator(fileSystem: fileSystem)
            .locate(explicitPath: nil, projectPath: "/p/ios", derivedDataPath: "/dd")
        #expect(located == "/dd/HealthMap-abcdef/Index.noindex/DataStore")
    }

    @Test(".xcworkspace 이름도 DerivedData 이름 후보가 된다")
    func namesComeFromTheWorkspaceDocumentToo() throws {
        // CocoaPods 프로젝트는 워크스페이스로 연다. `.xcodeproj` 가 없을 수도 있다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/ios/Runner.xcworkspace/contents.xcworkspacedata": "",
            "/dd/Runner-abcdef/Index.noindex/DataStore/units/a": "",
        ])
        let located = try IndexStoreLocator(fileSystem: fileSystem)
            .locate(explicitPath: nil, projectPath: "/p/ios", derivedDataPath: "/dd")
        #expect(located == "/dd/Runner-abcdef/Index.noindex/DataStore")
    }

    @Test("프로젝트 파일이 있어도 디렉터리 이름 후보를 버리지 않는다")
    func theFolderNameStaysACandidate() {
        // Xcode 로 직접 연 Swift 패키지는 WorkspacePath 가 확장자 없는 디렉터리 자체이고,
        // 디렉터리 이름이 곧 DerivedData 이름이다. 이름을 교체해 버리면 그쪽이 깨진다.
        let fileSystem = InMemoryFileSystem(files: ["/p/App/Other.xcodeproj/project.pbxproj": ""])
        let names = IndexStoreLocator(fileSystem: fileSystem).projectNames(inProjectRoot: "/p/App")
        #expect(names.contains("Other"))
        #expect(names.contains("App"))
    }

    @Test("이름은 프로젝트 루트 한 단계에서만 모은다")
    func namesAreNotCollectedRecursively() {
        // 재귀하면 Pods/Pods.xcodeproj 나 번들 안의 중첩 프로젝트가 이름 후보가 되어
        // 남의 DerivedData 를 자기 것이라고 연다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/ios/Runner.xcodeproj/project.pbxproj": "",
            "/p/ios/Runner.xcodeproj/Nested.xcodeproj/project.pbxproj": "",
            "/p/ios/Pods/Pods.xcodeproj/project.pbxproj": "",
        ])
        let names = IndexStoreLocator(fileSystem: fileSystem).projectNames(inProjectRoot: "/p/ios")
        #expect(names == ["Runner", "ios"])
    }

    @Test("같은 이름의 프로젝트와 워크스페이스는 이름 후보를 한 번만 만든다")
    func duplicateNamesAreCollapsed() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App/App.xcodeproj/project.pbxproj": "",
            "/p/App/App.xcworkspace/contents.xcworkspacedata": "",
        ])
        let names = IndexStoreLocator(fileSystem: fileSystem).projectNames(inProjectRoot: "/p/App")
        #expect(names == ["App"])
    }

    @Test("프로젝트 경로를 워크스페이스의 하위 디렉터리로 좁혀도 소유가 인정된다")
    func ownershipHoldsWhenTheProjectPathIsNarrower() {
        // 표준 Xcode 배치는 `App/App.xcodeproj` 와 `App/App/` 이다. 소스 디렉터리만
        // 분석하는 것은 흔한 사용법이고, 그때 WorkspacePath 는 프로젝트 경로의 *부모* 를
        // 가리킨다. 한 방향만 보면 오늘 잘 돌던 분석이 통째로 실패한다.
        #expect(IndexStoreLocator.workspacePath("/src/App/App.xcodeproj", belongsTo: "/src/App/App"))
        #expect(IndexStoreLocator.workspacePath("/src/App/App.xcodeproj", belongsTo: "/src"))
        #expect(!IndexStoreLocator.workspacePath("/src/main/App/App.xcodeproj", belongsTo: "/src/feature/App"))
    }

    @Test("남의 체크아웃이라고 스스로 밝힌 DerivedData 는 후보가 되지 않는다")
    func selfDeclaredForeignDirectoriesAreNeverUsed() {
        // 소유가 증명된 것이 없다고 남의 것을 되살리면, 이름 후보가 넓어진 만큼
        // 남의 인덱스로 분석할 확률이 그대로 올라간다.
        let fileSystem = InMemoryFileSystem(files: [
            "/dd/App-aaaaaa/info.plist": Self.infoPlist(workspacePath: "/other/ios/App.xcodeproj"),
            "/dd/App-aaaaaa/Index.noindex/DataStore/units/a": "",
        ])
        let candidates = IndexStoreLocator(fileSystem: fileSystem)
            .derivedDataCandidates(projectNames: ["App"], derivedDataPath: "/dd", projectPath: "/p/ios")
        #expect(candidates.allSatisfy { !$0.contains("App-aaaaaa") })
    }

    @Test("이름만 맞은 후보가 둘 이상이면 고르지 않고 알린다")
    func ambiguousUnprovenCandidatesAreReported() {
        // 최근성으로 하나를 고르면 남의 인덱스로 분석하고도 아무 표시가 나지 않는다.
        // 같은 이름의 심볼이 여럿일 때 query 가 후보를 돌려주는 것과 같은 규칙이다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/ios/Runner.xcodeproj/project.pbxproj": "",
            "/dd/Runner-aaaaaa/Index.noindex/DataStore/units/a": "",
            "/dd/Runner-bbbbbb/Index.noindex/DataStore/units/a": "",
        ])
        let locator = IndexStoreLocator(fileSystem: fileSystem)
        #expect(throws: CartographError.self) {
            try locator.locate(explicitPath: nil, projectPath: "/p/ios", derivedDataPath: "/dd")
        }
    }

    @Test("소유가 증명된 후보가 있으면 이름만 맞은 것과 다투지 않는다")
    func provenOwnershipSettlesTheAmbiguity() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/ios/Runner.xcodeproj/project.pbxproj": "",
            "/dd/Runner-aaaaaa/info.plist": Self.infoPlist(workspacePath: "/p/ios/Runner.xcodeproj"),
            "/dd/Runner-aaaaaa/Index.noindex/DataStore/units/a": "",
            "/dd/Runner-bbbbbb/Index.noindex/DataStore/units/a": "",
        ])
        let located = try IndexStoreLocator(fileSystem: fileSystem)
            .locate(explicitPath: nil, projectPath: "/p/ios", derivedDataPath: "/dd")
        #expect(located == "/dd/Runner-aaaaaa/Index.noindex/DataStore")
    }

    @Test("평평한 -derivedDataPath 배치도 후보로 본다")
    func flatDerivedDataLayoutIsFound() throws {
        // `xcodebuild -derivedDataPath DerivedData` 는 이름 붙은 디렉터리 없이 루트
        // 바로 아래에 스토어를 둔다. README 가 권하는 CI 배치가 그 모양이다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App/App.xcodeproj/project.pbxproj": "",
            "/dd/Index.noindex/DataStore/units/a": "",
        ])
        let located = try IndexStoreLocator(fileSystem: fileSystem)
            .locate(explicitPath: nil, projectPath: "/p/App", derivedDataPath: "/dd")
        #expect(located == "/dd/Index.noindex/DataStore")
    }

    @Test("DerivedData 를 어디서 어떤 이름으로 찾았는지 오류에 남는다")
    func theErrorSaysWhatItLookedForInDerivedData() {
        // 이름이 하나도 맞지 않으면 후보 경로가 한 줄도 생기지 않아, 목록만으로는
        // 도구가 그곳을 보기라도 했는지 알 수 없었다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/ios/HealthMap.xcodeproj/project.pbxproj": "",
            "/dd/SomethingElse-abcdef/Index.noindex/DataStore/units/a": "",
        ])
        var message = ""
        do {
            _ = try IndexStoreLocator(fileSystem: fileSystem)
                .locate(explicitPath: nil, projectPath: "/p/ios", derivedDataPath: "/dd")
        } catch {
            message = (error as? CartographError)?.errorDescription ?? ""
        }
        #expect(message.contains("/dd"))
        #expect(message.contains("'HealthMap'"))
        #expect(message.contains("'ios'"))
    }

    @Test("이름은 맞았지만 빌드된 적이 없으면 그렇게 말한다")
    func theErrorDistinguishesANeverBuiltProject() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/ios/App.xcodeproj/project.pbxproj": "",
            "/dd/App-abcdef/info.plist": Self.infoPlist(workspacePath: "/p/ios/App.xcodeproj"),
        ])
        var message = ""
        do {
            _ = try IndexStoreLocator(fileSystem: fileSystem)
                .locate(explicitPath: nil, projectPath: "/p/ios", derivedDataPath: "/dd")
        } catch {
            message = (error as? CartographError)?.errorDescription ?? ""
        }
        #expect(message.contains("hold no index store"))
    }

    @Test("후보 목록이 겹치는 프로젝트를 걸러 낸다")
    func candidateListExcludesOtherProjects() {
        let fileSystem = InMemoryFileSystem(files: [
            "/dd/App-aaaaaa/Index.noindex/DataStore/units/a": "",
            "/dd/App-Extension-bbbbbb/Index.noindex/DataStore/units/a": "",
        ])
        let candidates = IndexStoreLocator(fileSystem: fileSystem)
            .derivedDataCandidates(projectNames: ["App"], derivedDataPath: "/dd")
        #expect(candidates.allSatisfy { !$0.contains("App-Extension") })
        #expect(candidates.contains("/dd/App-aaaaaa/Index.noindex/DataStore"))
    }
}
