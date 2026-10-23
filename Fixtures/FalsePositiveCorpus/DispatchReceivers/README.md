# Dispatch receiver compiler evidence

This synthetic program separates direct concrete receivers, inherited `self` calls,
receiver aliases, a sibling constructor calling the inherited method, factories,
a different receiver passed to a sibling instance,
and genuine base/protocol polymorphism. No private application sources are used.

`DispatchReceiverCompilerTests` compiles it with the selected Xcode compiler and
saves the raw `receivedBy`, `calledBy`, `containedBy`, inheritance, and override
relations before mapping. The initial diagnostic establishes what the compiler
actually records; it does **not** assert that static receiver type establishes
runtime receiver identity, or that sibling callers may safely be removed.

The `siblingOtherChanged` and `polymorphic` cases are positive controls: narrowing
all calls made through a `Sibling` instance would incorrectly drop a real route
to `Changed.send`. The existing architecture corpus remains separate and retains
true cycles and the Presentation → Data rule violation.
