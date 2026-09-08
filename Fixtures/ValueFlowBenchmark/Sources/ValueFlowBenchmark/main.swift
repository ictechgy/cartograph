import Foundation

@main
struct BenchmarkMain {
    static func main() async {
        runSameFileScenario()

        let directA = "origin-A"
        probe(label: "direct-A", value: directA)
        let directB = "origin-B"
        probe(label: "direct-B", value: directB)

        let identityA = identity("origin-A")
        probe(label: "identity-A", value: identityA)
        let identityB = identity("origin-B")
        probe(label: "identity-B", value: identityB)

        probe(label: "literal-return-A", value: literalA())
        probe(label: "nested-return-B", value: nestedB())
        probe(label: "discarded-input", value: discard("origin-A"))

        let closureA = invoke { "origin-A" }
        probe(label: "closure-callback-A", value: closureA)
        let namedCallback = invoke(namedCallbackB)
        probe(label: "named-callback-B", value: namedCallback)

        probe(label: "recursive-A", value: recursive(2))
        let asynchronous = await asyncValue()
        probe(label: "async-return-B", value: asynchronous)

        var mutable = "before"
        overwrite(&mutable)
        probe(label: "inout-A", value: mutable)

        let box = Box(field: "origin-A")
        probe(label: "box-read-A", value: box.field)
        box.field = "origin-B"
        probe(label: "box-write-B", value: box.field)

        let outer = "origin-A"
        do {
            let outer = "origin-B"
            probe(label: "shadow-inner-B", value: outer)
        }
        probe(label: "shadow-outer-A", value: outer)

        probe(label: "overload-string-A", value: overloaded("origin-A"))
        probe(label: "overload-int-B", value: overloaded(7))

        let effects = SideEffect()
        probe(label: "side-effect-A", value: effects.returnAfterMutation("origin-A"))

        probe(label: "unknown-external", value: unknownExternalResult(for: "origin-A"))
        probe(label: "external-side-effect", value: externalSideEffectResult(for: "origin-B"))
        probe(label: "literal-inline-A", value: "origin-A")
    }
}
