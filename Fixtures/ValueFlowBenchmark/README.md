# Swift value-flow benchmark

This deterministic SwiftPM executable compares Cartograph, Semgrep Community Edition, and
CodeQL's public Swift queries on the same source. The CodeQL binary CLI has separate distribution
and licensing terms. Infer is a design reference, with no direct Swift score here.

`probe(label:value:)` prints exactly `label=value`. Definitions and calls are split between
`Support.swift`, `LocalScenarios.swift`, and `main.swift`. No network service receives the source.

## Oracle

[`expected.json`](expected.json) separates two questions:

- `runtime` contains the 23 exact strings printed by the executable.
- `flow_oracle` contains 20 positive origin-to-probe pairs and three negative cases. An empty
  `expected_origins` is a scored negative, not an unsupported test.

The cases cover local values, identity A/B, literal and nested returns, discarded inputs, inline and
named callbacks, recursion, async returns, inout writes, object field reads/writes, local shadowing,
overloads, and side effects. `unknown-external` uses a Foundation Base64 result only as a condition
before returning fixed strings. `external-side-effect` sends an origin to NotificationCenter and
then returns a fixed string. Together with `discarded-input`, these prevent generic unknown-call
propagation from being mistaken for value preservation.

Future cases may explicitly use `evaluation: unsupported`; they are reported separately and excluded
from scores. Extraction failure, malformed output, missing labels, unstable repeats, or truncated
analysis are unscored, rather than counted as successful absence or as zero precision.

## Queries and scoring

[`rules/origin-to-probe.yml`](rules/origin-to-probe.yml) has two Semgrep taint rules, one for each
origin, and two direct-literal sink rules. The taint sink focuses on the `value` argument, not the
whole `probe` call. Taint-only, literal-only, and their union are reported separately, deduplicated
by `(label, origin)`.

The [`codeql`](codeql) pack separately queries global value flow, taint flow, and literals directly
at the sink. Constant observations are not added to the interprocedural score. Query compilation,
database extraction, query execution, and BQRS decoding have separate timing records.

Cartograph reads only `selectedContexts` for `probe`, retaining non-origin strings, possible value
sets, and unknown reasons separately. A value with an unknown reason is not an exact runtime string.
The measured flow result is 20 TP, 0 FP, 0 FN across all 23 labels. The
[comparison report](../../docs/scans/2026-09-value-flow-comparison.md) records versions, source hashes,
independent reruns, exact-value observations, and timing conditions.

These 23 cases do not measure whole-language support or establish an engine ranking. A parsed file
count also does not prove semantic coverage of every construct in that file.

## Reproduction

Run from the repository root, substituting executable paths for your installation:

```bash
python3 Scripts/benchmark-semgrep.py \
  --semgrep /path/to/semgrep --runs 3 \
  --output-dir Fixtures/ValueFlowBenchmark/.benchmark-results/semgrep

python3 Scripts/benchmark-codeql.py \
  --codeql /path/to/codeql/codeql --build-method swiftpm --timeout 600 --runs 3 \
  --output-dir Fixtures/ValueFlowBenchmark/.benchmark-results/codeql

python3 Scripts/benchmark-cartograph.py \
  --cartograph /path/to/cartograph --runs 3 \
  --output-dir Fixtures/ValueFlowBenchmark/.benchmark-results/cartograph
```

Each runner builds fresh Swift sources and verifies their runtime output before scoring. Raw JSON,
stdout, stderr, tool metadata, and wall times stay in the ignored evidence directory. Semgrep receives
`--metrics=off` and `--disable-version-check`. Its scanned/skipped files and errors are retained.
CodeQL pack installation may download the pinned dependencies on the first run. Cold builds and
warm queries are reported separately; timings under concurrent machine load are not treated as
isolated performance measurements. Do not publish raw logs containing personal absolute paths.
