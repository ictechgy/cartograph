import CartographCore
import Foundation

/// 인덱스 스토어와 libIndexStore 를 찾아 준다.
///
/// 사용자가 가장 자주 막히는 지점이 "인덱스가 어디 있는지 모르겠다"이다.
/// 흔한 위치를 전부 뒤지고, 못 찾으면 만드는 방법을 알려 준다.
/// 경로 규칙만 담고 있어 메모리 파일 시스템으로 전부 테스트된다.
public struct IndexStoreLocator: Sendable {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// 프로젝트 안에서 인덱스 스토어가 있을 만한 자리들.
    ///
    /// SwiftPM 은 툴체인과 빌드 러너에 따라 위치가 달라져 왔다.
    /// 하나만 가정하면 어떤 환경에서는 반드시 실패한다.
    public func projectCandidates(projectPath: String) -> [String] {
        [
            ".build/index/store",
            ".build/debug/index/store",
            ".build/release/index/store",
            ".build/out",
            ".index-store",
            "IndexStore",
        ].map { (projectPath as NSString).appendingPathComponent($0) }
    }

    /// DerivedData 안의 인덱스 스토어 후보.
    ///
    /// Xcode 14 부터 `Index.noindex/DataStore` 이고 그 이전은 `Index/DataStore` 다.
    public func derivedDataCandidates(projectName: String, derivedDataPath: String) -> [String] {
        guard let entries = try? fileSystem.contentsOfDirectory(at: derivedDataPath) else { return [] }
        return entries
            .filter { Self.isDerivedDataDirectory(($0 as NSString).lastPathComponent, forProject: projectName) }
            .flatMap { entry in
                ["Index.noindex/DataStore", "Index/DataStore"]
                    .map { (entry as NSString).appendingPathComponent($0) }
            }
    }

    /// DerivedData 디렉터리 이름이 이 프로젝트의 것인지 판단한다.
    ///
    /// 이름은 `<프로젝트명>-<해시>` 형태다. 접두사만 보면 `App` 이 `App-Extension`
    /// 의 디렉터리까지 집어삼켜, 더 최근에 빌드된 다른 프로젝트를 분석하게 된다.
    /// 해시 부분은 영숫자만 있고 하이픈이 없다는 점으로 구분한다.
    ///
    /// APFS 는 기본이 대소문자 구분 없음이라, 디렉터리 표기가 프로젝트 이름과
    /// 대소문자만 다른 경우가 흔하다. 비교도 대소문자를 구분하지 않는다.
    static func isDerivedDataDirectory(_ name: String, forProject projectName: String) -> Bool {
        let prefix = projectName + "-"
        guard name.count > prefix.count,
              name.prefix(prefix.count).lowercased() == prefix.lowercased()
        else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// 인덱스 스토어 경로를 결정한다.
    ///
    /// 명시 경로가 있으면 그것만 쓴다. 없으면 후보를 훑고, 여러 개가 존재하면
    /// 가장 최근에 갱신된 것을 고른다. 오래된 인덱스로 분석하면 결과가 조용히
    /// 틀리기 때문에, 애매할 때는 최신을 택하는 편이 안전하다.
    public func locate(
        explicitPath: String?,
        projectPath: String,
        derivedDataPath: String? = nil
    ) throws -> String {
        if let explicitPath {
            guard fileSystem.directoryExists(at: explicitPath) else {
                throw CartographError.indexStoreNotFound(searchedPaths: [explicitPath])
            }
            return explicitPath
        }

        var candidates = projectCandidates(projectPath: projectPath)
        if let derivedDataPath {
            // 프로젝트 경로가 심볼릭 링크면 링크 이름이 아니라 실제 디렉터리 이름이
            // DerivedData 이름과 맞는다.
            let canonicalPath = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
            let projectName = (canonicalPath as NSString).lastPathComponent
            candidates += derivedDataCandidates(projectName: projectName, derivedDataPath: derivedDataPath)
        }

        let existing = candidates.filter { fileSystem.directoryExists(at: $0) }
        guard !existing.isEmpty else {
            throw CartographError.indexStoreNotFound(searchedPaths: candidates)
        }
        return existing.max { lhs, rhs in
            let lhsDate = fileSystem.modificationDate(at: lhs) ?? .distantPast
            let rhsDate = fileSystem.modificationDate(at: rhs) ?? .distantPast
            return lhsDate == rhsDate ? lhs > rhs : lhsDate < rhsDate
        } ?? existing[0]
    }

    /// libIndexStore 후보 경로.
    ///
    /// IndexStoreDB 는 이 라이브러리를 실행 시점에 dlopen 한다.
    /// 인덱스 포맷은 하위 호환만 보장하므로, 인덱스를 만든 툴체인과 같거나
    /// 더 새로운 라이브러리를 써야 한다.
    public func libraryCandidates(developerDirectory: String?) -> [String] {
        var candidates: [String] = []
        if let developerDirectory {
            candidates.append(
                developerDirectory + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
            )
        }
        candidates.append("/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib")
        candidates.append(
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
                + "/usr/lib/libIndexStore.dylib"
        )
        return candidates
    }

    public func locateLibrary(explicitPath: String?, developerDirectory: String?) throws -> String {
        if let explicitPath {
            guard fileSystem.fileExists(at: explicitPath) else {
                throw CartographError.indexStoreLibraryNotFound(searchedPaths: [explicitPath])
            }
            return explicitPath
        }
        let candidates = libraryCandidates(developerDirectory: developerDirectory)
        guard let found = candidates.first(where: { fileSystem.fileExists(at: $0) }) else {
            throw CartographError.indexStoreLibraryNotFound(searchedPaths: candidates)
        }
        return found
    }
}
