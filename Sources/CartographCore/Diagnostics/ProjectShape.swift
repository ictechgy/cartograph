/// 프로젝트 루트가 제공하는 빌드 진입점.
///
/// "인덱스 스토어가 없다"는 오류의 다음 행동은 루트에 무엇이 있는지에 따라 갈린다.
/// Swift 패키지에 `xcodebuild` 를, Xcode 프로젝트에 `swift build` 를 권하는 안내는
/// 절반이 언제나 틀리다. 값만 담고, 디렉터리를 읽는 일은 `CartographIndexStore` 가
/// 한다 — `CartographCore` 는 파일 접근을 갖지 않는 규칙 때문이다.
public struct ProjectShape: Sendable, Equatable {
    /// 루트에 `Package.swift` 가 있다.
    public let hasPackageManifest: Bool
    /// 루트에 `.build` 디렉터리가 있다.
    ///
    /// 스토어를 못 찾았는데 `.build` 만 있으면 의존성 해석까지만 됐거나 인덱스 없이
    /// 빌드된 것이다. 다음 행동이 같아도 "한 번도 빌드된 적 없다"와는 이유 문장이
    /// 달라야 사용자가 자기 상황을 대조할 수 있다.
    public let hasBuildDirectory: Bool
    /// 루트의 Xcode 문서 파일 이름(확장자 포함). 워크스페이스가 앞에 오고 이름순이다.
    ///
    /// Xcode 는 한 번에 하나의 문서로 빌드하므로, 문서가 여럿이면 명령이
    /// `-workspace`/`-project` 를 실어야 그대로 따라 쳐서 된다.
    public let xcodeDocuments: [String]

    public init(
        hasPackageManifest: Bool,
        hasBuildDirectory: Bool = false,
        xcodeDocuments: [String] = []
    ) {
        self.hasPackageManifest = hasPackageManifest
        self.hasBuildDirectory = hasBuildDirectory
        self.xcodeDocuments = xcodeDocuments
    }

    /// 프로젝트 형태에 맞는 "인덱스를 만드는 법" 문단.
    public var remedy: String {
        if hasPackageManifest, xcodeDocuments.isEmpty { return swiftPackageRemedy }
        if xcodeDocuments.isEmpty { return Self.unidentifiedRemedy }
        return hasPackageManifest ? dualRemedy : xcodeRemedy
    }

    /// 인덱스를 쓰는 빌드 명령들. 다른 안내 문장에 끼울 수 있게 명령만 돌려준다.
    public var buildCommands: [String] {
        var commands: [String] = []
        if hasPackageManifest { commands.append("swift build") }
        if !xcodeDocuments.isEmpty { commands.append(xcodeBuildCommand) }
        if commands.isEmpty {
            commands = [
                "swift build",
                "xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>",
            ]
        }
        return commands
    }

    /// 어느 문서로 빌드할지까지 담은 xcodebuild 명령 한 줄.
    ///
    /// `-scheme` 없는 xcodebuild 는 첫 타깃만 빌드하거나 멈춘다. 안내대로 실행했는데
    /// 실패하는 안내는 없는 안내보다 나쁘다.
    private var xcodeBuildCommand: String {
        "xcodebuild \(xcodeDocumentFlag) -scheme <scheme> build COMPILER_INDEX_STORE_ENABLE=YES"
    }

    /// `-workspace`·`-project` 플래그와 인자. 문서가 하나면 그것을, 여럿이면 자리표시자를 쓴다.
    /// 이름은 셸 작은따옴표로 감싼다 — 큰따옴표는 `$`·역따옴표·`\` 를 여전히 확장하고
    /// 이름에 든 `"` 로 닫혀 명령이 깨진다.
    private var xcodeDocumentFlag: String {
        let workspaces = xcodeDocuments.filter { $0.hasSuffix(".xcworkspace") }
        if workspaces.count == 1 { return "-workspace \(shellQuoted(workspaces[0]))" }
        if workspaces.count > 1 { return "-workspace <workspace>" }
        return xcodeDocuments.count == 1 ? "-project \(shellQuoted(xcodeDocuments[0]))" : "-project <project>"
    }

    /// 셸 인용 — 작은따옴표 안에서는 아무것도 확장되지 않고, 이름 속 `'` 는 `'\''` 로 닫는다.
    /// stdlib `replacing` 을 쓴다 — 이 파일은 Foundation 없이 컴파일되어야 한다.
    private func shellQuoted(_ name: String) -> String {
        "'" + name.replacing("'", with: "'\\''") + "'"
    }

    private var swiftPackageRemedy: String {
        var lines = [
            "This project is a Swift package, so the store is one build away:",
            "  swift build",
        ]
        if hasBuildDirectory {
            lines.append(
                "A .build directory exists but holds no index store — resolving dependencies "
                    + "or an interrupted build writes none; the command above writes it."
            )
        }
        lines.append(
            """
            The store lands under .build and is found automatically — run again, \
            or pass --index-store <path> to point at it directly.
            Note: with SwiftPM's Xcode-based build system, -Xswiftc -index-store-path is
            ignored; the store goes to <scratch path>/out.
            """
        )
        return lines.joined(separator: "\n")
    }

    private var xcodeRemedy: String {
        """
        This project builds with Xcode, and indexing must be turned on for the build:
          \(xcodeBuildCommand)
        `xcodebuild -list` shows the scheme names. The store lands under DerivedData, \
        which Cartograph searches automatically — run again, or pass --index-store <path>.
        """
    }

    private var dualRemedy: String {
        """
        This root offers both a Swift package and an Xcode project — build the one you mean:
          swift build
          \(xcodeBuildCommand)
        Then run again, or pass --index-store <path> to point at the store directly.
        Note: with SwiftPM's Xcode-based build system, -Xswiftc -index-store-path is
        ignored; the store goes to <scratch path>/out.
        """
    }

    /// 루트에 빌드 진입점이 하나도 없다 — 경로가 얕게 잘못 지정됐을 가능성이 가장 크다.
    /// 경로 지적만 하고 명령을 빼면 Tuist·Bazel 처럼 다른 빌드를 아는 사용자가
    /// 어떤 플래그가 중요한지까지 잃는다. 명령은 "빌드할 수 있는 루트를 가리켰을 때"
    /// 의 참고로 남긴다.
    private static let unidentifiedRemedy = """
        No Package.swift or Xcode project lives at the project root — check that \
        --project points at the sources' root. Once pointed at a buildable root:
          swift build
          xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
        Then run again, or pass --index-store <path> to point at it directly.
        Note: with SwiftPM's Xcode-based build system, -Xswiftc -index-store-path is
        ignored; the store goes to <scratch path>/out.
        """
}
