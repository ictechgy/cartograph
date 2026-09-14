import Foundation

final class NonObjectiveCTarget {
    func hiddenAction() {}
}

final class GenericTarget: NSObject {
    func genericAction<T>(_ value: T) {}
}

final class TupleTarget: NSObject {
    func tupleAction(_ value: (Int, Int)) {}
}

@objcMembers
final class ImplicitMembersTarget: NSObject {
    func implicitAction() {}
}

enum FakeLookup {
    static func NSClassFromString(_ name: String) -> AnyClass? { nil }
}

func nestedShadowLookup() {
    func NSClassFromString(_ name: String) -> AnyClass? { nil }
    _ = NSClassFromString("RuntimeAlias")
}

func qualifiedShadowLookup() {
    _ = FakeLookup.NSClassFromString("RuntimeAlias")
}

func runtimeClassWrapper(_ name: String) -> AnyClass? {
    Foundation.NSClassFromString(name)
}

func wrapperOnlyLookup() {
    _ = runtimeClassWrapper("RuntimeAlias")
}

func selectorWrapper(_ name: String) -> Selector {
    NSSelectorFromString(name)
}

func wrapperOnlySelector() {
    _ = selectorWrapper("implicitAction")
}

func nonObjectiveCNegative(_ target: NSObject) {
    _ = target.perform(NSSelectorFromString("hiddenAction"))
}

func genericNegative(_ target: NSObject) {
    _ = target.perform(NSSelectorFromString("genericAction:"))
}

func tupleNegative(_ target: NSObject) {
    _ = target.perform(NSSelectorFromString("tupleAction:"))
}

func implicitObjcMembers(_ target: ImplicitMembersTarget) {
    _ = target.perform(NSSelectorFromString("implicitAction"))
}

private func configure(target: NSObject, action: Selector) {}

func unsupportedSelectorRegistration(_ target: PerformTarget) {
    configure(target: target, action: #selector(PerformTarget.explicitAction))
}

func unsupportedKeyValueReflection(_ target: NSObject) {
    _ = target.value(forKey: "title")
}
