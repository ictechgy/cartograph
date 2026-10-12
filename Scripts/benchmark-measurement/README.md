# Final comparison measurement helpers

These are reproducible measurement and arithmetic tools, not final benchmark results. The
[preregistered protocol](../../docs/evaluation/indexstore-final-protocol.md) remains the contract.
No adapter, oracle, holdout, native runner or SDK-content identity is frozen by this import.
Active CI and `fresh-shared-v2` compiler-generation policy are unchanged.

## Provenance and local verification

`provenance.json` records the reviewed source hashes. The process observer is the exact reviewed
successor of the `final-measurement-freeze-20261012T0158` snapshot: it adds private workload environment
transport over worker stdin and creation-time identity to private samples. Its SHA-256 is
`03a6cc72657a560e983b95fa99b7df4ff907a6d41f37fcd3692f6ed694d92101`.
The paired arithmetic, observer calibration, hardware manifest and synthetic workload helpers are
byte-for-byte imports of that frozen snapshot. Historical private samples and machine logs are not
copied into this repository. The older identity-normalizer draft was ported additively into the
current normalizer, preserving compiler-help token handling, credential checks and atomic bundles.

Python 3.10+ and `psutil==7.2.2` are required. From the repository root:

```sh
python3 Scripts/verify-indexstore-evidence.py
python3 Scripts/verify-indexstore-bundles.py
python3 -m unittest discover -s Scripts/benchmark-measurement -p 'test_*.py' -v
```

The suite uses only synthetic allocations, child processes and manufactured cost records. These
checks do not replace Swift product tests or native macOS containment/calibration. The integration
tests exercise actual helper output, normalization, private environment transport and preservation
of timeout failure evidence. A symlinked `TMPDIR` is an intentional supported validation case.

## Separate timing and memory

```python
from pathlib import Path
from process_tree_measure import run

result = run(command, Path(project), Path(evidence) / "runs" / "initial", mode="timing")
```

Timing is the default. Normal execution uses blocking `Popen.wait()` and one POSIX deadline timer;
there is no periodic RSS observer or process-tree scan in the timed interval. One root identity
read and deadline setup remain and must be calibrated. Successful `wall_seconds` ends at observed
root exit. Post-exit descendant discovery is outside that duration; leftover discoverable work
fails the sample. The workload root must wait for every result-producing child.

Use `mode="memory"` only in separate matched sessions, with the independent balanced memory orders
from the committed plan, the same workload/index/query/edit state and private reader caches. Memory
results always set `primary_timing_eligible=false`. Never use their wall time in either timing
endpoint, subtract an observer estimate, or choose memory sessions after seeing timing outcomes.
`caller_elapsed_seconds` includes helper startup/IPC and is not the endpoint cost.

The optional API argument `environment` replaces the workload environment and travels privately
through worker stdin. It is not included in command/result artifacts. Do not put secrets in command
arguments or print them from the workload. Normalization still screens all candidate evidence.

## Process-tree RSS and cleanup limits

Memory mode records each near-simultaneous sampling sweep with monotonic start/end, every observed
process's RSS and a sum. Peak RSS is the maximum sweep sum, never `wait4` max RSS or a sum of each
process's lifetime peak. Sequential reads introduce skew; shared pages are counted in each process;
finite sampling misses short-lived children and peaks. The observed maximum is an estimate, not a
proven bound on continuous simultaneous memory. Actual interval/skew/read-error counts stay visible.

Tracking uses PID plus creation time. TERM, STOP and KILL target individually identity-checked
workload descendants, regardless of process groups or sessions. No host-wide process-name or
command-line matching is used. Linux orphan adoption is isolated to the short-lived helper via a
subreaper. Timeout/cancellation/nonzero exit, observation errors, orphaned live work and cleanup
survivors remain failures. Existing artifact stems are refused, so retries require new stems and
must retain earlier failures.

