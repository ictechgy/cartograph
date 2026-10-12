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
