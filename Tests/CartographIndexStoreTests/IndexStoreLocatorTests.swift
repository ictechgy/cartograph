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
            #expect(description.contains("swift build -Xswiftc -index-store-path"))
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
