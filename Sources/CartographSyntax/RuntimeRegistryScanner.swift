import CartographCore
import SwiftParser
import SwiftSyntax

private typealias SourceLocation = CartographCore.SourceLocation

/// Swift Dictionary literal과 그 literal-key subscript를 별도 구문 경계로 수집한다.
///
/// 구문만으로 표준 라이브러리 Dictionary나 함수 호출을 확정하지 않는다. 반환한 위치를
/// 상위 resolver가 인덱스의 Dictionary subscript와 실제 함수 reference에 대조한다.
public struct RuntimeRegistryFacts: Sendable, Equatable {
    /// 구문에서 얻은 registry 경계 후보.
    public let boundaries: [RuntimeBoundary]
    /// 이 파일에서 확정할 수 없어 상위 분석에 알린 제한.
    public let limitations: [String]

    /// registry 후보와 제한을 만든다.
    public init(boundaries: [RuntimeBoundary] = [], limitations: [String] = []) {
        self.boundaries = boundaries
        self.limitations = limitations
    }
}

/// immutable factory/router registry의 구문 후보를 모은다.
public struct RuntimeRegistryScanner: Sendable {
    /// 빈 상태의 scanner를 만든다.
    public init() {}

    /// 한 파일에서 registry 선언, alias, literal-key lookup 후보를 수집한다.
    public func scan(source: String, path: String) -> RuntimeRegistryFacts {
        scan(tree: Parser.parse(source: source), path: path)
    }

    /// 공통 런타임 스캐너가 파싱한 트리를 재사용한다.
    func scan(tree: SourceFileSyntax, path: String) -> RuntimeRegistryFacts {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = RuntimeRegistryCollector(path: path, converter: converter)
        collector.walk(tree)
        return collector.facts()
    }
}

private enum RegistrySyntaxIdentifiers {
    static func unescaped(_ raw: String) -> String {
        guard raw.count >= 2, raw.first == "`", raw.last == "`" else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}

private final class RuntimeRegistryCollector: SyntaxVisitor {
    private struct Entry {
        let key: String
        let keyLocation: SourceLocation
        let valueLocation: SourceLocation?
        let valueIsNamedReference: Bool
    }

    private struct Registry {
        let name: String
        let qualifiedName: String
        let location: SourceLocation
        let enclosingLocation: SourceLocation?
        let scope: [Int]
        let declarationOffset: Int
        let isImmutable: Bool
        let isStatic: Bool
        let conditional: Bool
        let entries: [Entry]
        let hasDuplicateKeys: Bool
        let isFunctionTyped: Bool

        var names: Set<String> {
            [name, qualifiedName].filter { !$0.isEmpty }.reduce(into: Set()) { $0.insert($1) }
        }
        var isLocal: Bool { !isStatic && enclosingLocation != nil }
    }

    private struct Alias {
        let name: String
        let source: String
        let location: SourceLocation
        let sourceLocation: SourceLocation
        let enclosingLocation: SourceLocation?
        let scope: [Int]
        let declarationOffset: Int
        let isImmutable: Bool
        let conditional: Bool
        let isLocal: Bool
    }

    private struct Lookup {
        let location: SourceLocation
        let enclosingLocation: SourceLocation?
        let scope: [Int]
        let offset: Int
        let base: String
        let baseLocation: SourceLocation
        let subscriptLocation: SourceLocation
        let key: String?
        let isInvoked: Bool
        let keyIsLiteral: Bool
    }

    private enum Resolution {
        case registry(Registry)
        case invalid(Registry?, String)
        case outOfScope(String)
        case ambiguous(String)
        case missing

        var registryLocation: SourceLocation? {
            switch self {
            case let .registry(registry): return registry.location
            case let .invalid(registry, _): return registry?.location
            case .outOfScope, .ambiguous, .missing: return nil
            }
        }

