import CartographCore

/// 한 번의 프로젝트 walk에서 파이프라인이 공유하는 파일 목록.
///
/// 인덱스 입력, 구문 보강, 런타임 리소스, 한계 수집이 각각 루트를 걸으면
/// 큰 저장소에서 같은 디렉터리와 빌드 산출물을 반복해서 열게 된다. 이 값은
/// 그 목록을 실행 한 번 동안만 보관하고, 각 소비자에게 필요한 관점만 넘긴다.
struct ProjectFileInventory: Sendable, Equatable {
    let allSourceFiles: [String]
    let sourceFiles: [String]
    let runtimeFiles: [String]
    let interfaceBuilderFiles: [String]
    /// 소스와 Interface Builder 문서가 한계 수집에서 보이는 파일이다.
    let limitationFiles: [String]
    /// 프로젝트 루트 밖을 가리켜 따라가지 않은 디렉터리 링크(정렬). 제외 글롭에 걸린 위치는 뺐다.
    ///
    /// 그 뒤의 소스는 어떤 명령도 읽지 않으므로 거기 사는 호출자도 없다. 한계로 알려야 빈 `usedBy` 를
    /// "못 봤다"로 읽는다. 제외한 위치의 링크까지 세면 범위 밖 파일을 알리는 매번 붙는 경보가 된다.
    let externalDirectoryLinks: [String]
    /// Git 범위나 중첩 저장소 경계로 제외한 실제 파일/디렉터리. 타깃 소속의 증명은 아니다.
    let discoveryExclusions: [String]
    /// Git 이 무시한 소스 확장자 파일(정렬, 분석 filter 적용). 분석 범위에는 넣지 않는다.
    ///
    /// 컴파일러가 이 중 일부를 색인했다면 그 파일이 쓰는 선언을 보존 근거로 삼는다(`IgnoredSourceReferences`).
    /// 생성 파일을 무시 목록에 두는 팀이 흔해, 빼기만 하면 생성 코드만 부르는 앱 코드가 미사용으로 보고됐다.
    let ignoredSourceFiles: [String]
    /// Git 저장소인데 선택을 끝내지 못해 전체 walk 로 폴백한 이유. nil 이면 선택했거나 시도할 필요가 없었다.
    ///
    /// 폴백하면 무시 파일까지 섞여, 같은 커밋에서도 선택이 성공한 실행과 답이 달라진다. 이 값이 그 사실을
    /// 응답의 한계로 옮기는 유일한 통로다.
    let gitSelectionUnavailableReason: String?

    init(fileSystem: any FileSystem, projectPath: String, pathFilter: PathFilter) {
        var externalLinks: [String] = []
        var exclusions: Set<String> = []
        var ignoredSources: Set<String> = []
        let selection = GitSourceSelection.select(fileSystem: fileSystem, projectPath: projectPath)
        let git = selection.inventory
        if case let .unavailable(reason) = selection {
            gitSelectionUnavailableReason = reason
        } else {
            gitSelectionUnavailableReason = nil
        }
        let paths = fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in
                guard Self.isSource(path) || path.hasSuffix(".h") || Self.isRuntimeResource(path) else { return false }
                if let git, !git.paths.contains(path) {
                    exclusions.insert(path)
                    if Self.isSource(path) { ignoredSources.insert(path) }
                    return false
                }
                return true
            },
            shouldDescend: { path in
                guard BuildArtifactDirectories.shouldDescend(into: path) else { return false }
                if fileSystem.fileExists(at: path + "/.git") || fileSystem.directoryExists(at: path + "/.git") {
                    exclusions.insert(path)
                    return false
                }
                return true
            },
            onExternalDirectoryLink: { externalLinks.append($0) }
        )
        allSourceFiles = paths.filter(Self.isSource)
        sourceFiles = allSourceFiles.filter(pathFilter.allows)
        runtimeFiles = paths.filter { Self.isRuntimeResource($0) && pathFilter.allows($0) }
        interfaceBuilderFiles = runtimeFiles.filter(Self.isInterfaceBuilder)
        let headers = paths.filter { $0.hasSuffix(".h") && pathFilter.allows($0) }
        limitationFiles = Set(sourceFiles + headers + interfaceBuilderFiles).sorted()
        externalDirectoryLinks = Self.inScope(externalLinks, pathFilter: pathFilter)
        discoveryExclusions = exclusions.sorted()
        ignoredSourceFiles = ignoredSources.filter(pathFilter.allows).sorted()
    }

    /// 제외 글롭에 걸리지 않는 위치의 링크만 남긴다.
    ///
    /// include 는 보지 않는다. 디렉터리 경로는 `Sources/**/*.swift` 같은 파일 글롭에 맞지 않아, 범위 안의
    /// 링크까지 조용히 빠진다. 알리는 쪽으로 기울이는 것이 이 목록의 안전한 방향이다.
    static func inScope(_ links: [String], pathFilter: PathFilter) -> [String] {
        links.filter { !pathFilter.removes(pathFilter.exclude, $0) }.sorted()
    }

    private static func isSource(_ path: String) -> Bool {
        path.hasSuffix(".swift") || path.hasSuffix(".m") || path.hasSuffix(".mm")
    }

    private static func isRuntimeResource(_ path: String) -> Bool {
        RuntimeResourcePath.isSupported(path)
    }

    private static func isInterfaceBuilder(_ path: String) -> Bool {
        RuntimeResourcePath.kind(of: path) == .interfaceBuilder
    }
}
