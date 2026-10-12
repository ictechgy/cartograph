# Mixed-language observation adapter prototype

This is preparatory validation. It is not a completed Cartograph-versus-IndexStoreDB comparison, performance result, or independent holdout. Only the portable contracts below were executed here. All implementation and evidence live in this isolated directory; no product worktree or completed fixture was edited.

## Implemented boundary

- `observe_mixed.py --state …`: a synchronous observation hook for the unchanged mixed-iOS lifecycle state schema. `--fixture-root`, `--oracle`, `--query-spec`, `--run-root`, and `--output` are configurable. The state directory may be under `runs/`; no `states/` basename is assumed. Both legacy `<run>/setup.json` and integrated `<run>/setup/setup.json` are supported; the selected path/layout is recorded. A run containing both setup files is rejected as ambiguous rather than silently choosing one.
- `mixed_adapter.py`: strict parsers for the actual pinned native `index-dump` output; current object-output-to-unit validation; recursive unit dependency traversal; unit/record/module/root provenance; source declarations, aliases, graph binding, shortest reverse depths; separate native Cartograph graph and native batch-query binding.
- `query-spec.json`: ten source-signature queries, without expected edges, callers, or USRs. It resolves against the independently parsed source/compile catalog. Both adapters operate before the scorer opens the source oracle.
- `verify_source_catalog.py`: seven successful lifecycle source states, covering all five source variants, 29 definitions (28 after deletion), header/Objective-C aliases, and ten seed/depth contracts. This audit compares source metadata only; it does not feed oracle answers into an observer.
- `run_portable_validation.py`: real Linux Clang `.m`/`.mm` and header lifecycle plus a separate real Swift same-physical-source/two-module and stale-unit regression. These portable workloads are explicit diagnostic subsets, never substitutes for iOS or Objective-C interoperability.
- `tests/`: 40 parser, identity, current-unit, compile-manifest, freshness, and scoring contracts. Initial red evidence is retained in `regression-first.txt`.

## Current-unit and identity rules

The adapter enumerates unit metadata, then starts only at outputs in the last successful compiler command manifest. Each root must uniquely match its output, main source, module, provider, target and selected SDK. Apple iOS deployment-version trailing zeroes are normalized without equating simulator and device targets. Every root needs its primary source record. Clang's recorded `.d` project headers must occur in that root's reachable Record/File dependencies. Dependency unit names must resolve; missing or ambiguous provenance fails closed.

Only records reachable through those roots are read. A compiler's retained orphan record files are never enumerated as graph input. Parsed record text is cached once per record name, while every parent unit, dependency module, effective unit module, source path and root-unit relationship remains separate. One physical Swift file compiled in FeatureAlpha and FeatureBeta therefore remains two source contexts. Old units and records stay in the physical input store.

Source identities are context, project-relative path, one-based line and UTF-8 column. Source declaration syntax provides definitions and header aliases. C-family aliases require a unique same-context full source signature; compiler identities must agree. An identity with multiple source definitions, or a source definition with multiple compiler identities, fails. Native Cartograph uses its own node location/module/USR data, without borrowing baseline USRs. Missing native module provenance fails.

The declaration scanner deliberately supports the fixture's one-line Swift functions/initializers, C/C++ free functions and Objective-C selector declarations/definitions. It is not a general language parser. Unrecognized in-universe callable definitions, missing source definitions, ambiguous aliases and unmapped in-universe endpoints remain explicit failures. Compiler-printed symbol roles never identify declaration occurrences; source anchors do. Only `calledBy` contributes baseline call edges. `receivedBy`, containment and receiver relations do not.

The default graph mode retains the existing native command and behavior. For a graph oracle containing recursive self calls, explicitly select `--cartograph-graph-mode include-self-loops`. This mode first retains raw/default-normalized graph evidence, then invokes `graph --format json --level symbol --include-self-loops`. The selected self-loop-preserving graph and the default graph have separate scores; the default diagnostic is never substituted for an unsupported compatible-mode binary. A rejected flag fails the observation. It adds one diagnostic native graph invocation, whose raw timing remains visible; this prototype makes no performance comparison from those invocations.

Native query commands never receive the graph flag. Reverse caller queries continue to exclude the seed, including on a recursive self edge; a graph self loop does not turn the seed into its own requested caller.

Full comparison mode scores both source call graphs and exact direct/transitive answers, including minimum depth. Extra known-source graph edges fail even if they are disconnected from all ten query seeds. Native batch answers are retained separately from native graph-derived answers. Missing native seeds are recorded explicitly rather than silently dropping a query.

## Input and capability rules

The existing successful native CLI build evidence must match the executable hash, official upstream URL, pinned revision `64aa0b26913249c4e7c21d351a215fba02702003`, and reviewed dependency revisions. Current tracked/untracked build inputs and dependency checkouts are checked read-only. No download, build, credential, or service is required by the hook.

Compiler setup library hash must match the explicit `--library` bytes supplied to native `index-dump`. Full native Cartograph mode additionally verifies its current Xcode library-selection path resolves to the same bytes. Source/store fingerprints are checked before and after each arm, including after an observation failure. Raw commands, stdout/stderr, unit metadata, binding decisions, normalized results and adapter hashes are preserved.

Source-only and failed-build states are never scored against the current source oracle. Their exact source hash deltas are checked against the last accepted compiler state; unbuilt states must retain identical store bytes. Native index-dump freshness and native caller commands are unsupported, with null precision/recall. The external hash gate is not attributed to native index-dump.

