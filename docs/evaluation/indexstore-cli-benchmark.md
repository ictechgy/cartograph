# Direct IndexStoreDB CLI comparison

This is a correctness/freshness gate and a bounded performance experiment. A green result is **not** a claim that
Cartograph universally outperforms IndexStoreDB.

These fixtures are adapter validation data. The separate [final comparison
preregistration](indexstore-final-protocol.md) defines the independent workload, composed source-to-result metric
and success criteria required before a bounded superiority claim.

## Real comparator

The pinned upstream repository is `swiftlang/indexstore-db`, revision `64aa0b26913249c4e7c21d351a215fba02702003`
from `release/6.4.1`. Its actual executable products are `index-dump` and `tibs`. `index-dump` prints a named index
unit or record; `tibs` is test-build infrastructure. There is no semantic-query command called `indexstore-db` in
this revision.

The comparator arm invokes the **unmodified release `index-dump` executable**, follows current unit-to-record
dependencies and assembles the printed `calledBy` relations in Python. It never substitutes an IndexStoreDB API
wrapper. The external assembly is named explicitly, its source is reviewable, and its launch, dump, parse and memory
costs are included in measurements. Native CLI commands that do not exist are marked unsupported, never scored as
zero recall.

Upstream source and both transitive dependencies are pinned. The lock is checked and builds use
`--force-resolved-versions`. A supplied checkout must already be at the exact commit with no tracked modifications
and the same dependency lock. Untracked and ignored files under `Sources/`, `Tests/`, `Plugins/`, or root
`Package*.swift` manifests are rejected because they can change the compiled executable without appearing in `git
diff HEAD`. Unrelated research outputs remain allowed. The default path clones and builds a fresh checkout,
preserving acquisition/build logs and costs.

## Run on macOS

Choose one Xcode toolchain before running. The script uses `xcrun --find swiftc` by default, records its actual
version, uses the sibling Swift package driver for both builds, and checks that Cartograph's selected libIndexStore
has the same bytes as the comparator library. It does not infer a Swift version from a runner name. A mismatched
standalone toolchain/library fails clearly.

Full release-build and query comparison:

```sh
python3 Scripts/verify-indexstore-benchmark.py
python3 Scripts/benchmark-indexstore-cli.py \
  --cartograph-package "$PWD" \
  --output "$RUNNER_TEMP/indexstore-cli-benchmark" \
  --repetitions 5
```

The output directory must be absent or empty. Existing evidence is never deleted or overwritten.

`--cartograph-package` builds the current repository's release product into a fresh benchmark scratch directory. It
preserves the source revision, working-tree status, manifest/source hashes and complete resolve/build wall time and
RSS. Repository acquisition is identified as caller/CI-provided and is outside this measurement. Compiler SDK/global
SwiftPM caches are not cleared.

For an already-built executable:

```sh
python3 Scripts/benchmark-indexstore-cli.py \
  --cartograph /absolute/path/to/cartograph \
  --output /absolute/path/to/new-evidence-directory
```

Supplied-binary mode explicitly marks Cartograph's build configuration and setup cost unknown. Use package mode for
a release-to-release setup comparison. Both modes record binary hashes and reported versions.

Useful options:

- `--swiftc /absolute/path/to/swiftc`: choose the compiler. On macOS its library must still match the Xcode
  selection used by Cartograph.
- `--lib-index-store /absolute/path/to/libIndexStore.dylib`: explicit comparator library; the same-library check
  still applies.
- `--indexstore-checkout /path/to/exact/unchanged/checkout`: reuse a checkout; clone cost is explicitly unmeasured.
- `--jobs 4`, `--setup-timeout 1200`, `--query-timeout 120`: bounded process controls.
- `--repetitions 5`: default CI count; increase explicitly for a dedicated experiment. Five samples are noisy and
  insufficient for broad statistical claims.

Linux can verify the baseline infrastructure with `--baseline-only`, which never emits a successful Cartograph
comparison status. Cartograph remains a macOS product; no portability changes or fake executable substitute are
included.

## Fixtures and independent expected outcomes

`Fixtures/IndexStoreCLIBenchmark/basic` has three source files: overloaded integer/String leaves, a cross-file
caller chain, a disconnected function, and a disconnected two-function cycle.

The separate four-file `holdout` validation fixture models checkout impact. An integer price feeds a shared subtotal
used by receipt and preview paths; tax has its own consumer path. An unused String overload and unused quote
function provide negative controls. The fixture also contains a disconnected audit cycle. This fixture was authored
alongside the harness; “holdout” does **not** mean a statistically blinded or representative real-world sample.

