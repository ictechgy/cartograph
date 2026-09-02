import CartographCore

/// Interface Builder 문서에서 읽어 낸 참조.
public struct InterfaceBuilderReferences: Sendable, Equatable {
    /// `customClass` 로 지정된 타입 이름들.
    public let customClassNames: Set<String>
    /// `<outlet property="…">` 로 연결된 프로퍼티 이름들.
    public let outletNames: Set<String>
    /// `<action selector="…">` 로 연결된 셀렉터들.
    public let actionSelectors: Set<String>

    public init(
        customClassNames: Set<String> = [],
        outletNames: Set<String> = [],
        actionSelectors: Set<String> = []
    ) {
        self.customClassNames = customClassNames
        self.outletNames = outletNames
        self.actionSelectors = actionSelectors
    }

    public var isEmpty: Bool {
        customClassNames.isEmpty && outletNames.isEmpty && actionSelectors.isEmpty
    }

    public func merging(_ other: InterfaceBuilderReferences) -> InterfaceBuilderReferences {
        InterfaceBuilderReferences(
            customClassNames: customClassNames.union(other.customClassNames),
            outletNames: outletNames.union(other.outletNames),
            actionSelectors: actionSelectors.union(other.actionSelectors)
        )
    }
}

/// xib 와 storyboard 에서 코드로 향하는 참조를 찾는다.
///
/// 스토리보드에서만 쓰이는 뷰 컨트롤러와 커스텀 뷰는 Swift 코드 어디에도 참조가
/// 없다. Identity Inspector 의 클래스 지정이 유일한 연결이기 때문이다.
/// 이것을 읽지 않으면 앱의 화면 절반이 미사용으로 보고된다.
///
/// XML 파서 대신 속성 값을 직접 훑는다. 필요한 것은 몇 개의 속성뿐이고,
/// 손상되거나 형식이 조금 다른 문서에서도 멈추지 않아야 하기 때문이다.
public struct InterfaceBuilderScanner: Sendable {
    /// 분석할 문서 확장자.
    public static let documentExtensions = ["xib", "storyboard"]

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// 주어진 경로들 아래의 모든 Interface Builder 문서를 훑는다.
    public func scan(roots: [String], pathFilter: PathFilter = .passthrough) -> InterfaceBuilderReferences {
        var result = InterfaceBuilderReferences()
        var seen: Set<String> = []

        for root in roots {
            let documents = fileSystem.recursiveFiles(
                under: root,
                isIncluded: { Self.isDocument($0) && pathFilter.allows($0) },
                shouldDescend: { !Self.prunedDirectoryNames.contains(Self.lastComponent(of: $0)) }
            )
            for document in documents where seen.insert(document).inserted {
                guard let contents = try? fileSystem.readText(at: document) else { continue }
                result = result.merging(Self.references(in: contents))
            }
        }
        return result
    }

    /// 문서 내용에서 참조를 뽑아낸다.
    public static func references(in contents: String) -> InterfaceBuilderReferences {
        InterfaceBuilderReferences(
            customClassNames: attributeValues(named: "customClass", in: contents),
            outletNames: attributeValues(named: "property", in: contents),
            actionSelectors: attributeValues(named: "selector", in: contents)
        )
    }

    /// `name="value"` 형태의 속성 값을 모두 모은다.
    static func attributeValues(named name: String, in contents: String) -> Set<String> {
        let marker = "\(name)=\""
        var result: Set<String> = []
        var searchStart = contents.startIndex

        while let markerRange = contents.range(of: marker, range: searchStart..<contents.endIndex) {
            guard let closingQuote = contents[markerRange.upperBound...].firstIndex(of: "\"") else { break }
            let value = String(contents[markerRange.upperBound..<closingQuote])
            if !value.isEmpty { result.insert(value) }
            searchStart = contents.index(after: closingQuote)
        }
        return result
    }

    static func isDocument(_ path: String) -> Bool {
        documentExtensions.contains { path.hasSuffix(".\($0)") }
    }

    static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// 들어가 봐야 소용없는 디렉터리 이름.
    static let prunedDirectoryNames: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "Carthage", "checkouts", ".swiftpm",
    ]
}
