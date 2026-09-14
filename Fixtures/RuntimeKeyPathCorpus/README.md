# Runtime key-path compiler corpus

This macOS fixture checks a bounded KVC and `NSPredicate(format:)` model against a fresh compiler
index and real Foundation execution. Its twelve positive relationships cover read/write paths,
optional intermediate objects, inline predicates, literal `argumentArray` `%K`, and an immutable
local predicate. Every path contributes all properties it depends on; a write kind on an intermediate
target does not claim that the intermediate property setter ran.

Negative cases keep overrides, non-final roots, `AnyObject`, arrays, inferred intermediate types,
read-only final properties, higher-priority accessors, dynamic or oversized paths, mutable predicates,
and same-named custom APIs unresolved. The grammar accepts at most sixteen simple dotted segments and
must consume the complete format. This fixture does not cover collection operators, `SUBQUERY`,
arbitrary functions, dynamic format strings or general predicate semantics.