        var reason: String? {
            switch self {
            case .registry: return nil
            case let .invalid(_, reason), let .outOfScope(reason), let .ambiguous(reason): return reason
            case .missing: return "The registry declaration was not found in the indexed source scope."
            }
        }
    }

    private static let maxAliasDepth = 64

    private let path: String
    private let converter: SourceLocationConverter
    private var scopes: [Int] = []
    private var typeNames: [String] = []
    private var enclosingLocations: [SourceLocation] = []
    private var conditionalDepth = 0
    private var registries: [Registry] = []
    private var aliases: [Alias] = []
    private var lookups: [Lookup] = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name, at: node)
    }

    override func visitPost(_: ClassDeclSyntax) { popType() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name, at: node)
    }

    override func visitPost(_: StructDeclSyntax) { popType() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name, at: node)
    }

    override func visitPost(_: EnumDeclSyntax) { popType() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name, at: node)
    }

    override func visitPost(_: ActorDeclSyntax) { popType() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.trimmedDescription
        typeNames.append(name)
        scopes.append(node.position.utf8Offset)
        enclosingLocations.append(location(node.extendedType))
        return .visitChildren
    }

    override func visitPost(_: ExtensionDeclSyntax) {
        if !typeNames.isEmpty { typeNames.removeLast() }
        if !scopes.isEmpty { scopes.removeLast() }
        if !enclosingLocations.isEmpty { enclosingLocations.removeLast() }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        enclosingLocations.append(location(node.name))
        return .visitChildren
    }

    override func visitPost(_: FunctionDeclSyntax) {
        scopes.removeLast()
        enclosingLocations.removeLast()
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        enclosingLocations.append(location(node.initKeyword))
        return .visitChildren
    }

    override func visitPost(_: InitializerDeclSyntax) {
        scopes.removeLast()
        enclosingLocations.removeLast()
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }

    override func visitPost(_: CodeBlockSyntax) { scopes.removeLast() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(node.position.utf8Offset)
        return .visitChildren
    }

    override func visitPost(_: ClosureExprSyntax) { scopes.removeLast() }

    override func visit(_: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        conditionalDepth += 1
        return .visitChildren
    }

    override func visitPost(_: IfConfigDeclSyntax) { conditionalDepth -= 1 }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
                  let initializer = binding.initializer?.value else { continue }
            let name = RegistrySyntaxIdentifiers.unescaped(identifier.text)
            let immutable = node.bindingSpecifier.tokenKind == .keyword(.let) && binding.accessorBlock == nil
            let isStatic = node.modifiers.contains { ["static", "class"].contains($0.name.text) }
            let declarationLocation = location(identifier)
            let declarationOffset = binding.positionAfterSkippingLeadingTrivia.utf8Offset
            let enclosingLocation = enclosingLocations.last
            let qualifiedName = (typeNames + [name]).joined(separator: ".")
            if let entries = dictionaryEntries(initializer) {
                let keys = entries.compactMap { literalString($0.key) }
                let duplicate = keys.count != Set(keys).count || keys.count != entries.count
                let functionTyped = binding.typeAnnotation.map { isFunctionDictionaryType($0.type) } ?? false
                let namedValues = entries.allSatisfy {
                    unparenthesized($0.value).is(DeclReferenceExprSyntax.self)
                }
                guard functionTyped || namedValues else { continue }
                registries.append(Registry(
                    name: name,
                    qualifiedName: qualifiedName,
                    location: declarationLocation,
                    enclosingLocation: enclosingLocation,
                    scope: scopes,
                    declarationOffset: declarationOffset,
                    isImmutable: immutable,
                    isStatic: isStatic,
                    conditional: conditionalDepth > 0,
                    entries: entries.map { element in
                        let key = literalString(element.key)
                        let value = unparenthesized(element.value)
                        return Entry(
                            key: key ?? "",
                            keyLocation: location(element.key),
                            valueLocation: value.as(DeclReferenceExprSyntax.self).map { location($0.baseName) },
                            valueIsNamedReference: value.is(DeclReferenceExprSyntax.self) && key != nil
                        )
                    },
                    hasDuplicateKeys: duplicate,
                    isFunctionTyped: functionTyped
                ))
            } else if let source = dottedName(unparenthesized(initializer)),
                      let sourceLocation = referenceLocation(initializer) {
                aliases.append(Alias(
                    name: name,
                    source: source,
                    location: declarationLocation,
                    sourceLocation: sourceLocation,
                    enclosingLocation: enclosingLocation,
                    scope: scopes,
                    declarationOffset: declarationOffset,
                    isImmutable: immutable,
                    conditional: conditionalDepth > 0,
                    isLocal: !isStatic && enclosingLocation != nil
                ))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        let baseExpression = unparenthesized(node.calledExpression)
        guard let base = dottedName(baseExpression),
              let baseLocation = referenceLocation(baseExpression),
              isRegistryReference(base, scope: scopes, offset: node.position.utf8Offset)
        else { return .visitChildren }
        let argument = node.arguments.count == 1 ? node.arguments.first : nil
        let key = argument.flatMap { literalString($0.expression) }
        lookups.append(Lookup(
            location: location(node),
            enclosingLocation: enclosingLocations.last,
            scope: scopes,
            offset: node.position.utf8Offset,
            base: base,
            baseLocation: baseLocation,
            subscriptLocation: location(node.leftSquare),
            key: key,
            isInvoked: isInvoked(node),
            keyIsLiteral: argument?.label == nil && key != nil
        ))
        return .visitChildren
    }

    func facts() -> RuntimeRegistryFacts {
        let emittedRegistries = registries.filter { registry in
            registry.isFunctionTyped || lookups.contains { lookup in
                lookup.isInvoked
                    && resolve(lookup.base, scope: lookup.scope, offset: lookup.offset,
                        visited: [], depth: 0).registryLocation == registry.location
            }
        }
        let registryLocations = Set(emittedRegistries.map(\.location))
        let registryBoundaries = emittedRegistries.flatMap(boundaries(for:))
        let aliasBoundaries = aliases.filter { alias in
            guard alias.isImmutable else { return false }
            return resolve(alias.source, scope: alias.scope, offset: alias.declarationOffset,
                visited: [], depth: 0).registryLocation.map(registryLocations.contains) == true
        }.map(boundary(for:))
        let lookupBoundaries = lookups.filter(\.isInvoked).filter { lookup in
            let resolution = resolve(lookup.base, scope: lookup.scope, offset: lookup.offset,
                visited: [], depth: 0)
            switch resolution {
            case let .registry(registry): return registryLocations.contains(registry.location)
            case .invalid, .outOfScope, .ambiguous: return true
            case .missing: return false
            }
        }.map(boundary(for:))
        return RuntimeRegistryFacts(
            boundaries: (registryBoundaries + aliasBoundaries + lookupBoundaries).sorted {
                ($0.location, $0.kind.rawValue, $0.api, $0.name ?? "")
                    < ($1.location, $1.kind.rawValue, $1.api, $1.name ?? "")
            },
            limitations: limitations()
        )
    }

    private func pushType(_ token: TokenSyntax, at node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        typeNames.append(RegistrySyntaxIdentifiers.unescaped(token.text))
        scopes.append(node.position.utf8Offset)
        enclosingLocations.append(location(token))
        return .visitChildren
    }

    private func popType() {
        typeNames.removeLast()
        scopes.removeLast()
        enclosingLocations.removeLast()
    }

    private func dictionaryEntries(_ expression: ExprSyntax) -> [DictionaryElementSyntax]? {
        guard let dictionary = unparenthesized(expression).as(DictionaryExprSyntax.self) else { return nil }
        guard case let .elements(elements) = dictionary.content else { return [] }
        return Array(elements)
    }

    private func isFunctionDictionaryType(_ type: TypeSyntax) -> Bool {
        type.trimmedDescription.contains("->")
    }

    private func boundaries(for registry: Registry) -> [RuntimeBoundary] {
        registry.entries.map { entry in
            RuntimeBoundary(
                kind: .registryEntry,
                api: "Dictionary.literal",
                location: entry.keyLocation,
                enclosingDeclarationLocation: registry.enclosingLocation,
                name: entry.key.isEmpty ? nil : entry.key,
                nameOrigin: .literal,
                referencedTargetLocation: entry.valueLocation,
                registryDeclarationLocation: registry.location,
                reason: entryReason(entry, registry: registry)
            )
        }
    }

    private func boundary(for alias: Alias) -> RuntimeBoundary {
        let resolution = resolve(
            alias.source, scope: alias.scope, offset: alias.declarationOffset, visited: [], depth: 0
        )
        return RuntimeBoundary(
            kind: .registryAlias,
            api: "registry-alias",
            location: alias.location,
            enclosingDeclarationLocation: alias.enclosingLocation,
            registryDeclarationLocation: resolution.registryLocation,
            registryReferenceLocation: alias.sourceLocation,
            reason: aliasReason(alias, resolution: resolution)
        )
    }

    private func boundary(for lookup: Lookup) -> RuntimeBoundary {
        let resolution = resolve(lookup.base, scope: lookup.scope, offset: lookup.offset, visited: [], depth: 0)
        let reason: String?
        if !lookup.keyIsLiteral {
            reason = "The registry key is not one literal string in the supported lookup shape."
        } else {
            reason = resolution.reason
        }
        return RuntimeBoundary(
            kind: .registryLookup,
            api: "Dictionary.subscript",
            location: lookup.location,
            calleeLocation: lookup.subscriptLocation,
            enclosingDeclarationLocation: lookup.enclosingLocation,
            name: lookup.key,
            nameOrigin: lookup.keyIsLiteral ? .literal : .dynamic,
            registryDeclarationLocation: resolution.registryLocation,
            registryReferenceLocation: lookup.baseLocation,
            reason: reason
        )
    }

    private func entryReason(_ entry: Entry, registry: Registry) -> String? {
        if !registry.isImmutable { return "The registry declaration is mutable." }
        if registry.conditional { return "The registry declaration is inside conditional compilation." }
        if registry.hasDuplicateKeys { return "The registry literal contains duplicate keys." }
        guard !entry.key.isEmpty else { return "The registry key is not one literal string." }
        guard entry.valueIsNamedReference else {
            return "The registry value is not a direct named function reference."
        }
        return nil
    }

    private func aliasReason(_ alias: Alias, resolution: Resolution) -> String? {
        if !alias.isImmutable { return "The registry alias is mutable." }
        if alias.conditional { return "The registry alias is inside conditional compilation." }
        return resolution.reason
    }

    private func isRegistryReference(_ base: String, scope: [Int], offset: Int) -> Bool {
        switch resolve(base, scope: scope, offset: offset, visited: [], depth: 0) {
        case .missing: return registries.contains { $0.names.contains(base) } || aliases.contains { $0.name == base }
        default: return true
        }
    }

    private func isInvoked(_ node: SubscriptCallExprSyntax) -> Bool {
        var parent = node.parent
        for _ in 0..<3 {
            guard let current = parent else { return false }
            if current.is(FunctionCallExprSyntax.self) { return true }
            if current.is(OptionalChainingExprSyntax.self) || current.is(ForceUnwrapExprSyntax.self) {
                parent = current.parent
            } else {
                return false
            }
        }
        return false
    }

    private func resolve(
        _ base: String,
        scope: [Int],
        offset: Int,
        visited: Set<SourceLocation>,
        depth: Int
    ) -> Resolution {
        guard depth < Self.maxAliasDepth else {
            return .invalid(nil, "The immutable registry alias chain exceeded 64 steps.")
        }
        let registryCandidates = registries.filter {
            $0.names.contains(base)
                && (visible($0.scope, from: scope) || ($0.isStatic && $0.qualifiedName == base))
                && (!$0.isLocal || $0.declarationOffset < offset)
        }
        let aliasCandidates = aliases.filter {
            $0.name == base && visible($0.scope, from: scope)
                && (!$0.isLocal || $0.declarationOffset < offset)
        }
        let candidates = registryCandidates.map { Candidate.scope($0.scope.count, .registry($0)) }
            + aliasCandidates.map { Candidate.scope($0.scope.count, .alias($0)) }
        guard let bestScope = candidates.map(\.scope).max() else {
            let known = registries.contains { $0.names.contains(base) } || aliases.contains { $0.name == base }
            return known ? .outOfScope("The registry reference is outside the declaration scope.") : .missing
        }
        let best = candidates.filter { $0.scope == bestScope }
        guard best.count == 1, let candidate = best.first else {
            return .ambiguous("The registry name has multiple compiler-visible declarations in this scope.")
        }
        switch candidate.value {
        case let .registry(registry):
            guard registry.isImmutable else { return .invalid(registry, "The registry declaration is mutable.") }
            guard !registry.conditional else {
                return .invalid(registry, "The registry declaration is inside conditional compilation.")
            }
            return .registry(registry)
        case let .alias(alias):
            guard alias.isImmutable else { return .invalid(nil, "The registry alias is mutable.") }
            guard !alias.conditional else {
                return .invalid(nil, "The registry alias is inside conditional compilation.")
            }
            var visited = visited
            guard visited.insert(alias.location).inserted else {
                return .invalid(nil, "The immutable registry alias chain contains a cycle.")
            }
            return resolve(alias.source, scope: alias.scope, offset: alias.declarationOffset,
                visited: visited, depth: depth + 1)
        }
    }

    private func visible(_ declarationScope: [Int], from useScope: [Int]) -> Bool {
        guard declarationScope.count <= useScope.count else { return false }
        return Array(useScope.prefix(declarationScope.count)) == declarationScope
    }

    private func limitations() -> [String] {
        let unsupportedEntries = registries.reduce(into: 0) { count, registry in
            count += registry.entries.filter { entryReason($0, registry: registry) != nil }.count
        }
        let dynamicLookups = lookups.filter { !$0.keyIsLiteral }.count
        var values: [String] = []
        if unsupportedEntries > 0 {
            values.append(
                "Immutable registry candidates with mutable, duplicate, conditional or unsupported values: "
                    + "\(unsupportedEntries)."
            )
        }
        if dynamicLookups > 0 {
            values.append("Registry lookups with dynamic or non-string keys: \(dynamicLookups).")
        }
        return values
    }

    private func literalString(_ expression: ExprSyntax) -> String? {
        unparenthesized(expression).as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    private func unparenthesized(_ expression: ExprSyntax) -> ExprSyntax {
        guard let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
              let element = tuple.elements.first, element.label == nil
        else { return expression }
        return unparenthesized(element.expression)
    }

    private func dottedName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return RegistrySyntaxIdentifiers.unescaped(reference.baseName.text)
        }
        guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
              let prefix = dottedName(unparenthesized(base))
        else { return nil }
        return prefix + "." + RegistrySyntaxIdentifiers.unescaped(member.declName.baseName.text)
    }

    private func referenceLocation(_ expression: ExprSyntax) -> SourceLocation? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return location(reference.baseName) }
        if let member = expression.as(MemberAccessExprSyntax.self) { return location(member.declName.baseName) }
        return nil
    }

    private func location(_ node: some SyntaxProtocol) -> SourceLocation {
        let value = node.startLocation(converter: converter)
        return SourceLocation(path: path, line: value.line, column: value.column)
    }

    private enum CandidateValue {
        case registry(Registry)
        case alias(Alias)
    }

    private struct Candidate {
        let scope: Int
        let value: CandidateValue

        static func scope(_ scope: Int, _ value: CandidateValue) -> Candidate {
            Candidate(scope: scope, value: value)
        }
    }
}
