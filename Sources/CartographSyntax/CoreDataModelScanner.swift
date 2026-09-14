import CartographCore
import Foundation

/// Core Data 모델 XML이 명시적으로 지목한 기존 Swift 클래스를 읽는다.
public enum CoreDataModelScanner {
    /// `.xcdatamodel/contents` 한 파일을 파싱한다.
    public static func scan(
        source: String,
        path: String,
        hasMultipleVersions: Bool = false,
        modelSelectionReason: String? = nil
    ) -> RuntimeFileFacts {
        guard RuntimeResourcePath.isCoreDataModelContents(path) else {
            return RuntimeFileFacts(
                path: path,
                limitations: ["not a Core Data model contents path: \(path)"]
            )
        }
        if containsDocumentTypeDeclaration(source) {
            return RuntimeFileFacts(
                path: path,
                limitations: ["XML DTDs and external entities are disabled: \(path)"]
            )
        }
        let collector = CoreDataEntityCollector(path: path, hasMultipleVersions: hasMultipleVersions,
            modelSelectionReason: modelSelectionReason)
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let parsed = parser.parse()
        guard parsed, collector.isModelDocument, collector.parseError == nil, !collector.foundExternalEntity else {
            let limitation = collector.foundExternalEntity
                ? "XML DTDs and external entities are disabled: \(path)"
                : "malformed Core Data model XML: \(path)"
            return RuntimeFileFacts(path: path, limitations: [limitation])
        }
        return RuntimeFileFacts(path: path, boundaries: collector.boundaries)
    }

    private static func containsDocumentTypeDeclaration(_ source: String) -> Bool {
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard let declaration = source.range(
                of: "<!DOCTYPE",
                options: .caseInsensitive,
                range: cursor..<source.endIndex
            ), let comment = source.range(of: "<!--", range: cursor..<source.endIndex),
                  comment.lowerBound < declaration.lowerBound else {
                return source.range(
                    of: "<!DOCTYPE",
                    options: .caseInsensitive,
                    range: cursor..<source.endIndex
                ) != nil
            }
            guard let commentEnd = source.range(of: "-->", range: comment.upperBound..<source.endIndex) else {
                return false
            }
            cursor = commentEnd.upperBound
        }
        return false
    }
}

private final class CoreDataEntityCollector: NSObject, XMLParserDelegate {
    private struct Entity {
        let name: String?
        let representedClassName: String?
        let codeGenerationType: String?
        let location: SourceLocation
    }

    private let path: String
    private let hasMultipleVersions: Bool
    private let modelSelectionReason: String?
    private var entities: [Entity] = []
    private var elementNames: [String] = []
    private(set) var isModelDocument = false
    private(set) var foundExternalEntity = false
    private(set) var parseError: Error?

    init(path: String, hasMultipleVersions: Bool, modelSelectionReason: String?) {
        self.path = path
        self.hasMultipleVersions = hasMultipleVersions
        self.modelSelectionReason = modelSelectionReason
    }

    var boundaries: [RuntimeBoundary] {
        let counts = Dictionary(grouping: entities.compactMap(\.name), by: { $0 }).mapValues(\.count)
        return entities.map { entity in
            let selected = entity.representedClassName
            let reason = unresolvedReason(
                entity: entity.name,
                represented: entity.representedClassName,
                codeGenerationType: entity.codeGenerationType,
                isDuplicate: entity.name.map { (counts[$0] ?? 0) > 1 } ?? false
            )
            return RuntimeBoundary(
                kind: .coreDataEntityClass,
                api: "representedClassName",
                location: entity.location,
                name: selected,
                nameOrigin: .resource,
                receiverTypeName: reason == nil ? selected : nil,
                receiverOrigin: .annotation,
                resourceObjectID: entity.name,
                coreDataCodeGeneration: entity.codeGenerationType,
                reason: reason
            )
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        defer { elementNames.append(elementName) }
        if elementNames.isEmpty { isModelDocument = elementName == "model" }
        guard elementName == "entity", elementNames == ["model"] else { return }
        let entity = nonempty(attributeDict["name"])
        let represented = nonempty(attributeDict["representedClassName"])
        entities.append(Entity(
            name: entity,
            representedClassName: represented,
            codeGenerationType: nonempty(attributeDict["codeGenerationType"]),
            location: SourceLocation(
                path: path,
                line: max(parser.lineNumber, 1),
                column: max(parser.columnNumber, 1)
            )
        ))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !elementNames.isEmpty { elementNames.removeLast() }
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

    private func unresolvedReason(
        entity: String?,
        represented: String?,
        codeGenerationType: String?,
        isDuplicate: Bool
    ) -> String? {
        let label = entity ?? "<unnamed>"
        if let modelSelectionReason { return modelSelectionReason }
        if hasMultipleVersions { return "Core Data model has multiple versions; select one model version explicitly" }
        if entity == nil { return "Core Data entity has no name" }
        if isDuplicate { return "Core Data model contains duplicate entity name '\(label)'" }
        if let codeGenerationType, !["none", "category"].contains(codeGenerationType) {
            if codeGenerationType == "class" {
                return "entity '\(label)' uses automatic code generation without generated-source provenance"
            }
            return "entity '\(label)' uses unsupported code generation '\(codeGenerationType)'"
        }
        guard let selected = represented else {
            return "entity '\(label)' has no represented class"
        }
        if selected.hasPrefix(".") || selected.contains("$(") {
            return "entity '\(label)' uses an unresolved module placeholder"
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
