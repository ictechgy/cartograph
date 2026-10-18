# Fresh-query phase diagnostic

`CARTOGRAPH_DIAGNOSTIC_QUERY_PHASES=1` opts a `query` invocation into a small, fixed phase
profile. No new command or public Kit initializer argument is added. The normal observer
is nil: measured bodies execute directly without reading a clock. Other variable values
leave the diagnostic off, and non-query commands do not read it.

```sh
CARTOGRAPH_DIAGNOSTIC_QUERY_PHASES=1 cartograph query --batch requests.json \
  --project /path/to/project --index-store /path/to/index > answer.json 2> phases.stderr
```

On leaving `QueryCommand.run`, including a thrown error, one extra stderr line starts with
`cartograph-query-phases-v1`. Its fixed fields are:

- `cli_setup`: request reading, configuration and environment setup
- `input_preparation`: external retention, project inventory and provider setup
- `raw_snapshot`: the existing index provider's snapshot load; live Kit uses the raw reader
- `syntax_context`: enrichment, empty-index checks, runtime facts and context construction
- `graph_query_setup`: symbol graph, baseline, lookup, limitations and diagnostics
- `found_facts`: reachability and reference-evidence preparation, only when needed
- `answer`: resolving and constructing answers, summed across a batch
- `serialization`: existing sorted JSON encoding
- `cli_output`: writing output and existing exit decisions

Values are nonnegative wall-clock seconds with nine decimal places, or `not_run` when the
phase was skipped. The record contains no paths, requested symbols or error text. Normal
stdout, output-file bytes and error decisions stay unchanged. The write is best-effort: a
failed diagnostic sink must not replace a successful result or the original query error.
Argument-parser failures before `run` do not produce a record. An explicit diagnostic is
not suppressed by `--quiet`.

## Default fixed native capture

The existing macOS comparison job runs `Scripts/diagnose-query-phases.py` after its public
ArgumentParser and prepared-session checks. It reuses the successful frozen project,
source-authored oracle, compiler index, configuration, release binary and admission checks.
It changes neither benchmark arm nor the existing publication scanner.

Without baseline arguments, there are exactly 14 fresh query processes. The real `fullMessage` overload ambiguity,
one deliberately absent name, and a mixed batch with a duplicate found request each run
off/on. The existing depth-5 `editDistance` request runs four AB/BA pairs, where A has the
variable absent and B sets it to `1`: `[A, B, B, A, A, B, B, A]`. No adaptive repetition,
cache flush, source edit or extra project is used.

Each process retains its complete stdout, stderr, exit, command, external wall time,
user/system CPU and wait4 maximum RSS. Every case must have byte-identical stdout and
matching exit status. Removing exactly one valid phase record from enabled stderr must
leave ordinary stderr byte-identical. Found answers must satisfy the frozen source oracle;
ambiguity must include both authored overloads; missing requests must retain exit 64.
Request order, duplicates and lazy found-only preparation are checked. Source/index/config,
runner and request hashes are checked before every command and after the final command.

Only after all parity gates pass are internal phase sums and external-wall residuals
reported. Outer wall times must be finite and nonnegative, and the sum cannot exceed that
wall by more than one microsecond of rounding tolerance. Residuals within that tolerance
are clamped to zero; raw phases and outer measurements remain available. A final shared
deadline check follows the final byte verification. These are instrumented estimates.
Residuals include startup, argument parsing,
small gaps, observation/diagnostic writes, teardown and process-recorder overhead. They do
not isolate those costs. Enabled-minus-disabled medians also include noise and order/cache
effects. This is an instrumentation diagnostic, not a comparative speed or superiority claim.

Each process is capped at 45 seconds and 1 MiB per output stream. A 300-second shared alarm
enters the existing process-group cleanup; the CI step has a six-minute cap. Raw records
are retained under `runs/query-phases` in the existing normalized project artifact. Existing
output directories are refused. Failed attempts remain failed; there is no automatic rerun.

## Optional exact-revision paired capture

Supplying `--baseline-setup-results` and `--baseline-revision` together adds a second
Cartograph arm. The baseline is the exact accepted pre-projection main revision, including
the preceding detection fixes; it is not the older Impact-cache baseline. Both arms must
come from clean, successful release builds with the same captured toolchain. The baseline
revision, captured Swift/package input membership and hashes, and both binary hashes are
checked before queries run.

The same frozen public project, compiler index, configuration and requests are used by both
binaries. Each of the default 14 slots runs once per arm, for 28 fresh processes total.
Baseline/candidate order alternates by slot. Full stdout bytes, exit status and ordinary
stderr after removing the phase record must match across both arms and all repetitions.
The existing per-process and shared driver caps are unchanged; no adaptive repeats or
cache flushes are added.

After all gates pass, `QueryProjectionTiming` prints a bounded numeric summary containing
the exact source revisions and binary identities. Each arm retains its absolute wall,
instrumented phase and process-lifetime wait4 RSS medians. The median of per-pair wall-time
ratios is reported separately; it is not the ratio of the two absolute medians. Found
requests have four pairs per instrumentation state; other shapes have one pair per state.
RSS is neither process-tree nor per-phase memory, and fresh-process execution does not
establish cold-cache behavior. Results cover this one workload and do not prove general
speedup or superiority over another tool.

The comparison job rotates the previously recorded one-off Impact timing experiment to
this query experiment within its existing budget. Historical Impact receipts remain
available, and ordinary Impact correctness, cache and refresh tests remain required.
This rotation does not represent a persistent Impact performance regression gate.

## Verification status and scope

At the original reconstruction after a cloud workspace reset, the earlier local payload and
test logs were unavailable; their byte identities and results were not reused.
`python3 Scripts/verify-query-phases.py` checks finite parsing, exact record removal, bounded
real Python children, cancellation, schedule, output mutations, oracle checks and the
unchanged publication boundary. Optional-mode tests also check exact baseline admission,
paired ordering and ratios, and rejection of mutated outputs. Synthetic test timings are
not native measurements.

Swift tests cover no-clock disabled execution, exact opt-in, timing/error propagation,
found/ambiguous/missing/batch output parity, lazy found-only work and failed diagnostic sinks.
Native compilation, these Swift tests, the full coverage/CLI/fixture/self-analysis gates,
and actual CLI parity/capture must pass on the proposed commit before drawing conclusions.
The original reconstruction had no native phase capture; this historical note does not
summarize later CI runs. Optional paired mode requires its own exact-head hosted result
before any timing conclusion.

The fixed capture covers the four batch shapes above. Broader output-file and malformed-input
behavior should continue to be checked through the existing CLI contract suite. These timings
do not replace the published fresh-CLI or prepared-session endpoint measurements. Existing
`--batch` and `serve` already provide the practical reuse workflows.
