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
            .derivedDataCandidates(projectName: "MyApp", derivedDataPath: "/dd")
        #expect(candidates.contains("/dd/MyApp-abcdef/Index.noindex/DataStore"))
        #expect(candidates.contains("/dd/MyApp-abcdef/Index/DataStore"))
        #expect(!candidates.contains { $0.contains("Other-123") })
    }

    @Test("DerivedData 디렉터리가 없으면 후보도 없다")
    func missingDerivedDataYieldsNoCandidates() {
        #expect(
            IndexStoreLocator(fileSystem: InMemoryFileSystem())
                .derivedDataCandidates(projectName: "MyApp", derivedDataPath: "/nope")
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
            .derivedDataCandidates(projectName: "App", derivedDataPath: "/dd", projectPath: "/src/main/App")
        #expect(candidates.contains("/dd/App-aaaaaa/Index.noindex/DataStore"))
        #expect(candidates.allSatisfy { !$0.contains("App-bbbbbb") })
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
            .derivedDataCandidates(projectName: "App", derivedDataPath: "/dd", projectPath: "/src/main/App")
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

    @Test("후보 목록이 겹치는 프로젝트를 걸러 낸다")
    func candidateListExcludesOtherProjects() {
        let fileSystem = InMemoryFileSystem(files: [
            "/dd/App-aaaaaa/Index.noindex/DataStore/units/a": "",
            "/dd/App-Extension-bbbbbb/Index.noindex/DataStore/units/a": "",
        ])
        let candidates = IndexStoreLocator(fileSystem: fileSystem)
            .derivedDataCandidates(projectName: "App", derivedDataPath: "/dd")
        #expect(candidates.allSatisfy { !$0.contains("App-Extension") })
        #expect(candidates.contains("/dd/App-aaaaaa/Index.noindex/DataStore"))
    }
}