Each oracle explicitly lists expected semantic call edges, SCC membership, direct/transitive caller sets, runtime
output, and post-edit expected outcomes. Neither product generates the expected answers. `// oracle:` source markers
identify declaration locations; each arm independently resolves those locations to USRs. All markers must resolve
uniquely, and both arms must agree on identity. Unmapped extra graph edges or caller results remain false positives
instead of being filtered away.

Measured common task: answer one batch of direct and transitive caller queries, including overload/disconnected
negatives. Native Cartograph `query --batch --depth 64 --limit 1000 --edge-kind call` answers this task directly.
The baseline invokes actual `index-dump`, then performs explicit external assembly and traversal. Both arms resolve
source selectors and validate complete call graphs/SCCs in separate discovery runs. Timed baseline workers use the
already-resolved symbol identities and calculate only direct/transitive callers; they do not reread source markers,
enumerate SCCs, or serialize a graph answer. The native Cartograph timed arm answers the same caller batch.
`selector_discovery` records each arm's full discovery workflow, including selector resolution and output
normalization. `discovery_plus_first_query_workflow_seconds` also exposes the combined first-use cost for each arm,
so excluding discovery from repeated queries cannot hide it. SCCs are graded from each arm's call graph before
repetition and after rebuilding; the native `cycles` command is not separately timed or graded.

Both arms read exactly the same compiler-produced index-store path. Full index-content fingerprints are checked
outside timed query sections to detect unexpected mutations. Each fixture has its own explicit Cartograph config so
a parent repository's filters cannot leak into the comparison.

## Freshness sequence

For each fixture:

1. Compile once to stable output object/unit paths; run the executable against a literal runtime oracle.
2. Verify both graphs and caller batches against the initial source oracle.
3. Run repeated new-process query pairs in seeded randomized order.
4. Remove one call from the source without rebuilding. The shared index hash must remain unchanged. Old compiled
   facts are scored against the compiled oracle, separately from the changed source. Native Cartograph must disclose
   `index-staleness:`; raw `index-dump` has no such native warning and receives no invented warning-recall score.
5. Rebuild into the same index and stable object paths. Both arms must match the new source oracle, Cartograph's
   stale warning must clear, and the index fingerprint must change.
6. Restore and rebuild the original source; original answers must return.

The baseline follows active unit dependencies and does not recursively treat every record file as current. Obsolete
record bytes may remain after rebuilding. No “newest unit wins” shortcut discards legitimate compilation contexts.

## Metrics and failure behavior

Every command has recorded arguments, working directory, return code, stdout, stderr, wall time, CPU time, and
`wait4` maximum RSS normalized to bytes. The latter is OS-reported waited-process high-water data, **not** a
measurement of simultaneous aggregate process-tree memory. Linux reports KiB; macOS reports bytes. A 1 ms wait loop
can add ordinary scheduling/poll jitter. All subprocesses have deadlines and process-group termination/kill cleanup.

Precision and recall use exact TP/FP/FN against source expectations. Undefined empty-set precision/recall are JSON
`null`; empty negative controls are judged by exact set agreement. Missing, ambiguous, malformed, reordered or
truncated native query output fails closed. Performance distributions report sample count, min, median, nearest-rank
p95 and max. No timing threshold is used as a correctness gate on a shared CI host.

“First observed” means a new-process observation, **not** a filesystem-cold measurement. Fixture compilation,
selector discovery and preceding reads may have warmed caches. Repetitions also launch new processes; OS caches and
Cartograph's normal on-disk reader cache may be warm. Both initial graph-discovery workflows and their combined
discovery-plus-first-query costs remain visible. Raw-output capture and process measurement overhead remain part of
these instrumented workflows; this is not a claim about every optimized external assembler. No warmed MCP session is
compared against a cold baseline, and no claim is made about a persistent cached assembler.

Exit codes:

- `0`: all requested checks passed; inspect status to distinguish `passed` from diagnostic `baseline_only`.
- `1`: completed comparison exposed a correctness/freshness mismatch.
- `2`: setup/execution/contract failure; inspect the preserved evidence and error.

The result always leaves `superiority_claim: null`. Real product conclusions must be bounded by the source-verified
tasks, complete setup/cache accounting and observed costs. Add pinned public projects and independent outcomes
before making broader practical claims. A synthetic pass alone does not fulfill that requirement.