Native Cartograph stale warning attribution remains a separate gate. A generic warning count is insufficient: a diagnostic must identify an actually changed dependency. Current product header coverage and header warning behavior are unverified here and may fail this gate. The adapter does not manufacture header edges or infer a warning from external hashes.

XCTest units/records are identified separately but never enter the Sources-only compiler-caller score. Framework affected-test selection and XCTest runtime execution remain unimplemented/unscored, with native baseline unsupported.

## Verified execution

The preserved original verification is `portable-results-reviewed/results.json`. Current integration repairs are additionally verified in `portable-integration-legacy/results.json` and `portable-integration-nested/results.json`; both execute the same portable contracts with the actual pinned CLI:

- Eight actual Clang lifecycle states: initial, header-only unbuilt/edit rebuild, header rename unbuilt/rebuild, header delete unbuilt/expected failed build, and restoration rebuild.
- Four accepted Clang states each match nine source definitions and five independently authored call edges exactly.
- Both header branches move from CGBase to CGAlternate after the header edit; renamed header identities replace old paths; restoration returns byte-identical source inputs.
- A real compiler-emitted orphan unit is retained in the store and excluded by active output ownership in every accepted state.
- Actual Swift 6.4 compiles one physical Shared.swift as FeatureAlpha and FeatureBeta; the native CLI produces four distinct bound definitions and two context-separated call edges.
- A separate actual Swift source rename/delete regression keeps old units in the store while current definitions move 5 → 5 → 4. Old Legacy.swift/Relocated.swift units are excluded by active output manifest.

Earlier `portable-results-01` preserves an initial Swift module-cache failure caused by a read-only default cache directory. The runner now passes a writable explicit module-cache path. `portable-results-02` passed the smaller contract before adding the current-source rename/delete and compile dependency gates. The later portable-results-03 and portable-results-final runs also preserve intermediate verification. They are historical diagnostics, not final evidence for current code.

Not run: real iOS SDK compilation, Foundation Objective-C, Swift/Objective-C interoperability, native Cartograph graph/query execution, native header freshness, full thirteen-state product comparison, framework selection, XCTest runtime, or performance/holdout protocol.

## Run

From this directory:

    python3 -m unittest discover -s tests -v
    python3 verify_source_catalog.py --fixture-root /path/to/mixed-ios-validation --output /new/catalog-contracts.json

Portable Linux diagnostic (existing tools only):

    python3 run_portable_validation.py --output /new/portable-run \
      --fixture-root /path/to/mixed-ios-validation \
      --toolchain /path/to/existing-swift-toolchain \
      --index-dump /path/to/pinned/index-dump \
      --indexstore-checkout /path/to/pinned/indexstore-db \
      --cli-build-evidence /path/to/existing/results.json

For the macOS fixture runner, create a hook JSON argv array containing:

    ["python3", "/path/to/observe_mixed.py",
     "--fixture-root", "/path/to/mixed-ios-validation",
     "--index-dump", "/path/to/pinned/index-dump",
     "--indexstore-checkout", "/path/to/pinned/indexstore-db",
     "--cli-build-evidence", "/path/to/existing/results.json",
     "--library", "/selected/Xcode/toolchain/usr/lib/libIndexStore.dylib",
     "--cartograph", "/path/to/native/cartograph",
     "--cartograph-graph-mode", "include-self-loops"]

The explicit compatible mode in this example requires a Cartograph binary implementing `--include-self-loops`; omit the mode option to retain the existing default graph contract. There is no feature-detection fallback.

Then pass that file to `run_ios_validation.py --hook-json …`. The fixture runner adds `--state`. The hook creates each state directory's `observation/` folder and refuses to overwrite existing evidence. Full mode returns nonzero for missing/ambiguous identities, incorrect graph/query results, changed input bytes, mismatched library/tool provenance, or unproven native freshness.

Use `--baseline-only` only for an explicitly labeled baseline diagnostic; it cannot report `full_comparison: true`. `--no-score` is for portable contract checks whose authored subset is checked by `run_portable_validation.py`; it is never a full fixture comparison pass.

For the portable runner, `--setup-layout nested` exercises the integrated setup directory. Its default `--setup-layout legacy` preserves the original runner layout. No state-directory basename is special.

## Integration repair history

`history/20261012-before-integration-repairs/` preserves the prior implementation, README, HANDOFF, SHA256SUMS, and check evidence at their original hashes. All earlier portable evidence remains untouched. `integration-repair-regression-first.txt` records the nine new layout/mode contracts failing before implementation; `integration-repair-tests.txt` records all 39 current contracts. Self-loop flag/unsupported-binary/default-score tests use explicit native-protocol doubles; they are not claims of native Cartograph execution. Real native execution remains a macOS gate.

## Handoff / publication

Copy only source scripts, query specification, tests and this documentation for review/integration. Runtime Project/, Build/, IndexStore/, module caches and earlier diagnostic trees are local-only inputs. All retained raw evidence needs the parent's existing text-only evidence normalizer before publication; do not upload these directories wholesale. No CI workflow, repository branch, PR, or artifact publication was changed by this task.

## Repository integration

The parent fixture includes this adapter under `adapter/`. Diagnostic catalog serialization uses
`declaration_lexeme` instead of the internal `token` key; source binding and oracle bytes are unchanged.
Earlier local run paths above identify retained validation history, not committed binary evidence.
Use the repository-level `Scripts/verify-indexstore-mixed.py` and `Scripts/benchmark-indexstore-mixed.py`
entry points for the integrated checks. Public CI retains normalized text only.
