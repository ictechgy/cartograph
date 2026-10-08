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

    init(fileSystem: any FileSystem, projectPath: String, pathFilter: PathFilter) {
        let paths = fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in
                Self.isSource(path) || Self.isRuntimeResource(path)
            },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
        )
        allSourceFiles = paths.filter(Self.isSource)
        sourceFiles = allSourceFiles.filter(pathFilter.allows)
        runtimeFiles = paths.filter { Self.isRuntimeResource($0) && pathFilter.allows($0) }
        interfaceBuilderFiles = runtimeFiles.filter(Self.isInterfaceBuilder)
        limitationFiles = Set(sourceFiles + interfaceBuilderFiles).sorted()
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
