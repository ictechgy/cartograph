import Foundation

final class KeyPathLeaf: NSObject {
    @objc var text = "before"
}

final class KeyPathRoot: NSObject {
    @objc let leaf: KeyPathLeaf
    @objc let optionalLeaf: KeyPathLeaf?

    init(leaf: KeyPathLeaf = KeyPathLeaf(), optionalLeaf: KeyPathLeaf? = nil) {
        self.leaf = leaf
        self.optionalLeaf = optionalLeaf
    }
}

func readKeyPath(_ root: KeyPathRoot) -> String? {
    root.value(forKeyPath: "leaf.text") as? String
}

func writeKeyPath(_ root: KeyPathRoot) {
    root.setValue("after", forKeyPath: "leaf.text")
}

func readNilOptionalKeyPath(_ root: KeyPathRoot) -> Any? {
    root.value(forKeyPath: "optionalLeaf.text")
}

func evaluateInlinePredicate(_ root: KeyPathRoot) -> Bool {
    NSPredicate(format: "leaf.text == %@", "after").evaluate(with: root)
}

func evaluateArgumentArrayPredicate(_ root: KeyPathRoot) -> Bool {
    NSPredicate(
        format: "%K == %@",
        argumentArray: ["leaf.text", "after"]
    ).evaluate(with: root)
}

func evaluateLocalPredicate(_ root: KeyPathRoot) -> Bool {
    let predicate = NSPredicate(format: "leaf.text == %@", "after")
    return predicate.evaluate(with: root)
}

final class KeyPathOverrideRoot: NSObject {
    @objc let leaf: KeyPathLeaf = KeyPathLeaf()

    override func value(forKeyPath keyPath: String) -> Any? {
        "override"
    }
}

func overriddenKeyPath(_ root: KeyPathOverrideRoot) -> Any? {
    root.value(forKeyPath: "leaf.text")
}

class NonfinalKeyPathRoot: NSObject {
    @objc let leaf: KeyPathLeaf = KeyPathLeaf()
}

func nonfinalKeyPath(_ root: NonfinalKeyPathRoot) {
    _ = root.value(forKeyPath: "leaf.text")
}

final class AnyKeyPathRoot: NSObject {
    @objc let leaf: AnyObject = KeyPathLeaf()
}

func anyIntermediateKeyPath(_ root: AnyKeyPathRoot) {
    _ = root.value(forKeyPath: "leaf.text")
}

final class ArrayKeyPathRoot: NSObject {
    @objc let leaves: [KeyPathLeaf] = [KeyPathLeaf()]
}

func arrayIntermediateKeyPath(_ root: ArrayKeyPathRoot) {
    _ = root.value(forKeyPath: "leaves.text")
}

final class InferredKeyPathRoot: NSObject {
    @objc let leaf = KeyPathLeaf()
}

func inferredIntermediateKeyPath(_ root: InferredKeyPathRoot) {
    _ = root.value(forKeyPath: "leaf.text")
}

final class ReadOnlyKeyPathLeaf: NSObject {
    @objc let text = "fixed"
}

final class ReadOnlyKeyPathRoot: NSObject {
    @objc let leaf: ReadOnlyKeyPathLeaf = ReadOnlyKeyPathLeaf()
}

func readOnlyKeyPathWrite(_ root: ReadOnlyKeyPathRoot) {
    root.setValue("changed", forKeyPath: "leaf.text")
}

final class AccessorKeyPathLeaf: NSObject {
    @objc var text = "property"
    @objc func getText() -> String { "accessor" }
}

final class AccessorKeyPathRoot: NSObject {
    @objc let leaf: AccessorKeyPathLeaf = AccessorKeyPathLeaf()
}

func alternateAccessorKeyPath(_ root: AccessorKeyPathRoot) {
    _ = root.value(forKeyPath: "leaf.text")
}

func dynamicKeyPath(_ root: KeyPathRoot, path: String) {
    _ = root.value(forKeyPath: path)
}

func oversizedKeyPath(_ root: KeyPathRoot) {
    _ = root.value(forKeyPath: "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q")
}

private struct CustomKeyPathRoot {
    func value(forKeyPath path: String) -> String { path }
}

func customKeyPathAPI() {
    _ = CustomKeyPathRoot().value(forKeyPath: "leaf.text")
}

func unsupportedPredicateKeyArgument(_ root: KeyPathRoot, key: String) {
    _ = NSPredicate(format: "%K == %@", key, "after").evaluate(with: root)
}

func mutablePredicate(_ root: KeyPathRoot) {
    var predicate = NSPredicate(format: "leaf.text == %@", "after")
    predicate = NSPredicate(format: "leaf.text != %@", "never")
    _ = predicate.evaluate(with: root)
}

let leaf = KeyPathLeaf()
let root = KeyPathRoot(leaf: leaf)
let before = readKeyPath(root) ?? "nil"
writeKeyPath(root)
let after = readKeyPath(root) ?? "nil"
let nilValue = readNilOptionalKeyPath(root) == nil ? "nil" : "value"
let predicates = [
    evaluateInlinePredicate(root),
    evaluateArgumentArrayPredicate(root),
    evaluateLocalPredicate(root),
]
let overridden = overriddenKeyPath(KeyPathOverrideRoot()) as? String ?? "nil"
print("keypath=\(before)->\(after),optional=\(nilValue),override=\(overridden)")
print("predicate=\(predicates.map(String.init).joined(separator: ","))")
