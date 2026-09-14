import Foundation

@objc(RuntimeAlias)
final class AliasedController: NSObject {}

final class PlainController: NSObject {}

@objc(AliasTarget)
final class ImmutableAliasTarget: NSObject {}

final class ConcatTarget: NSObject {}

@objc(RuntimeProtocol)
protocol RuntimeProtocol: AnyObject {}

private let immutableLookupName = "AliasTarget"
private let modulePiece = "RuntimeDiscoveryApp"
private let concatPiece = "ConcatTarget"

func classAliasLookup() {
    _ = NSClassFromString("RuntimeAlias")
}

func modulePlainLookup() {
    _ = NSClassFromString("RuntimeDiscoveryApp.PlainController")
}

func immutableAliasLookup() {
    let localName = immutableLookupName
    _ = NSClassFromString(localName)
}

func concatenatedLookup() {
    let name = modulePiece + "." + concatPiece
    _ = NSClassFromString(name)
}

func dynamicClassLookup(_ name: String) {
    _ = NSClassFromString(name)
}

func runtimeProtocolLookup() {
    _ = NSProtocolFromString("RuntimeProtocol")
}

func conditionalCompilationLookup() {
    #if DEBUG
    let name = "RuntimeAlias"
    #else
    let name = "RuntimeDiscoveryApp.PlainController"
    #endif
    _ = NSClassFromString(name)
}
