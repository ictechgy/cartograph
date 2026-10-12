# One restored-state correctness integration: implementation review candidate

This draft is local and unintegrated. It has no native execution, calibration schedule or final holdout.
Historical runtime primitive c58845e8 and engine primitive 2cbe13ea copies are recorded in provenance.
Current runtime bootstrap/measurement overrides are explicit; the original engine primitive remains unchanged.
The original engine `run_arm/run_state` and ambient measurement entrypoints are never called.
The independent source scorer is an additional exact copy of the existing mixed fixture scorer.
The prospective installer amendment is the separately reviewed 9e8ebd01 snapshot, unchanged.

## Fixed input, runtime and execution contract

The controller requires explicit repository, successful 13-state fresh-shared-v2 lifecycle, original
tool setup, and successful native helper results from the same current CI task. It selects only the
restored_rebuilt state. The original query-spec and source oracle have pinned unchanged SHA256s.
Engine requests contain only the ten distinct source selectors and the frozen primitive's permitted
fields; the oracle path/hash stays outside engine requests. The baseline assembles one graph/reverse
adjacency for all ten queries; native performs complete graph binding plus its actual query batch.
There is one fixed AB pair, no warmup, default projection, performance ratio, bootstrap or success gate.

The controller starts with -I -S -B and imports only standard-library code before package validation.
A retained first-red caught an indirect psutil import through the primitive; preparation now uses
stdlib-only selector/input helpers. Each later supervisor/engine Python exec goes through the source-bound version-2
verified bootstrap, including the frozen process helper's --worker. Actual imported psutil/extension
origins and pre/post code/package/module identities are retained. No ambient site/PYTHONPATH fallback
or second package installation is permitted. Source lists are explicit, not inferred from extra files.

The existing one-time pip --target installation receives its approved prospective interpreter receipt.
Installation binding requires its exact argv, original private report hash, duplicate receipts, all
helper source hashes, matching before/after interpreter bytes/metadata and current package inventory.
Absent historical interpreter receipts cannot satisfy the default integration gate. The private pip
report is hashed but never parsed into or copied to the public packet; its existing narrow provenance
projection remains the only public package metadata. This does not establish wheel-to-tree equivalence
or complete interpreter/OS loader closure.

The already-executed SDK diagnostic must have a completed process and passed generation guards. Its
full cost and identical per-arm charges are retained by exact reference, even when unknown runtime
search roots keep discovery red. It must bind the same lifecycle. No SDK/root/content acceptance follows.

Inputs and outputs are checked for lexical/physical overlap before creating output. The external
attempt, raw and public directories have fixed names under the exact current CI RUNNER_TEMP root.
Malformed inputs can retain an attempt there; they cannot authorize arbitrary write destinations.
Engine and observer HOME/TMP/cache are distinct, initially empty private-readers trees outside the
published setup/runs allowlist. Only normalized identities, not cache contents, enter public evidence.

## Process and cost diagram

1. stdlib-only supervisor -> isolated preparation child (600-second outer safety limit).
2. preparation binds prior inputs, collects up to two clean startup probes (30-second bound each),
   verifies the shared profile and one selected launch, then runs the complete 292+53 prerequisites
   through separate bound processes (180-second bound each) before creating runtime/plan manifests.
3. preparation -> verified whole-state bootstrap (540-second limit).
4. state worker -> verified frozen observer bootstrap -> verified engine bootstrap -> actual CLIs.
   Each arm has a 240-second bound; each actual CLI retains its existing 120-second bound.
5. after A's completed terminal guards, run B once. After both arms' terminal guards, the separate
   evaluator reads the source oracle and compares all definitions, call edges and ten caller batches.
6. whole-state bootstrap closes post-code/package/module guards; preparation rechecks generation,
   writes its final receipt, then exits. Supervisor records the full child exit and wall time.

Within the state worker, directly recorded contiguous intervals are setup, A, B, evaluation and
finalization/failed work. Each arm includes its receipt write in the enclosing interval. Within the
preparation child, contiguous intervals are preparation, the whole-state supervision call, and terminal
verification/failed work. The command's own process wall is nested inside that supervision-call interval.
The outer child wall includes import/startup before the first inner clock, final receipt serialization
and normal interpreter teardown after the last inner clock. Those remainder costs are not assumed zero.

All inner observer/engine/CLI timings are nested explanatory observations, never added again to the
physical enclosing wall. Prior acquisition/build/install/shared-generation/SDK costs remain exact sealed
references. No final composed or existing-built endpoint is exported by this correctness diagnostic.
No calibrated average is subtracted. Embedded observer overhead and actual-arm memory calibration remain
unmeasured; the fixed AB order and OS caches support no speed or memory superiority claim.

Reserved 125, signal, timeout, launch failure or unavailable terminal guards prevent the second arm.
Ordinary nonzero retains post-guards and may retain the other arm only if those guards completed.
Process-group cleanup plus the frozen observer does not prove detached macOS descendant containment.
Failures preserve original observed return codes and costs; forced/incomplete work is never a pass.

## Publication contract

The strict general normalizer is copied unchanged. Public staging selects setup/runs/results text,
raw/normalized hashes and a separately verified hash-only attempt envelope. Binary indexes, compiler
outputs, package files and private-reader cache contents are outside selection. Credential/path blocks
keep CI red; no raw fallback is possible. Only a complete staged normalized subtree is promoted.

