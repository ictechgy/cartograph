# Mixed Swift / Objective-C iOS validation

This is adapter validation data, **not the independent final holdout**. The original
source-authored expectations are frozen before native Cartograph observations. A successful
compiler run alone does not establish product correctness or comparative superiority.

## Contract

- Twelve source/config inputs cover `.m`, `.mm`, Foundation Objective-C, Clang module headers,
  one physical Swift source compiled in FeatureAlpha and FeatureBeta, protocol extensions,
  overload negatives, and cross-module AppFlow callers.
- `oracle.json` defines 29 context-qualified source identities, 23 initial compiler-call edges,
  ten fixed caller queries and five source variants. No expected compiler USRs are supplied.
- Thirteen declared states cover header edit, rename, deletion, expected compilation failure,
  Swift rename/deletion, retained stale records and complete source restoration.
- `framework-oracle.json` is a separate XCTest lifecycle/test-selection contract. Optional
  `--with-tests` compiles XCTest source only. This harness neither executes XCTest nor scores
  framework-aware selection as compiler-call precision/recall.
- `source-manifest.json`, `source-call-audit.txt` and `immutable-inputs.json` preserve the original
  source/oracle/audit bytes. `DESIGN.md` explains source semantics and compiler command references.

The `adapter/` directory invokes the actual pinned `index-dump`, follows active output/unit/record
provenance, binds each arm independently to source identities, and retains every unmapped or extra
owned callable. It does not generate expected answers. Native `graph --include-self-loops --level
symbol` is explicit; the default graph and its score remain separately visible. Native caller
queries still exclude their seed. Unsupported options fail without a weaker fallback.

## Run

From the repository root:

```sh
python3 Scripts/verify-indexstore-mixed.py
python3 Scripts/benchmark-indexstore-mixed.py \
  --setup-results /path/to/passed/indexstore-cli-benchmark/results.json \
  --output /new/empty/mixed-validation
```

The native run requires a selected, already installed full Xcode on macOS. It reuses and verifies
the recorded binaries, upstream revision/dependencies and exact libIndexStore bytes. The default
SDK is `iphonesimulator`; compilation is build-only, with no signing, app installation or simulator
boot. Explicit `DEVELOPER_DIR` can select an existing toolchain. Actual compiler/SDK versions,
commands, source hashes, index hashes and costs remain in the evidence.

For compiler-plan inspection only:

```sh
python3 Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/run_ios_validation.py \
  --plan --with-tests --output /new/empty/compiler-plan
```

Plan mode executes no compilers or observer, and never claims native coverage. Placeholder SDK
paths in plans are not publishable runtime evidence. The public normalizer must remain fail-closed.

## Failure retention and evidence layout

The outer driver keeps `results.json`, `setup/observer-argv.json` and lifecycle command logs.
Its `validation/` child contains:

```text
results.json
setup/setup.json
setup/<command>.json, .stdout, .stderr
runs/<state>/state.json
runs/<state>/commands.json
runs/<state>/<command>.json, .stdout, .stderr
runs/<state>/observation/...
private-snapshots/<state>/sources.tar.gz
private-snapshots/<state>/index.tar.gz
Project/..., Build/..., IndexStore/...
```

Every output directory must be new or empty. Partial setup, command launch failures, timeouts,
interruptions, missing compiler outputs and wrong diagnostics are retained. Failed compilation
never becomes the accepted indexed state. Secondary snapshot errors cannot replace the original
failure. Source-only states reuse byte-identical private index archives.

The runner normally stops on any observation failure. The outer pilot explicitly requests
`--continue-observation-failures` so every declared state can reveal its own failures. All failed
observations remain failed, the overall run exits nonzero, and the shared compiler state advances
only after accepted compilation. Source or index mutation by an observer always aborts immediately,
including when that observer also exits nonzero. Continuation is limited to normally completed positive
exit statuses. Timeout, launch failure, signal termination and interruption abort before any later
source state; descendant cleanup is not inferred from a timed-out Python root. This option cannot turn
incomplete coverage into a pass. Freshness checks accept only a successful structured query limitation
that identifies the required changed header or moved/deleted Swift path. A path appearing only in normal
graph output, an unrelated warning, generic counts or partial failure output cannot satisfy that gate.

## Public boundary

Raw source copies, binary indexes, objects, archives, global caches and environment dumps stay
local. The workflow normalizes two separate text-only bundles, `mixed-setup` and `mixed-ios`, and
uploads them only if the entire normalization step succeeds. Every selected command/output/failure
is retained with raw and normalized hashes. A normalization failure never uploads raw fallback data.
The source catalog diagnostic uses `declaration_lexeme` for a declaration's lexical name; the
binding catalog and frozen oracle are unchanged. Credential screening is not weakened for it.

## Verification scope

