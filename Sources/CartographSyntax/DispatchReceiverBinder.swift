import CartographCore

/// Receiver refinement needs both compiler ownership and source identity. Name
/// matching, stale source, accessors, aliases and legacy facts provide no proof.
enum DispatchReceiverBinder {
    static func bind(snapshot: IndexSnapshot, files: [String: SourceFileFacts],
                     freshPaths: Set<String>) -> [DispatchReceiverFileFacts] {
        let symbols = snapshot.symbolsByUSR()
        let definitionSites = Dictionary(grouping: snapshot.symbols.filter { !$0.isExternal }, by: \.usr)
            .mapValues { Set($0.map(\.location)) }
        let definitions = Dictionary(grouping: snapshot.symbols.filter {
            !$0.isExternal && !$0.attributes.contains(.implicit) && $0.usr.hasPrefix("s:")
        }, by: \.location)
        let calls = Dictionary(grouping: snapshot.references.filter {
            $0.kind == .call && $0.origin == .compiler && $0.location != nil
        }, by: { $0.location! })
        return files.keys.sorted().compactMap { path in
            guard freshPaths.contains(path), let file = files[path],
                  let syntax = file.dispatchReceiverSyntaxFacts else { return nil }
            let declarations = Dictionary(grouping: file.declarations.compactMap { facts in
                facts.nameLocation.map { ($0, facts) }
            }, by: { $0.0 }).mapValues { $0.map(\.1) }
            func exactDeclaration(_ symbol: IndexedSymbol) -> Bool {
                guard let facts = declarations[symbol.location], facts.count == 1,
                      let declaration = facts.first, declaration.hasUnresolvedAttributes == false,
                      declaration.name == GraphNode.baseName(ofIndexName: symbol.name) else { return false }
                return !declaration.attributes.contains(where: {
                    $0.isObjectiveCRelated || [.dynamicDispatch, .dynamicReplacement, .runtimeManaged].contains($0)
                })
            }
            let finalClasses = syntax.finalClassLocations.compactMap { location -> String? in
                let matches = definitions[location, default: []].filter { $0.kind == .classType }
                guard Set(matches.map(\.usr)).count == 1, let symbol = matches.first,
                      exactDeclaration(symbol), definitionSites[symbol.usr]?.count == 1 else { return nil }
                return symbol.usr
            }
            let selfCalls = syntax.selfCalls.compactMap { site -> SelfReceiverCall? in
                let references = Set(calls[site.location] ?? [])
                guard references.count == 1, let reference = references.first,
                      reference.receiverTypeUSR != nil,
                      let target = symbols[reference.targetUSR], target.kind == .method,
                      let memberName = site.memberName,
                      GraphNode.baseName(ofIndexName: target.name) == memberName,
                      // Even self.callAsFunction() can invoke a property value
                      // named callAsFunction. Its runtime receiver is not self.
                      // Keep all callable-value lowering conservative.
                      memberName != "callAsFunction",
                      let caller = symbols[reference.sourceUSR],
                      caller.location == site.callerLocation,
                      [.method, .initializer].contains(caller.kind),
                      exactDeclaration(caller), definitionSites[caller.usr]?.count == 1,
                      Set(definitions[caller.location, default: []].map(\.usr)).count == 1
                else { return nil }
                return SelfReceiverCall(callerUSR: reference.sourceUSR, calleeUSR: reference.targetUSR,
                    location: site.location)
            }
            return DispatchReceiverFileFacts(path: path, finalClassUSRs: finalClasses, selfCalls: selfCalls,
                sourceDigest: file.sourceDigest)
        }
    }
}
