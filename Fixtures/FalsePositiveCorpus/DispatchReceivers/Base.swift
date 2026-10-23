// Generalized receiver controls, with no private app source.
class Base {
    func send() -> Int { 0 }
    func sharedSelf() -> Int { send() }
    func sharedExplicitSelf() -> Int { self.send() }
    func sharedAlias() -> Int {
        let receiver = self
        return receiver.send()
    }
    func sharedOther(_ other: Base) -> Int { other.send() }
}
final class Changed: Base {
    override func send() -> Int { 1 }
}
final class Sibling: Base {
    override init() {
        super.init()
        _ = sharedSelf()
    }
    override func send() -> Int { 2 }
}
