import Foundation

@objc(CartographRuntimeController)
public final class RuntimeController: NSObject {}

public func resolveRuntimeController() -> AnyClass? {
    NSClassFromString("CartographRuntimeController")
}
