# Swift immutable registry corpus

This dependency free executable is a compiler grounded corpus for static factory and router registries.
The supported shape is an immutable `Swift.Dictionary` literal whose string keys point directly to named
top level functions. An immutable alias may forward to the same declaration when the compiler reference
chain is unique.

The corpus deliberately includes mutable and dynamic maps, duplicate keys, closures, instance method
references, conditional compilation, and a custom `ExpressibleByDictionaryLiteral` type. Those cases must
remain unresolved until the compiler proves both the actual registry declaration and the standard library
`Dictionary` subscript. A lookup finding describes a possible static dependency; it does not claim that the
factory was executed.

The standard library subscript USRs used by the verifier are extracted from this fixture with the installed
Swift toolchain. They are evidence for the resolver contract, not guessed names or framework heuristics.
