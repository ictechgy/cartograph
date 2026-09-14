protocol Service: Sendable {}

struct Alpha: Service {}
struct Beta: Service {}

func makeAlpha() -> any Service { Alpha() }
func makeBeta() -> any Service { Beta() }

let factories: Swift.Dictionary<String, () -> any Service> = [
    "alpha": makeAlpha,
    "beta": makeBeta,
]
let factoryAlias = factories

struct Router {
    static let routes: [String: @Sendable () -> any Service] = [
        "alpha": makeAlpha,
    ]

    @MainActor
    static func route() -> (any Service)? {
        routes["alpha"]?()
    }
}

@MainActor
func lookupFactory() -> (any Service)? {
    factories["alpha"]?()
}

@MainActor
func lookupFactoryAlias() -> (any Service)? {
    factoryAlias["beta"]?()
}

@MainActor
func lookupRouter() -> (any Service)? {
    Router.routes["alpha"]?()
}

var mutableFactories = factories

@MainActor
func lookupMutableFactory() -> (any Service)? {
    mutableFactories["alpha"]?()
}

@MainActor
func lookupDynamicFactory(_ key: String) -> (any Service)? {
    factories[key]?()
}

let closureFactories: [String: @Sendable () -> any Service] = [
    "closure": { Alpha() },
]

func lookupClosureFactory() -> (any Service)? {
    closureFactories["closure"]?()
}

struct Builder {
    func build() -> any Service { Alpha() }
}

let receiverFactories: [String: @Sendable () -> any Service] = [
    "receiver": Builder().build,
]

func buildDuplicateFactories() -> [String: @Sendable () -> any Service] {
    let duplicate: [String: @Sendable () -> any Service] = [
        "alpha": makeAlpha,
        "alpha": makeBeta,
    ]
    return duplicate
}

struct CustomRegistry: ExpressibleByDictionaryLiteral {
    typealias Key = String
    typealias Value = @Sendable () -> any Service

    init(dictionaryLiteral elements: (String, @Sendable () -> any Service)...) {}

    subscript(_ key: String) -> (@Sendable () -> any Service)? { nil }
}

let customFactories: CustomRegistry = ["alpha": makeAlpha]

func lookupCustomFactory() -> (any Service)? {
    customFactories["alpha"]?()
}

#if DEBUG
let conditionalFactories: [String: @Sendable () -> any Service] = ["conditional": makeAlpha]
#else
let conditionalFactories: [String: @Sendable () -> any Service] = ["conditional": makeBeta]
#endif

func lookupConditionalFactory() -> (any Service)? {
    conditionalFactories["conditional"]?()
}

func label(_ service: (any Service)?) -> String {
    guard let service else { return "nil" }
    return String(describing: type(of: service))
}

print("registry=\(label(lookupFactory())),\(label(lookupFactoryAlias())),\(label(lookupRouter()))")
let unsupported = [
    label(lookupMutableFactory()),
    label(lookupDynamicFactory("alpha")),
    label(lookupClosureFactory()),
]
print("unsupported=" + unsupported.joined(separator: ","))
print("custom=\(label(lookupCustomFactory())),conditional=\(label(lookupConditionalFactory()))")