Offline checks cover wrapper failures and mutation detection, strict parsers, active-unit selection,
source identity, exact scoring, negative controls and publication layout. Compiler stubs exercise
orchestration only. Real Linux diagnostic runs cover eight Clang/header lifecycle states, retained
orphan units, two Swift contexts sharing one physical source, and Swift rename/delete. Those runs
do not establish iOS Foundation interoperability, native Cartograph header coverage or native
freshness behavior. Exact-head macOS CI provides those observations, including failures.

No speedup threshold or superiority verdict is emitted. Final statistical and holdout requirements
remain in [the final protocol](../../../docs/evaluation/indexstore-final-protocol.md).

## Versioned shared compiler generations

`--compiler-index-policy incremental-diagnostic-v1` is the unchanged default. It recompiles into
one persistent store/output tree and deliberately retains the original stale-module, orphan-unit
and partial-failure behavior. Existing results keep their original status. A later policy run
cannot replace those failures or turn this fixture into an independent holdout.

`--compiler-index-policy fresh-shared-v2` selects the separately declared supported workflow:

```sh
python3 Scripts/benchmark-indexstore-mixed.py \
  --setup-results /path/to/passed/indexstore-cli-benchmark/results.json \
  --compiler-index-policy fresh-shared-v2 \
  --output /new/empty/fresh-shared-validation
```

The existing mixed CI step explicitly selects `fresh-shared-v2` for validation only; it runs one
cohort per CI job to preserve the existing evidence bounds. The CLI default stays incremental and
all earlier failed diagnostic archives remain unchanged.

The option is also accepted by `run_ios_validation.py`, including `--plan`. Each build attempt
creates empty `Generations/<state>/IndexStore` and `Generations/<state>/Build` trees. Every declared
Clang/Swift compilation runs again; objects, output maps, Swift modules and the Swift/Clang module
cache all use this generation's paths. No old index/cache is copied, scrubbed or restored. The same
physical accepted generation is supplied to the actual CLI plus external assembler and to native
Cartograph. This changes shared compiler preparation, not either engine's source oracle or scoring.

A generation is accepted only after all commands complete successfully, every declared object and
Swift module exists, Clang dependencies contain the required header, completed index units exist,
and source/config bytes plus compiler/frontend/library hashes still match. Command, source, complete index
and complete build-file manifests are sealed before the observer runs. The existing module-artifact
manifest must match the current adapter's source/output/target/SDK associations. Both arms recheck
accepted bytes, including objects and module caches. Accepted trees are never renamed after
compilation, so compiler-recorded absolute output paths remain valid.

Source-only stages continue observing the last accepted generation and must still report stale
source paths. An expected missing-header build writes only to a new rejected generation; its
partial index/output bytes and hashes remain in place, while the observation uses the last accepted
successful generation. Other build failures abort. Rejected bytes never seed an arm or a later
build. No accepted predecessor means no observation. Timeouts, signals, launch errors and interrupts
abort the lifecycle; retained snapshots of an incomplete process are explicitly unverified. Nested
observer failures propagate reserved exit 125 rather than becoming ordinary continuable exit 1.
This proves no cleanup of surviving descendants and makes no claim that incomplete bytes are stable.

Every state's `shared_input_cost` records the entire compiler preparation interval, including new
directories, output maps, command logging, compilation and acceptance hashes. The full measured value
is charged once to each arm, including failed attempts; it is never divided by two or replaced by an
engine-only time. Compiler subprocess times remain separately visible. Initial project copying is
reported and charged equally in setup. One-time runtime/toolchain sealing and each state's preflight
accepted-generation integrity checks are separate, equal per-arm components that must be included
when composing a final endpoint. Observer guard/discovery and arm/session work also remain outside
this rebuild component; it is not the complete validation or source-to-result duration. Private
evidence archive times are reported separately and never seed runtime inputs. Source-only states have zero rebuild cost; plan costs are null. These are
cost components, not a final paired-performance result. Full final comparison still requires the
preregistered arm/session costs, randomized order, independent holdouts and statistical gates.

The motivating compiler-only diagnostic distinguishes current object/IR semantics from stale
module-index facts after header edits/renames. Resetting only the PCM cache did not repair those
facts; a fresh index did. That diagnosis selects this workflow to test; it does not establish that
the complete mixed-iOS engine comparison passes. Run both policies in separate evidence directories
and retain their outcomes separately. Raw `Generations/` trees stay private alongside other compiler
bytes; publication continues through the existing text-only normalizer without a raw fallback.

SDK binding is explicitly **version/path-only validation**: the selected SDK path, version and build
receipts do not hash or prove unchanged SDK header/module contents across generations. The metadata
records `contents_sha256: null` and `final_protocol_gate: not-satisfied`. This does not weaken the
frozen source oracle, but it cannot satisfy the final experiment's SDK identity/freshness gate.
Before final execution, pin and seal the complete SDK input identity (or an independently verified
immutable SDK image) and verify it throughout the run. Runtime provenance includes the generation
policy and common validation helper hashes on successful, stale and failed observations.
