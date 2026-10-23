# Extension attribution variants

These synthetic sources extend feedback C-P1-4/C-P1-8 without copying private
application code. The earlier `ExtensionArchitecture` corpus covers an explicit
associatedtype implementation; this corpus adds four other shapes:

- An inferred associatedtype witness on a domain type.
- A conditional generic conformance with a concrete type constraint.
- A nested domain type extended with an app-local nested type and static factory.
- A protocol default implementation and a protocol-alias conformance.

The package executes all five resulting values. Native verification then compares
the public 0.28.0 binary and the candidate against the same unchanged compiler
index. It records the full file/module/type graphs, but validates a bounded set:
the complete module dependency pairs, absence of Domain-to-Presentation/Data file
edges, semantic conformance edges, and genuine Left/Right file/type cycles. The
real Presentation-to-Data rule violation must remain visible with evidence.

A public result with no reverse edge is **not reproduced**, not a demonstrated
fix of the reported application. This fixture does not reproduce the reported
22-project Xcode workspace, its compiler version, or its module SCC count. Missing
or ambiguous source ownership remains a limitation rather than a fabricated
architecture dependency.

Run `Scripts/verify-extension-architecture.py --corpus variants` with the same
candidate/public-binary/output arguments as the original corpus. The script's
default original-corpus run also executes this additional corpus in a separate
subdirectory, retaining independent timings, hashes and reproduction results.
Both corpora run sequentially in one Python interpreter: each native command is
owned directly by the existing process supervisor. The variants retain a
600-second command budget, passed as remaining time to each native call. Cleanup
grace, Python bookkeeping and artifact copying are not a hard total wall bound.