The envelope binds exact source/argv/phase hashes and observed exit/cost. Capture-time unavailable log
identities remain unavailable; present publication reads are separate and cannot upgrade the run.
Missing detailed output still permits a safe attempt. An available capture hash that later changes
blocks that receipt. Current source unavailability retains original phase evidence with a red status.
A normalized partial bundle is not marked complete without its whole-controller completion receipt.
Prefix mappings are publication tokens only, not SDK/runtime input-root or hermeticity acceptance.

## Current control evidence and remaining freeze work

The historical initial integration freeze passed 105 integration contracts, 43 runtime contracts and the
21 existing installer contracts. The preceding exact isolated startup freeze passed 263 integration and 53 runtime
controls with no skips and completed terminal guards. The exact extension-loader successor then passed 267
integration and 53 runtime controls with normal exits, no skips and completed terminal guards. Six integration
controls use actual isolated processes: success,
ordinary exit 9, reserved 125, SIGTERM, launch failure and timeout; they use declared synthetic engine
scripts and do not represent product results. The initial import failure and all earlier local failures
remain retained. Source-authored oracle mutation controls retain missing definitions/edges/extra callers.

Before publication/native execution, review this complete source freeze, the bounded `.github/workflows/ci.yml`
and COPIED-PROVENANCE.json, then inspect the eventual combined immutable repository tree. No real product
arm, native calibration, final SDK seal, independent holdout or performance session is granted by these
local tests. The final protocol and thresholds remain unchanged.


The workflow proposal reuses exactly the existing single psutil installation with the separately approved
prospective interpreter amendment. It retains the existing runner/job budget and runs only this one AB
correctness pair after successful mixed/helper setup and terminal SDK generation guards. SDK's ordinary
unresolved-root failure does not imply acceptance; an incomplete SDK process refuses the arm controller.
The safe-publication step is independent and ready-gated. No second install, warmup or calibration occurs.

Additional first-red controls found and fixed malformed non-object lifecycle failure retention, untyped
source-guard acceptance, extra historical log fields and unvalidated privacy-diagnostic metadata. A
completed whole-state failure now retains its generation/source guards even if the runtime receipt is
missing. The three outer-flow controls mock the product worker only to verify contiguous costs/failure
sequencing; the six isolated subprocess controls remain the actual local process-layer tests.

Current executable bytes are rebound to the original successful setup receipt, including its completed
baseline command/help and untracked-source checks. This diagnostic does not rebuild the tools or prove
reproducible source-to-binary equivalence. Original acquisition/build/source provenance and all costs
remain in the referenced setup, rather than being credited as a new build or a zero-cost install.


## Reviewed-freeze successor corrections

The original 90-control freeze is retained. Staging now preserves a second attempt observation and
requires current source identity before promoting any normalized detail. Successful completion admission
requires typed exits and actual whole-state process, plan, runtime-input, runtime-result and state-result
files, exact JSON agreement with embedded records, request-bound runtime guards and raw hashes matching
the normalized staging manifest. Boolean zero, missing files, contradictory state/runtime outcomes and
post-normalization source changes refuse success. Ordinary failed/incomplete controller outcomes retain
their own explicit labels. Synthetic receipt controls exercise schema binding; they do not replace actual
isolated process controls or native execution.

The proposed SDK selector changes exactly one RUNNER_SHA256 literal to the unchanged approved installer
successor hash266d771f. The old selector correctly refuses those new bytes; the new pin accepts exactly
them and retains the existing five-argument command API. The frozen copied discovery-receipt reader in
runtime/vendor remains byte-identical: only its bounded file-identity API is used there, never its runner.
WORKFLOW-PROPOSAL.yml must apply this selector pin alongside the installer, before combined native review.


## Prospective startup profile integration

The next source-only successor first collects at most two clean-request startup observations inside the
existing supervised preparation child. The original installation-selected spelling and current spelling
must identify the same physical interpreter. Only the observed Darwin startup addition can be matched by
bounded hash/length; requested environment keys/values are unchanged. The collection precedes selected
exec and prerequisites. An incomplete collection stops without later phases. A one-exec replacement
reuses the exclusive collection and cannot initiate another probe.

All initial controller/publisher local imports and probe-local imports compile their admitted source bytes,
with bounded no-follow reads and no local bytecode fallback. The actual runtime bootstrap keeps its fresh
private cache and adds a separately request-bound before/after environment observation for each process.
Its shared profile does not replace the existing interpreter, source, package, command or exit guards.
Whole child wall includes collection, repeated guards, exec, all suites, state and normal teardown. Inner
collection/process intervals are explanatory and must never be added to that wall again.

Successful publication now requires runtime configuration version 2, the original verified profile/launch
collection, exact public copies and actual per-process environment-request receipts. Failure summaries
retain capture hashes and nested costs while remaining failed/incomplete. The original scanner and fixed
measurement worker are unchanged. These controls do not certify Apple startup behavior, SDK contents,
complete native loader/cache state, a final endpoint, observer calibration or performance superiority.

Local native-extension loader create/exec paths are also rejected before native code can run, using both lexical and resolved origins. This applies only to the declared controller source tree; the separately sealed private psutil installation remains outside that tree. Regression controls mock the native loader and never compile or load a new binary.
