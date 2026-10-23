func makeSibling() -> Sibling { Sibling() }
func siblingConstructor() -> Sibling { Sibling() }
func siblingShared() -> Int { Sibling().sharedSelf() }
func changedShared() -> Int { Changed().sharedSelf() }
func factorySiblingShared() -> Int { makeSibling().sharedSelf() }
func explicitSiblingShared() -> Int { Sibling().sharedExplicitSelf() }
func aliasSiblingShared() -> Int { Sibling().sharedAlias() }
func directSibling() -> Int { Sibling().send() }
func directChanged() -> Int { Changed().send() }
func polymorphic(_ receiver: Base) -> Int { receiver.sharedSelf() }
// This sibling owner can still call Changed.send through a different receiver.
func siblingOtherChanged() -> Int { Sibling().sharedOther(Changed()) }

protocol Sender { func send() -> Int }
extension Changed: Sender {}
extension Sibling: Sender {}
func existential(_ receiver: any Sender) -> Int { receiver.send() }
func siblingExistential() -> Int { existential(Sibling()) }
func changedExistential() -> Int { existential(Changed()) }
