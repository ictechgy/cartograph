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

    /// DerivedData 디렉터리 이름에 쓰일 수 있는 프로젝트 이름들.
    ///
    /// Xcode 는 그 디렉터리를 **연 문서의 이름**으로 짓는다. 담고 있는 폴더의 이름이
    /// 아니다. Flutter 와 React Native 앱은 전부 `ios/Runner.xcodeproj` 모양이라
    /// 폴더 이름은 `ios` 이고, 그것만 보면 스토어를 영원히 못 찾는다. 이 머신의 실제
    /// 앱 프로젝트 셋이 전부 그 모양이었다.
    ///
    /// 폴더 이름도 남긴다. Xcode 로 직접 연 Swift 패키지는 `WorkspacePath` 가 확장자
    /// 없는 디렉터리 자체이고, 디렉터리 이름이 곧 DerivedData 이름이다.
    ///
    /// 한 단계만 훑는다. 재귀하면 `Pods/Pods.xcodeproj` 나 `node_modules` 안의
    /// `.xcodeproj` 가 이름 후보가 되어 남의 DerivedData 를 자기 것이라고 연다.
    func projectNames(inProjectRoot projectPath: String) -> [String] {
        let entries = ((try? fileSystem.contentsOfDirectory(at: projectPath)) ?? [])
            .map { ($0 as NSString).lastPathComponent }
        // 워크스페이스를 먼저 본다. 워크스페이스로 연 프로젝트는 그쪽 이름이 쓰인다.
        var names = Self.stems(in: entries, withExtension: "xcworkspace")
        names += Self.stems(in: entries, withExtension: "xcodeproj")
        names.append((projectPath as NSString).lastPathComponent)
        return Self.deduplicatedIgnoringCase(names)
    }

    /// 확장자가 맞는 항목의 확장자를 뗀 이름들. 정렬해 실행마다 같은 순서를 낸다.
    private static func stems(in entries: [String], withExtension pathExtension: String) -> [String] {
        entries
            .filter { ($0 as NSString).pathExtension.lowercased() == pathExtension }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    /// 대소문자를 무시하고 첫 등장만 남긴다.
    ///
    /// `isDerivedDataDirectory` 가 대소문자를 구분하지 않으므로 `App` 과 `app` 은
    /// 같은 디렉터리를 두 번 후보로 만든다.
    private static func deduplicatedIgnoringCase(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// DerivedData 를 훑어본 결과 전체.
    struct DerivedDataScan {
        let candidates: [String]
        let search: DerivedDataSearch
        /// 이름은 맞고 스토어도 있으나 소유가 증명되지 않은 디렉터리들.
        let unprovenStoreDirectories: [String]
    }

    /// DerivedData 안의 인덱스 스토어 후보.
    ///
    /// Xcode 14 부터 `Index.noindex/DataStore` 이고 그 이전은 `Index/DataStore` 다.
    public func derivedDataCandidates(
        projectNames: [String],
        derivedDataPath: String,
        projectPath: String? = nil
    ) -> [String] {
        scanDerivedData(
            projectNames: projectNames,
            derivedDataPath: derivedDataPath,
            projectPath: projectPath
        ).candidates
    }

    /// 후보와 함께 "무엇을 어떤 이름으로 훑었는지" 를 돌려준다.
    func scanDerivedData(
        projectNames: [String],
        derivedDataPath: String,
        projectPath: String? = nil
    ) -> DerivedDataScan {
        guard fileSystem.directoryExists(at: derivedDataPath) else {
            // 루트가 없으면 그 아래 경로를 후보로 늘어놓아 봐야 검색 목록만 길어진다.
            return DerivedDataScan(
                candidates: [],
                search: DerivedDataSearch(
                    root: derivedDataPath,
                    rootExists: false,
                    names: projectNames,
                    matchedDirectoryCount: 0,
                    storeDirectoryCount: 0
                ),
                unprovenStoreDirectories: []
            )
        }

        // `-derivedDataPath` 로 옮긴 빌드는 이름 붙은 디렉터리 없이 루트 바로 아래에
        // 스토어를 둔다. README 가 권하는 CI 배치가 그 모양이라 함께 본다.
        // 있을 때만 후보로 넣는다. 기본 DerivedData 루트에는 이 배치가 있을 수 없어,
        // 늘 넣으면 실패 메시지의 검색 목록에 뜻 없는 두 줄이 매번 붙는다.
        let flat = Self.storePaths(in: derivedDataPath).filter { fileSystem.directoryExists(at: $0) }
        let entries = (try? fileSystem.contentsOfDirectory(at: derivedDataPath)) ?? []
        let matching = entries.filter { entry in
            let name = (entry as NSString).lastPathComponent
            return projectNames.contains { Self.isDerivedDataDirectory(name, forProject: $0) }
        }
        let withStore = matching.filter { entry in
            Self.storePaths(in: entry).contains { fileSystem.directoryExists(at: $0) }
        }
        let kept = owned(matching, byProjectAt: projectPath)
        return DerivedDataScan(
            candidates: flat + kept.flatMap { Self.storePaths(in: $0) },
            search: DerivedDataSearch(
                root: derivedDataPath,
                rootExists: true,
                names: projectNames,
                matchedDirectoryCount: matching.count,
                storeDirectoryCount: withStore.count
            ),
            unprovenStoreDirectories: projectPath.map { path in
                withStore.filter { ownership(of: $0, byProjectAt: path) != .proven }
            } ?? []
        )
    }

    /// 한 디렉터리 아래에서 인덱스 스토어가 있을 두 자리.
    private static func storePaths(in directory: String) -> [String] {
        ["Index.noindex/DataStore", "Index/DataStore"]
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// DerivedData 디렉터리가 이 프로젝트의 것이라고 말하는지.
    enum Ownership {
        /// `info.plist` 가 이 프로젝트를 가리킨다.
        case proven
        /// `info.plist` 가 다른 곳을 가리킨다.
        case foreign
        /// `info.plist` 를 읽을 수 없다. 예전 Xcode 는 남기지 않는다.
        case unknown
    }

    func ownership(of entry: String, byProjectAt projectPath: String) -> Ownership {
        guard let workspacePath = workspacePath(inDerivedDataDirectory: entry) else { return .unknown }
        return Self.workspacePath(workspacePath, belongsTo: projectPath) ? .proven : .foreign
    }

    /// 같은 이름의 프로젝트가 여럿일 때 이 체크아웃의 것만 남긴다.
    ///
    /// 한 프로젝트를 두 곳에 체크아웃하면 `App-<해시A>` 와 `App-<해시B>` 가
    /// 함께 생기고, 이름만으로는 구분되지 않는다. 최근 빌드된 쪽을 고르는 규칙
    /// 때문에 다른 브랜치의 인덱스로 분석하고도 아무 표시가 나지 않는다.
    ///
    /// 소유가 증명된 것이 하나라도 있으면 그것들만 쓴다. 하나도 없으면 읽을 수 없는
    /// 것들만 남긴다 — 예전 Xcode 는 `info.plist` 를 남기지 않아 그 경우까지 버리면
    /// 멀쩡한 스토어를 잃는다. 남의 것이라고 **스스로 밝힌** 디렉터리는 어느 경우에도
    /// 쓰지 않는다. 이름 후보가 넓어질수록 그 구분이 중요해진다.
    private func owned(_ entries: [String], byProjectAt projectPath: String?) -> [String] {
        guard let projectPath else { return entries }
        var proven: [String] = []
        var unknown: [String] = []
        for entry in entries {
            switch ownership(of: entry, byProjectAt: projectPath) {
            case .proven: proven.append(entry)
            case .unknown: unknown.append(entry)
            case .foreign: continue
            }
        }
        return proven.isEmpty ? unknown : proven
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

    /// 워크스페이스가 이 프로젝트와 같은 나무에 있는지 확인한다.
    ///
    /// 한쪽이 다른 쪽을 담고 있기만 하면 같은 것으로 본다. 방향이 둘 다 실재한다.
    /// `--project` 를 워크스페이스보다 넓게 잡으면 워크스페이스가 그 안에 있고,
    /// 소스 디렉터리로 좁히면(`ios/App.xcodeproj` 에 `--project ios/App`) 프로젝트가
    /// 워크스페이스 디렉터리 안에 있다. 뒤쪽은 흔한 사용법이라, 한 방향만 보면
    /// 오늘 잘 돌던 분석이 통째로 실패한다.
    ///
    /// Xcode 가 심볼릭 링크로 열었으면 링크 경로가 기록되고, 우리는 실제 경로와
    /// 비교한다. APFS 는 기본이 대소문자 구분 없음이라 표기만 다른 경우도 흔하다.
    /// 어느 쪽이든 어긋나면 소유권 판정이 통째로 무효가 되어, 이 코드가 막으려던
    /// "이름이 같은 다른 체크아웃" 상황으로 되돌아간다.
    static func workspacePath(_ workspacePath: String, belongsTo projectPath: String) -> Bool {
        let document = documentDirectory(workspacePath)
        let candidates = Set([document, canonical(document)]).map(trimmingTrailingSlash)
        let bases = Set([projectPath, canonical(projectPath)]).map(trimmingTrailingSlash)
        for candidate in candidates {
            for base in bases where contains(candidate, base) || contains(base, candidate) {
                return true
            }
        }
        return false
    }

    /// `.xcodeproj`·`.xcworkspace` 를 담고 있는 디렉터리.
    ///
    /// 확장자가 없는 `WorkspacePath` 는 그대로 둔다. Xcode 로 직접 연 Swift 패키지가
    /// 그 모양이라, 무조건 마지막 성분을 떼면 패키지 자신이 아니라 그 부모를 가리킨다.
    static func documentDirectory(_ workspacePath: String) -> String {
        let pathExtension = (workspacePath as NSString).pathExtension.lowercased()
        guard pathExtension == "xcodeproj" || pathExtension == "xcworkspace" else { return workspacePath }
        return (workspacePath as NSString).deletingLastPathComponent
    }

    /// `lhs` 가 `rhs` 와 같거나 `rhs` 를 담고 있는지.
    private static func contains(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
            || rhs.lowercased().hasPrefix(lhs.lowercased() + "/")
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func canonical(_ path: String) -> String {
        LocalFileSystem.canonicalPath(path)
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
        var scan: DerivedDataScan?
        if let derivedDataPath {
            // 프로젝트 경로가 심볼릭 링크면 링크 이름이 아니라 실제 디렉터리 이름이
            // DerivedData 이름과 맞는다.
            let canonicalPath = LocalFileSystem.canonicalPath(projectPath)
            let found = scanDerivedData(
                projectNames: projectNames(inProjectRoot: canonicalPath),
                derivedDataPath: derivedDataPath,
                projectPath: canonicalPath
            )
            candidates += found.candidates
            scan = found
        }

        let existing = candidates.filter { fileSystem.directoryExists(at: $0) }
        guard !existing.isEmpty else {
            throw CartographError.indexStoreNotFound(searchedPaths: candidates, derivedData: scan?.search)
        }
        let selected = existing.max { lhs, rhs in
            let lhsDate = fileSystem.modificationDate(at: lhs) ?? .distantPast
            let rhsDate = fileSystem.modificationDate(at: rhs) ?? .distantPast
            return lhsDate == rhsDate ? lhs > rhs : lhsDate < rhsDate
        } ?? existing[0]

        // 이름만으로 맞은 디렉터리가 둘 이상이면 최근성으로 고르지 않는다. 그중 어느
        // 것도 이 프로젝트의 것이라고 밝히지 않았으므로, 고르는 순간 남의 인덱스로
        // 분석하고도 아무 표시가 나지 않는다. 같은 이름의 심볼이 여럿일 때 `query` 가
        // 후보를 돌려주는 것과 같은 규칙이다.
        if let scan, scan.unprovenStoreDirectories.count > 1,
           scan.unprovenStoreDirectories.contains(where: { selected.hasPrefix($0 + "/") }) {
            throw CartographError.indexStoreAmbiguous(
                directories: scan.unprovenStoreDirectories.sorted(),
                names: scan.search.names
            )
        }
        return selected
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
