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

The follow-on product check compares the legacy traversal and bounded receiver
refinement on the **same freshly compiled index**. The comparison JSON records
both candidate sets and the actual exclusion count. `NonfinalSibling`, aliases,
other-object arguments and base/protocol receivers remain conservative. This is
not a reproduction or accuracy measurement of the user's private application.
The executable is compiled; its runtime preconditions are not executed by this gate.

The bounded capability joins exact compiler caller/callee/UTF-8 call locations to
fresh implicit or explicit `self` syntax. It carries the required final receiver
through those calls and excludes only observed distinct final Swift receivers.
`receivedBy Base` alone is insufficient: compiler evidence gives the same static
type for `self.send()`, a self alias and `other.send()`.
Callable local/property values (`other()`) can also resolve to `callAsFunction`;
the syntax spelling must match the compiler method. All `callAsFunction` paths
remain conservative: even `self.callAsFunction()` may invoke a property value
named `callAsFunction`. The fixture includes local, property and explicit-self
callable values alongside actual self method calls. Ordinary `self.send()` is the
positive refinement control; callable lowering is not refined.

`impact` and `affected` expose optional `receiverPrecision`, including excluded
caller/callee, receiver types and call locations. Output follows the requested
limit (maximum 128 exclusion witnesses), with omitted counts. Unproved paths
remain candidates. A state budget of 50,000, a transition budget of four times
that (200,000 by default), or conflicting receiver/unknown states
at one declaration reruns the **entire** legacy traversal and reports the fallback;
it never reports those paths as excluded. The existing node-only `via` witnesses
therefore do not splice paths from different receiver states.
Every examined transition is charged, including revisits from multiple witnesses
to one shared contract and unknown receivers. Counts and both budgets are output.
The transition budget bounds repeated refinement work; it is not a hard wall-clock
or allocation bound, and fallback still runs the existing conservative traversal.

Source joins are ephemeral and are not serialized in snapshots. Historical
before/after traversal remains conservative. Current queries recheck source SHA-256
against the parsed bytes, with 8 MiB per-file and 64 MiB per-pass read budgets; stale,
unreadable and over-budget files cannot support refinement. The source
files admitted on the first pass are rechecked after traversal and output
preparation whenever an exclusion was made. A change, failed read or final budget
failure restores the entire legacy result. These two observations do not lock the
filesystem or provide an atomic snapshot against all concurrent writers. The compiler/source
join still relies on the existing oldest-unit timestamp checks and exact locations;
a digest of current source is not proof of the bytes consumed by an earlier build.
No change to dead-code retention or permission to skip tests is implied.
