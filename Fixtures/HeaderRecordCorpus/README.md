# Project header records

This compiler regression preserves the exact `CGCore.h`, `Core.m` and
`CppBridge.mm` source bytes from the mixed iOS validation fixture. In retained
run [38205053093](https://github.com/ictechgy/cartograph/actions/runs/38205053093),
the compiler/CLI oracle contained both header-inline definitions (lines 15 and
19) and their four incoming/outgoing call edges, while Cartograph omitted them.
The independent benchmark oracle and original failed evidence remain unchanged.

The product harness compiles these files directly with Clang, including the
same header in multiple Objective-C units and a different Objective-C++ context.
It tests exact call sets, caller queries, scoped/excluded/external header
admission, unreadable record failure, deleted-header metadata and snapshot
roundtrip. No Xcode project or new dependency is required. Successfully reading
all observed records does not prove completeness of unbuilt configurations.
