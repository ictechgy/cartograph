import Foundation

@objc(StaleRuntimeTarget)
final class StaleRuntimeTarget: NSObject {}

func staleLookup() {
    _ = NSClassFromString("StaleRuntimeTarget")
}
