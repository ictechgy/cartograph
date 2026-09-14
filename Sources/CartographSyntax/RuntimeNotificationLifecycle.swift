import CartographCore

enum RuntimeNotificationTokenKind: Equatable {
    case observer(receiverText: String)
    case subscription
}

struct RuntimeNotificationToken: Equatable {
    let registrationLocation: SourceLocation
    let kind: RuntimeNotificationTokenKind
}

final class RuntimeNotificationLifecycleTracker {
    private struct BindingKey: Hashable {
        let scopes: [Int]
        let name: String
    }

    private struct ScopeKey: Hashable {
        let scopes: [Int]
    }

    private enum Binding {
        case token(RuntimeNotificationToken)
        case opaque
    }

    private var bindings: [BindingKey: Binding] = [:]
    private var removals: [ScopeKey: [RuntimeNotificationRemovalReference]] = [:]
    private var cancellations: [ScopeKey: [RuntimeNotificationCancellationReference]] = [:]
    private var deferredRemovals: [ScopeKey: [RuntimeNotificationRemovalReference]] = [:]
    private var deferredCancellations: [ScopeKey: [RuntimeNotificationCancellationReference]] = [:]

    func bindOpaque(name: String, scopes: [Int]) {
        bindings[BindingKey(scopes: scopes, name: name)] = .opaque
    }

    func bindAlias(name: String, source: String, scopes: [Int]) {
        let key = BindingKey(scopes: scopes, name: name)
        guard let token = token(named: source, scopes: scopes) else {
            bindings[key] = .opaque
            return
        }
        bindings[key] = .token(token)
    }

    func bindToken(name: String, token: RuntimeNotificationToken, scopes: [Int]) {
        bindings[BindingKey(scopes: scopes, name: name)] = .token(token)
    }

    func token(named name: String, scopes: [Int]) -> RuntimeNotificationToken? {
        for depth in stride(from: scopes.count, through: 0, by: -1) {
            guard let binding = bindings[BindingKey(scopes: Array(scopes.prefix(depth)), name: name)] else {
                continue
            }
            guard case .token(let token) = binding else { return nil }
            return token
        }
        return nil
    }

    func recordRemoval(
        _ reference: RuntimeNotificationRemovalReference,
        scopes: [Int],
        deferredUntilScopeExit: [Int]? = nil
    ) {
        let key = ScopeKey(scopes: deferredUntilScopeExit ?? scopes)
        if deferredUntilScopeExit != nil { deferredRemovals[key, default: []].append(reference) }
        else { removals[key, default: []].append(reference) }
    }

    func recordCancellation(
        _ reference: RuntimeNotificationCancellationReference,
        scopes: [Int],
        deferredUntilScopeExit: [Int]? = nil
    ) {
        let key = ScopeKey(scopes: deferredUntilScopeExit ?? scopes)
        if deferredUntilScopeExit != nil { deferredCancellations[key, default: []].append(reference) }
        else { cancellations[key, default: []].append(reference) }
    }

    func activateDeferredTerminations(from exitedScope: [Int], in targetScope: [Int]) {
        let exited = ScopeKey(scopes: exitedScope)
        let target = ScopeKey(scopes: targetScope)
        removals[target, default: []] += deferredRemovals.removeValue(forKey: exited) ?? []
        cancellations[target, default: []] += deferredCancellations.removeValue(forKey: exited) ?? []
    }

    func visibleRemovals(scopes: [Int]) -> [RuntimeNotificationRemovalReference]? {
        let values = visibleValues(in: removals, scopes: scopes)
        return values.isEmpty ? nil : values
    }

    func visibleCancellations(scopes: [Int]) -> [RuntimeNotificationCancellationReference]? {
        let values = visibleValues(in: cancellations, scopes: scopes)
        return values.isEmpty ? nil : values
    }

    private func visibleValues<Value>(in storage: [ScopeKey: [Value]], scopes: [Int]) -> [Value] {
        (0...scopes.count).flatMap { depth in
            storage[ScopeKey(scopes: Array(scopes.prefix(depth)))] ?? []
        }
    }
}