## Local raw evidence preservation

Keep `results.json`, setup/run logs and exact compiler fixture inputs in the local task workspace,
including failed rounds. Never upload the raw directory or binary indexes to a public repository or
Actions artifact. The public bundle below preserves every included observation and cost with hashes
linking it to the unchanged originals; source/compiler manifests and index fingerprints replace
binary-index publication.

`Scripts/verify-indexstore-benchmark.py` is an offline harness test suite. Its synthetic JSON cases
verify scorer/parser/timeout behavior and are not observations of a real Cartograph executable.

## Real public-project validation

The same installed tools also run against a pinned 53-file Swift ArgumentParser package. Its source-authored
oracle covers the constrained `StringProtocol.editDistance(to:)` caller chain, overloads, recursion and exact
minimum depths. See the [fixture protocol](../../Fixtures/IndexStoreCLIBenchmark/argument-parser-validation/README.md).
This remains validation data, not the final independent holdout. Repeated cached-assembler and fresh native CLI
measurements are explicitly different state regimes and cannot establish persistent-session superiority.

## Public evidence bundle

For public CI artifacts, keep raw evidence locally and run
`Scripts/normalize-indexstore-evidence.py` before uploading anything. Upload **only** its separate output directory
when normalization succeeds. A benchmark failure still has useful evidence; a normalization failure blocks upload
and must never trigger a raw-artifact fallback.

```sh
python3 Scripts/normalize-indexstore-evidence.py \
  --input "$RUNNER_TEMP/indexstore-evidence" \
  --output "$RUNNER_TEMP/indexstore-public" \
  --prefix WORKSPACE="$GITHUB_WORKSPACE" \
  --prefix RUNNER_TEMP="$RUNNER_TEMP" \
  --prefix TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swiftc)")")" \
  --prefix DEVELOPER="$(xcode-select -p)" \
  --prefix HOME="$HOME"
```

Use existing, explicit path values; do not capture or upload an environment dump. `--input` and `--output` must be
absolute, disjoint directories. Output must be absent or empty. Repeatable `--prefix LABEL=ABSOLUTE_PATH` arguments
map workspace, toolchain, cache or other expected path roots to stable `$LABEL` tokens. `$EVIDENCE` and
`$PUBLIC_BUNDLE` are automatic. Labels must be unique uppercase identifiers. If Python or SDK locations fall outside
these roots, provide an additional explicit prefix. SwiftPM may also emit a virtual output root; for example,
`--prefix SWIFTPM_VIRTUAL_BUILD=/swift-argument-parser.build` covers the observed Linux project-unit output paths.
Unknown absolute paths block publication instead of being
silently retained or guessed. Known fixed system paths receive documented system tokens. Log references inside JSON
become artifact-relative references and must name a selected file.

The static allowlist copies only:

- `results.json`, bounded JSON/stdout/stderr files under `setup/` and `runs/`, the setup dependency lock,
  and the exact `setup/cartograph.yml` config;
- fixture Swift source text, `oracle.json`, `.cartograph.yml` and `.build/output-file-map.json`.

It excludes binary index records, build objects, executables, dependency checkouts and global caches. The limits are
10,000 files, 8 MiB per file and 64 MiB total, checked before output is written. Unexpected binary content, symlinks,
ambiguous JSON, unknown paths, known credential fields or values, token-bearing/signed URLs and environment dumps
block normalization. The original raw files are unchanged. JSON numbers, booleans, nulls, failure statuses, return
codes, timings and RSS values retain their values; only paths and JSON formatting change.

`manifest.json` records the normalized invocation, explicit prefix roles and hashed original prefixes, fixed system
mappings, and each included file's original raw SHA-256, normalized SHA-256 and byte counts. These hashes permit local
comparison with the retained originals without publishing their absolute paths. The manifest status is
`normalized_for_review`, not a privacy certification: automated screening cannot recognize every secret or personal
fact in arbitrary text. Review the normalized bundle before publication. Exit code `2` blocks publication; exit code
`0` indicates a complete normalized bundle. Do not upload a partial directory after any failure.

Run `python3 Scripts/verify-indexstore-evidence.py` for offline regressions using synthetic sensitive-looking values.
They check unchanged raw hashes, exact metric/failure values, excluded binaries, normalized paths and relative log
references, empty-output enforcement, unknown-path rejection, escaped credential JSON keys, and signed-URL rejection.
