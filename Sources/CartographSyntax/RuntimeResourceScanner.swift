import CartographCore
import Foundation

/// Interface Builder XML에서 소유 타입이 보존된 런타임 경계를 읽는다.
///
/// 기존 보존 스캐너는 이름 집합만 필요하지만, 자동 발견은 동명 action과 outlet을
/// 서로 다른 컨트롤러에 정확히 결합해야 한다. 이 스캐너는 파일 순회를 하지 않고
/// 호출자가 전달한 한 문서만 파싱한다.
public enum RuntimeResourceScanner {
    /// XIB 또는 storyboard 한 파일에서 런타임 경계와 해석 한계를 만든다.
    public static func scan(source: String, path: String) -> RuntimeFileFacts {
        // Interface Builder 문서는 DTD가 필요 없다. 파서가 외부 선언을 해석할 기회
        // 자체를 주지 않아 로컬 파일과 네트워크 접근을 구조적으로 막는다.
        if containsDocumentTypeDeclaration(source) {
            return RuntimeFileFacts(
                path: path,
                limitations: ["XML DTDs and external entities are disabled: \(path)"]
            )
        }
        let collector = RuntimeResourceCollector(path: path)
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        let parsed = parser.parse()
        if collector.foundExternalEntity {
            return RuntimeFileFacts(
                path: path,
                limitations: ["XML DTDs and external entities are disabled: \(path)"]
            )
        }
        guard parsed, collector.parseError == nil else {
            return RuntimeFileFacts(
                path: path,
                limitations: ["malformed Interface Builder XML: \(path)"]
            )
        }
        return RuntimeFileFacts(path: path, boundaries: collector.boundaries())
    }

    private static func containsDocumentTypeDeclaration(_ source: String) -> Bool {
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard let declaration = source.range(of: "<!DOCTYPE", range: cursor..<source.endIndex),
                  let comment = source.range(of: "<!--", range: cursor..<source.endIndex),
                  comment.lowerBound < declaration.lowerBound else {
                return source.range(of: "<!DOCTYPE", range: cursor..<source.endIndex) != nil
            }
            guard let commentEnd = source.range(of: "-->", range: comment.upperBound..<source.endIndex) else {
                return false
            }
            cursor = commentEnd.upperBound
        }
        return false
    }
}

private final class RuntimeResourceCollector: NSObject, XMLParserDelegate {
    private struct ResourceObject {
        let id: String
        let className: String?
        let qualifiedClassName: String?
        let location: SourceLocation
    }

    private struct Connection {
        enum Kind {
            case action, outlet
        }

        let kind: Kind
        let memberName: String?
        let destinationID: String?
        let ownerID: String?
        let location: SourceLocation
    }

    private struct ElementFrame {
        let objectID: String?
    }

    private let path: String
    private var objects: [ResourceObject] = []
    private var connections: [Connection] = []
    private var frames: [ElementFrame] = []
    private(set) var foundExternalEntity = false
    private(set) var parseError: Error?

