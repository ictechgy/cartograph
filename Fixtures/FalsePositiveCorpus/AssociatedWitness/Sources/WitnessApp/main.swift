import Combine

let first = Forwarder(upstream: Just(1)).sink { print($0) }
let second = Namespace.NestedForwarder(upstream: Just(2)).sink { print($0) }
print(LivePlain().value())
withExtendedLifetime((first, second)) {}
