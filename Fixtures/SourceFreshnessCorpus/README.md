# Source freshness regression

`Scripts/verify-index-freshness.py --cartograph <exact executable>` compiles this
fixture into a fresh index and tests the normal CLI pipeline. A shared Swift file
is compiled in two module contexts. Rebuilding only one must not conceal the
other context's older coverage. Header edits, renames and deletion must identify
the affected project-relative dependency in the structured `limitations` array.

The harness checks both warning presence and clean rebuilt controls, retains
the command outputs on failure, and checks snapshot dates independently of graph
declarations. It does not score header graph admission or framework execution.
Compiler outputs use stable names when a source is renamed; other build systems
can leave obsolete units, which require a fresh index to remove.