Native macOS cleanup and calibration remain unvalidated. In particular, macOS may miss a descendant
whose ancestry disappears between sweeps; timing mode deliberately has no sweeps. A cooperative
root that waits for all children or independently verified containment is required. Linux tests
with subreaping disabled are not native macOS validation. Uncatchable SIGKILL still requires external
supervision. OS filesystem-cache coldness is unproved and must be reported as uncontrolled.

## Complete private evidence and normalized derivatives

Each invocation produces `.command.json`, `.stdout`, `.stderr` and `.json`. Memory also produces
`.samples.0001.jsonl`, `.samples.0002.jsonl`, etc. Each chunk is at most 6 MiB; complete rows are never
split or silently dropped. A row too large to fit fails the run. The result retains ordered chunk
names, raw SHA-256, byte counts, sample counts and total bytes. Any disagreement, duplicate, gap,
reorder, missing chunk or unlisted sibling blocks public normalization.

Place helper artifacts under `runs/` or `setup/` in an evidence directory with `results.json`.
Use `Scripts/normalize-indexstore-evidence.py` with explicitly declared path prefixes to prepare a
bounded derivative. Use `Scripts/normalize-indexstore-bundles.py` when preparing the existing bundle
layout: it stages outside the final output and atomically retains only complete normalized bundles.
Blocked bundles retain hash/category-only status diagnostics, with no raw fallback. Neither command
uploads anything. Bundle limits remain 8 MiB per file and 64 MiB total; package evidence per pair
or explicitly manifest-link bounded bundles. Never omit samples to meet a limit.

Only schema-v2 results from the exact pinned successor helper can authorize identity normalization.
Memory chunks must first match the complete raw manifest and exact sample/member schema. The
normalizer preserves stable, injective `process_id` values and every member/RSS/time/count while
omitting only raw `pid` and `create_time`. Cleanup PIDs become surviving-process count and an explicit
unresolved-identity flag; original failure, elapsed cleanup time and other evidence remain intact.
Legacy helper outputs without creation-time identity, unknown hashes, malformed helper schemas and
unbound process samples are rejected. Unrelated domain JSON is not indiscriminately stripped of
similarly named fields. Raw helper process identity must never be published.

