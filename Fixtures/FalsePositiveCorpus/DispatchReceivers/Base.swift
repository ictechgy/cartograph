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

// A non-final sibling is retained by the first bounded capability.
class NonfinalSibling: Base { override func send() -> Int { 3 } }

class CallableBase {
    func callAsFunction() -> Int { 0 }
    func callableSelf() -> Int { self.callAsFunction() }
    func callableLocal() -> Int {
        let other: CallableBase = CallableChanged()
        return other()
    }
    var callableOther: CallableBase { CallableChanged() }
    func callableProperty() -> Int { callableOther() }
    func callableNamedValue() -> Int {
        let callAsFunction: CallableBase = CallableChanged()
        return callAsFunction()
    }
}
final class CallableChanged: CallableBase {
    override func callAsFunction() -> Int { 1 }
}
final class CallableSibling: CallableBase {
    override func callAsFunction() -> Int { 2 }
}
class CallableWrapper {
    var callAsFunction: CallableBase { CallableChanged() }
    func callPropertyExplicitly() -> Int { self.callAsFunction() }
}
final class CallableSiblingWrapper: CallableWrapper {}
