# Scoped review, readable limits and preparation status

These are additive options in the unpublished 0.29.0 candidate. Existing full
reports and default analysis behavior remain unchanged. They do not prove that
tests may be omitted or declarations deleted.

## Review target membership

`affected --target-scope receipt.json` adds `targetScope` to JSON and a path review
to text. The opt-in producer captures `swift package describe`, explicitly builds
the package, and records a normal analysis snapshot:

```sh
python3 Scripts/cartograph-swiftpm-scope.py \
  --project /path/to/package --cartograph /path/to/cartograph \
  --test-target AppTests --output /path/outside/package/new-scope

cartograph affected changedValue --project /path/to/package \
  --index-store /path/from/new-scope/capture.json --format json \
  --target-scope /path/outside/package/new-scope/target-scope.json
```

Use the same `--config` in both commands when applicable. Only build packages you
trust to build. The producer retains commands, output, the snapshot and preparation
cost in a new directory. It requires one actual index with units; use its explicit
`--index-store` when build backends leave multiple candidates. Release archives
include the helper under `Scripts/`; Homebrew installs it under
`$(brew --prefix cartograph)/libexec/`. Publication and installation checks are
separate from source availability.

The consumer compares the exact snapshot input fingerprint and a bounded source
inventory, including Git-ignored and analysis-filtered files. New source files,
manifest/lock changes, unsupported targets, shared source owners, external package
dependencies, resources or a mismatched capture leave membership unknown. Limits
are 8 MiB per receipt, 1,000 targets, 10,000 source files, 4 MiB per source and
64 MiB combined source bytes. Symlinked or unreadable inventories are unsupported.

The selected test targets and their declared dependency closure classify paths as
`within-selected-targets`, `outside-selected-targets` or `unknown`. This is a
capture-bound producer claim, not signed build provenance or a current whole-package
completeness proof. Arbitrary resources and build environment are not established.
SwiftPM module names do not prove the chosen Xcode scheme's test-target identities.
All original coverage warnings remain. With this review requested, narrow
`xcodebuild` selectors remain refused with exit 2 and no arguments; callers must run
the whole suite. No suite is automatically executed.

## Keep findings and inspect file concentrations

```sh
cartograph dead --report-format json --file-summary
cartograph dead --report-format json --generated-suggestions
```

`findingReview` adds deterministic file counts, rule/severity counts and omitted-file
counts. All original diagnostics, summary, limitations and exit behavior remain.
`--generated-suggestions` also checks bounded leading comment headers. An observed
marker is a source assertion, not proof that a generator ran. Suggestions ask for
manual review of `retention.retained_files`; they never change configuration or
hide findings. Names such as `NeedleGenerated.swift` or `DesignTokens.swift` alone
produce no generated suggestion. The library API defaults to no header reads.

## Choose full or summarized limitations

```sh
cartograph query SomeType --limitations summary
cartograph affected SomeType --format json --limitations summary
cartograph serve --limitations summary
```

Full is the default and preserves the original bytes. Summary replaces each note
array with one line per exact code and adds `limitationSummary`: note count,
distinct-message count, up to three original examples per group, repetition count,
and omitted/truncated detail counts. Note count is not a source-file count.
Unknown codes remain separate. Status, freshness, selection issues, truncation and
error/exit facts are unchanged. Request full for original messages. Summary refuses
non-JSON reports, unsupported evidence/write formats, invalid shapes or exceeded
budgets; it never turns an unknown result into success. Bounds include 16 MiB input
and output, 128 groups per array, 512 bytes per example, depth 64 and 100,000 values.
Snapshots and exchange evidence always retain their original full contract.

## Prepare an MCP session without hiding a long first read

Call `cartograph_prepare` with `{"action":"start"}`, then poll with
`{"action":"status"}`. The tool immediately reports an observed lifecycle phase,
preparation generation, `workerActive`, deadline and cached session metadata. It
does not invent completion percentages. An explicit `refresh` starts a new
preparation and `timeoutSeconds` is bounded to 1...600 (default 300).

`{"action":"cancel","generation":1}` cancels publication of that generation's
result. Synchronous native reads cannot be forcibly interrupted: an expired or
cancelled request can still report `workerActive:true`, and no replacement worker
starts until it settles. Late results are discarded. Closing stdio also suppresses
late publication. Normal analysis requests preserve their existing freshness checks;
cached readiness is not a claim that current source inputs or coverage are complete.
The original `cartograph_status` and queries may still block during their own work.

Native regressions use synthetic packages and the frozen first-feedback commit
`fae3c24b1776af8d75151663821f8ff221d928f8`. They do not revalidate the reported private
22-project workspace or establish macOS 14 runtime compatibility.