    init(path: String) {
        self.path = path
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let location = SourceLocation(
            path: path,
            line: max(parser.lineNumber, 1),
            column: max(parser.columnNumber, 1)
        )
        let objectID = nonempty(attributeDict["id"])
        if let objectID {
            let className = nonempty(attributeDict["customClass"])
            objects.append(ResourceObject(
                id: objectID,
                className: className,
                qualifiedClassName: qualifiedClassName(className, attributes: attributeDict),
                location: location
            ))
        } else if let className = nonempty(attributeDict["customClass"]) {
            // ID가 없는 customClass도 리소스 참조 자체는 남기되 객체 신원은 미확정이다.
            objects.append(ResourceObject(
                id: "",
                className: className,
                qualifiedClassName: qualifiedClassName(className, attributes: attributeDict),
                location: location
            ))
        }

        if elementName == "action" || elementName == "outlet" {
            connections.append(Connection(
                kind: elementName == "action" ? .action : .outlet,
                memberName: nonempty(attributeDict[elementName == "action" ? "selector" : "property"]),
                destinationID: nonempty(attributeDict["destination"]),
                ownerID: frames.reversed().compactMap(\.objectID).first,
                location: location
            ))
        }
        frames.append(ElementFrame(objectID: objectID))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !frames.isEmpty { frames.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        parseError = validationError
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        foundExternalEntity = true
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        foundExternalEntity = true
        return nil
    }

    func boundaries() -> [RuntimeBoundary] {
        let objectsByID = Dictionary(grouping: objects.filter { !$0.id.isEmpty }, by: \.id)
        var result = objects.compactMap { classBoundary(for: $0, objectsByID: objectsByID) }
        result.append(contentsOf: connections.map { connectionBoundary(for: $0, objectsByID: objectsByID) })
        return result.sorted(by: boundaryOrder)
    }

    private func classBoundary(
        for object: ResourceObject,
        objectsByID: [String: [ResourceObject]]
    ) -> RuntimeBoundary? {
        guard let className = object.className, let qualifiedClassName = object.qualifiedClassName else {
            return nil
        }
        let reason: String?
        if object.id.isEmpty {
            reason = "custom class object has no id"
        } else if objectsByID[object.id]?.count != 1 {
            reason = duplicateReason(object.id)
        } else {
            reason = nil
        }
        return RuntimeBoundary(
            kind: .interfaceBuilderClass,
            api: "customClass",
            location: object.location,
            name: className,
            nameOrigin: .resource,
            receiverTypeName: qualifiedClassName,
            receiverOrigin: .annotation,
            receiverTypeLocation: object.location,
            resourceObjectID: object.id.isEmpty ? nil : object.id,
            reason: reason
        )
    }

    private func connectionBoundary(
        for connection: Connection,
        objectsByID: [String: [ResourceObject]]
    ) -> RuntimeBoundary {
        let owner = connection.kind == .action ? connection.destinationID : connection.ownerID
        let resolution = resolveObject(owner, role: connection.kind == .action ? "destination" : "owning",
                                       objectsByID: objectsByID)
        let missingMemberReason: String?
        switch connection.kind {
        case .action:
            missingMemberReason = connection.memberName == nil ? "action has no selector" : nil
        case .outlet:
            missingMemberReason = connection.memberName == nil ? "outlet has no property" : nil
        }
        let reason = missingMemberReason ?? resolution.reason

        return RuntimeBoundary(
            kind: connection.kind == .action ? .interfaceBuilderAction : .interfaceBuilderOutlet,
            api: connection.kind == .action ? "action" : "outlet",
            location: connection.location,
            name: connection.memberName,
            nameOrigin: .resource,
            receiverTypeName: reason == nil ? resolution.object?.qualifiedClassName : nil,
            receiverOrigin: connection.kind == .action ? .explicitTarget : .enclosingType,
            receiverTypeLocation: reason == nil ? resolution.object?.location : nil,
            targetMemberName: connection.memberName,
            resourceObjectID: owner,
            reason: reason
        )
    }

    private func resolveObject(
        _ id: String?,
        role: String,
        objectsByID: [String: [ResourceObject]]
    ) -> (object: ResourceObject?, reason: String?) {
        guard let id else { return (nil, "connection has no \(role) object") }
        guard let candidates = objectsByID[id] else { return (nil, "unknown \(role) object id '\(id)'") }
        guard candidates.count == 1 else { return (nil, duplicateReason(id)) }
        guard candidates[0].qualifiedClassName != nil else {
            return (nil, "\(role) object '\(id)' has no custom class")
        }
        return (candidates[0], nil)
    }

    private func qualifiedClassName(_ className: String?, attributes: [String: String]) -> String? {
        guard let className else { return nil }
        // customModuleProvider는 모듈명이 아니라 모듈을 찾는 정책이다.
        guard let module = nonempty(attributes["customModule"]) else { return className }
        return "\(module).\(className)"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func duplicateReason(_ id: String) -> String {
        "duplicate resource object id '\(id)'"
    }

    private func boundaryOrder(_ lhs: RuntimeBoundary, _ rhs: RuntimeBoundary) -> Bool {
        let left = (lhs.location, lhs.kind.rawValue, lhs.api, lhs.name ?? "")
        let right = (rhs.location, rhs.kind.rawValue, rhs.api, rhs.name ?? "")
        return left < right
    }
}
