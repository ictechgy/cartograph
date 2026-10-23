# Associated type witnesses

This generalized C-P1-2 feedback fixture reproduces a Combine `Publisher` whose
`receive` constraints refer to `Upstream.Output` / `Upstream.Failure` without
spelling the conforming type's own aliases. It contains a used top-level publisher,
a used nested publisher, an unused publisher, and a used nonconforming type with
unrelated aliases named `Output` and `Failure`.

The native verifier retains the entire dead-code report for public 0.28.0 and the
candidate. It separately removes each required alias and rebuilds to test the
compiler's requirement. Removing both unrelated aliases must compile. A compiler
record test records raw occurrence roles/relations before any mapping inference.

This is a synthetic compiler counterexample, not a rerun of the reported company
workspace. The unused owner must stay a candidate; matching an alias's name alone
does not establish a protocol witness. Diagnostic-only mode records the candidate
failure without claiming a completed fix.
