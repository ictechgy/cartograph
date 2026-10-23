/// A call occurrence whose receiver was bound to the enclosing instance using
/// fresh source syntax and the compiler's exact caller/callee/UTF-8 location.
/// Receiver aliases, closures and calls on other values are deliberately absent.
public struct SelfReceiverCall: Codable, Hashable, Sendable {
    public let callerUSR: String
    public let calleeUSR: String
    public let location: SourceLocation

    public init(callerUSR: String, calleeUSR: String, location: SourceLocation) {
        self.callerUSR = callerUSR
        self.calleeUSR = calleeUSR
        self.location = location
    }
}

/// Optional precision evidence; absence never means that no receiver is possible.
/// IndexSnapshot never serializes these facts. Query callers revalidate sourceDigest;
/// historical/decoded captures and changed bytes provide no narrowing capability.
public struct DispatchReceiverFileFacts: Codable, Equatable, Sendable {
    public let path: String
    public let sourceDigest: String?
    public let finalClassUSRs: [String]
    public let selfCalls: [SelfReceiverCall]

    public init(path: String, finalClassUSRs: [String], selfCalls: [SelfReceiverCall], sourceDigest: String? = nil) {
        self.path = path
        self.sourceDigest = sourceDigest
        self.finalClassUSRs = Set(finalClassUSRs).sorted()
        self.selfCalls = Set(selfCalls).sorted {
            ($0.location, $0.callerUSR, $0.calleeUSR) < ($1.location, $1.callerUSR, $1.calleeUSR)
        }
    }

}
