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
        let fixed = [
            ".build/index/store",
            ".build/debug/index/store",
            ".build/release/index/store",
            ".build/out",
            ".index-store",
            "IndexStore",
        ].map { (projectPath as NSString).appendingPathComponent($0) }
        return fixed + perTripleCandidates(projectPath: projectPath)
    }

    /// 트리플별 디렉터리 아래의 인덱스 스토어 후보.
    ///
    /// SwiftPM 은 한동안 `.build/arm64-apple-macosx/debug/index/store` 처럼
    /// 트리플 디렉터리 밑에 인덱스를 뒀다. 고정 목록만 보면 멀쩡한 스토어를
    /// 놓친다. 애플 플랫폼 트리플에는 항상 `-apple-` 이 들어가므로, 그 이름만
    /// 훑어 못 찾았을 때의 오류 메시지가 길어지지 않게 한다.
    func perTripleCandidates(projectPath: String) -> [String] {
        let buildRoot = (projectPath as NSString).appendingPathComponent(".build")
        let entries = (try? fileSystem.contentsOfDirectory(at: buildRoot)) ?? []
        return entries
            .filter { ($0 as NSString).lastPathComponent.contains("-apple-") }
            .flatMap { entry in
                ["index/store", "debug/index/store", "release/index/store"]
                    .map { (entry as NSString).appendingPathComponent($0) }
            }
    }

    /// DerivedData 안의 인덱스 스토어 후보.
    ///
    /// Xcode 14 부터 `Index.noindex/DataStore` 이고 그 이전은 `Index/DataStore` 다.
    public func derivedDataCandidates(
        projectName: String,
        derivedDataPath: String,
        projectPath: String? = nil
    ) -> [String] {
        guard let entries = try? fileSystem.contentsOfDirectory(at: derivedDataPath) else { return [] }
        let matching = entries
            .filter { Self.isDerivedDataDirectory(($0 as NSString).lastPathComponent, forProject: projectName) }
        return owned(matching, byProjectAt: projectPath)
            .flatMap { entry in
                ["Index.noindex/DataStore", "Index/DataStore"]
                    .map { (entry as NSString).appendingPathComponent($0) }
            }
    }

    /// 같은 이름의 프로젝트가 여럿일 때 이 체크아웃의 것만 남긴다.
    ///
    /// 한 프로젝트를 두 곳에 체크아웃하면 `App-<해시A>` 와 `App-<해시B>` 가
    /// 함께 생기고, 이름만으로는 구분되지 않는다. 최근 빌드된 쪽을 고르는 규칙
    /// 때문에 다른 브랜치의 인덱스로 분석하고도 아무 표시가 나지 않는다.
    ///
    /// Xcode 가 각 디렉터리에 남기는 `info.plist` 의 `WorkspacePath` 가 유일한
    /// 단서다. 읽을 수 없는 경우(예전 Xcode)에는 예전처럼 전부 후보로 둔다.
    private func owned(_ entries: [String], byProjectAt projectPath: String?) -> [String] {
        guard let projectPath else { return entries }
        let matched = entries.filter { entry in
            guard let workspacePath = workspacePath(inDerivedDataDirectory: entry) else { return false }
            return Self.workspacePath(workspacePath, belongsTo: projectPath)
        }
        return matched.isEmpty ? entries : matched
    }

    /// DerivedData 디렉터리가 가리키는 워크스페이스 경로.
    func workspacePath(inDerivedDataDirectory entry: String) -> String? {
        let plistPath = (entry as NSString).appendingPathComponent("info.plist")
        guard let contents = try? fileSystem.readText(at: plistPath) else { return nil }
        return Self.stringValue(forKey: "WorkspacePath", inPropertyList: contents)
    }

    /// 속성 목록에서 키 하나에 대응하는 문자열 값을 읽는다.
    ///
    /// 값 하나만 필요해 XML 파서를 들이지 않는다.
    static func stringValue(forKey key: String, inPropertyList contents: String) -> String? {
        guard let keyRange = contents.range(of: "<key>\(key)</key>"),
              let openRange = contents.range(of: "<string>", range: keyRange.upperBound..<contents.endIndex),
              let closeRange = contents.range(of: "</string>", range: openRange.upperBound..<contents.endIndex)
        else { return nil }
        return decodingEntities(String(contents[openRange.upperBound..<closeRange.lowerBound]))
    }

    /// XML 기본 엔티티를 되돌린다.
    ///
    /// `/work/R&D` 는 속성 목록에 `/work/R&amp;D` 로 저장된다. 그대로 비교하면 절대
    /// 같아지지 않아, 소유권 판정이 실패하고 이름이 같은 다른 체크아웃까지 후보로
    /// 되돌아간다.
    static func decodingEntities(_ value: String) -> String {
        var result = value
        for (entity, character) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// 워크스페이스 경로가 이 프로젝트 안에 있는지 확인한다.
    static func workspacePath(_ workspacePath: String, belongsTo projectPath: String) -> Bool {
        // Xcode 가 심볼릭 링크로 열었으면 링크 경로가 기록되고, 우리는 실제 경로와
        // 비교한다. APFS 는 기본이 대소문자 구분 없음이라 표기만 다른 경우도 흔하다.
        // 어느 쪽이든 어긋나면 소유권 판정이 통째로 무효가 되어, 이 코드가 막으려던
        // "이름이 같은 다른 체크아웃" 상황으로 되돌아간다.
        let candidates = Set([workspacePath, canonical(workspacePath)])
        let bases = Set([projectPath, canonical(projectPath)]).map {
            $0.hasSuffix("/") ? String($0.dropLast()) : $0
        }
        for candidate in candidates {
            for base in bases where candidate.compare(base, options: .caseInsensitive) == .orderedSame
                || candidate.lowercased().hasPrefix(base.lowercased() + "/") {
                return true
            }
        }
        return false
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
            candidates += derivedDataCandidates(
                projectName: projectName,
                derivedDataPath: derivedDataPath,
                projectPath: canonicalPath
            )
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