Keep private originals and their hashes. Embedded result/chunk hashes always describe unchanged raw
inputs. `manifest.json` separately gives original and normalized SHA-256/bytes for each derivative;
public consumers verify normalized bytes against that manifest. The omission list and normalized
sample-file list make the transformation visible. Calibration's embedded memory receipts must match
one preserved standalone result with verified chunks, allowing only finite nonnegative
`caller_elapsed_seconds` in addition; the manifest records each such binding. Unrelated helper
provenance (including the hardware manifest's own hash) is preserved without authorizing process
identity handling. A hash allowlist identifies a reviewed schema;
it does not authenticate a claimed execution or prove that handwritten samples are real.

Unknown absolute paths, credentials, signed URLs, binary content, duplicate JSON keys, nonfinite
numbers (including overflowing exponents) and invalid JSONL remain blocking. Screening is not a privacy guarantee for arbitrary free text. Human review is
still required before any separately authorized publication.

## Preregistered plan and whole-session arithmetic

```sh
python3 Scripts/benchmark-measurement/paired_sessions.py plan \
  --seed 1729 --bootstrap-seed 2718 --memory-seed 31415 --output plan.json
```

These example seeds are documentation, not a final choice. Before outcomes, commit the real plan,
helper/adapter/oracle/query/edit hashes and pinned runner/toolchain/SDK identity. Plans use exclusive
creation; history and append-only evidence must enforce no favorable reruns or reseeding.

There are exactly 20 independent paired sessions and ten queries per indexed state. Initial,
post-edit and existing-built orders are independently balanced at 10 AB and 10 BA; memory has its
own explicit different seed and balanced plan. Nested queries are not independent observations.

`paired_sessions.py` preserves separately named discovery/setup, refresh, cache-validation and batch
components. Both primary arms receive the same full measured initial and edit compiler-build costs.
Zero components require explicit observed-zero declarations. Preserve one-time acquisition, release
compilation, toolchain/helper seals and preflight guard work as distinct measured evidence; freeze
how each is charged before final execution. Do not hide work between component timers or claim the
analyzer itself verifies raw phase completeness. Index-content fingerprints remain outside query
timers. Adapter execution and raw-receipt binding are still required.

The estimand is the median of the 20 within-pair Cartograph/baseline total-cost ratios. Bootstrap
resamples whole pairs, including shared build cost, using the frozen seed and type-7 95% percentile
interval. The default is 50,000 resamples. Success requires median ratio <= 0.8 and confidence upper
bound < 1, plus all exact accuracy/freshness gates. Failed or missing pairs remain visible and cannot
be dropped into a favorable performance estimate. A secondary existing-built success cannot rescue
a failed/inconclusive primary; overall success is primary-only. Memory/startup regressions >10%
are explicit tradeoffs, not dominance.

Boolean gate declarations and artifact-hash syntax checks are arithmetic input checks only. They do
not prove real CLI execution, source-oracle truth, matched immutable index content, disjoint charged
phases or native cleanup. The final runner must independently establish those facts. No superiority
claim follows from this synthetic suite or this integration.

## Bounded native CI diagnostic

`Scripts/validate-native-measurement.py` requires actual macOS and preserves separate install,
unit/integration test, machine and calibration phase commands, outputs and wall times. `psutil` is
installed from official PyPI into a new task-owned directory outside the evidence tree; inherited
pip index configuration is disabled without changing global settings. No environment values are
serialized. Existing evidence and dependency directories are refused.

The diagnostic fixes four AB/BA-balanced pairs per synthetic workload/mode, randomization seed
20261012, bootstrap seed 101226 and a 10 ms memory interval before execution. It runs the frozen
single-process and twelve-subprocess workloads in timing-only and separate memory modes. Missing,
failed or unbalanced groups block success; no ratio threshold makes this a product-speed result.
Every phase failure stops later phases. Incomplete commands, including a nested helper exit 125, remain exit 125 and retain the observed
raw return code separately. Outer fallback only
signals the owned POSIX process group and does not establish detached-descendant containment.
The existing helper tests separately exercise retained-identity cleanup and report Linux-only
orphan-adoption controls as skipped on macOS. The moving runner, uncontrolled load/filesystem
cache, unobserved macOS ancestry gap, final SDK seal and actual-engine calibration remain open.

CI normalizes this small diagnostic independently and uploads only after its normalizer succeeds,
under `measurement-helper-validation`. It is separate from the larger compiler-comparison artifact.
Original command/sample bytes remain private and normalized manifests retain their hashes.
No final paired sessions, holdout, oracle or comparison endpoint are run or changed by this step.


### Package install provenance publication

The complete pip install report is kept under private-setup, outside the public text selection.
Its public receipt retains the raw report hash/byte count and explicitly declares omitted package
contacts, long descriptions, other package metadata and environment fields. The strict projection
requires report schema1, one requested non-yanked psutil7.2.2 wheel, the unsigned HTTPS distribution
URL on files.pythonhosted.org, consistent SHA256 fields and the actual pip/report versions. Missing,
duplicate or unexpected distributions, schema fields, signed/credential-bearing URLs or inconsistent
hashes fail the diagnostic before later phases. Binary-only installation avoids an implicit source build.

Install command/stdout/stderr, completed/incomplete state and full costs remain public after normal
screening; projection cost is recorded separately. No email or credential allowance was added to the
normalizer. A raw report hash is integrity evidence, not a substitute for successful installation or
verification of the installed binary bytes. Native run38217594404 completed its synthetic diagnostic,
but its helper artifact was correctly withheld because the earlier full report contained package
contact metadata. That round's detailed helper samples remain unavailable; they are not reconstructed
from a later run. All four independently normalized compiler-comparison bundles survived.
