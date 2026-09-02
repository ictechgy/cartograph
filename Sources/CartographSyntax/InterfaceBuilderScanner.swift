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
        let body = removingComments(contents)
        return InterfaceBuilderReferences(
            customClassNames: attributeValues(named: "customClass", in: body),
            outletNames: attributeValues(named: "property", in: body),
            actionSelectors: attributeValues(named: "selector", in: body)
        )
    }

    /// `name="value"` 형태의 속성 값을 모두 모은다.
    ///
    /// Xcode 는 항상 `customClass="Foo"` 로 쓰지만 XML 은 등호 주변의 공백과
    /// 작은따옴표를 모두 허용한다. 손으로 고쳤거나 정렬 도구를 거친 문서에서
    /// 이름을 놓치면 스토리보드에서만 쓰이는 화면이 미사용으로 보고된다.
    ///
    /// 속성 이름 앞이 공백인지도 확인한다. 그러지 않으면 `myproperty="x"` 가
    /// `property` 로 잡혀 없는 이름이 생긴다.
    static func attributeValues(named name: String, in contents: String) -> Set<String> {
        var result: Set<String> = []
        var searchStart = contents.startIndex

        while let nameRange = contents.range(of: name, range: searchStart..<contents.endIndex) {
            // 어떤 경로로 빠져나가든 이름 길이만큼은 전진하므로 멈추지 않는다.
            searchStart = nameRange.upperBound
            guard isAttributeStart(nameRange.lowerBound, in: contents) else { continue }

            var cursor = nameRange.upperBound
            skipWhitespace(&cursor, in: contents)
            guard cursor < contents.endIndex, contents[cursor] == "=" else { continue }
            cursor = contents.index(after: cursor)
            skipWhitespace(&cursor, in: contents)
            guard cursor < contents.endIndex, quoteCharacters.contains(contents[cursor]) else { continue }

            let quote = contents[cursor]
            let valueStart = contents.index(after: cursor)
            guard let valueEnd = contents[valueStart...].firstIndex(of: quote) else { break }
            let value = String(contents[valueStart..<valueEnd])
            if !value.isEmpty { result.insert(value) }
            searchStart = contents.index(after: valueEnd)
        }
        return result
    }

    /// XML 주석 영역을 걷어 낸다.
    ///
    /// 주석 안의 `customClass="LegacyView"` 까지 읽으면 이미 지운 타입이
    /// 영원히 보존된다. 보고서에 남는 잡음이라 굳이 감수할 이유가 없다.
    static func removingComments(_ contents: String) -> String {
        guard contents.contains("<!--") else { return contents }
        var result = ""
        var cursor = contents.startIndex

        while let start = contents.range(of: "<!--", range: cursor..<contents.endIndex) {
            result += contents[cursor..<start.lowerBound]
            guard let end = contents.range(of: "-->", range: start.upperBound..<contents.endIndex) else {
                return result
            }
            cursor = end.upperBound
        }
        result += contents[cursor...]
        return result
    }

    /// 속성 이름이 시작하는 자리인지 확인한다. XML 에서 속성 앞은 항상 공백이다.
    private static func isAttributeStart(_ index: String.Index, in contents: String) -> Bool {
        guard index > contents.startIndex else { return false }
        return contents[contents.index(before: index)].isWhitespace
    }

    private static func skipWhitespace(_ cursor: inout String.Index, in contents: String) {
        while cursor < contents.endIndex, contents[cursor].isWhitespace {
            cursor = contents.index(after: cursor)
        }
    }

    /// XML 이 속성 값 구분자로 허용하는 따옴표.
    static let quoteCharacters: Set<Character> = ["\"", "'"]

    /// 확장자는 대소문자를 가리지 않는다. APFS 는 기본이 대소문자 구분 없음이라
    /// `Main.XIB` 같은 파일이 실제로 존재할 수 있다.
    static func isDocument(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return documentExtensions.contains { lowercased.hasSuffix(".\($0)") }
    }

    static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// 들어가 봐야 소용없는 디렉터리 이름.
    static let prunedDirectoryNames: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "Carthage", "checkouts", ".swiftpm",
    ]
}
