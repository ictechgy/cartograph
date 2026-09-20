# Action, corpus and cache follow-up

Date: 2026-09-21. Development branch: `feature/action-corpus-cache`.
Changes here are not included in the published 0.20.0 action or binary.

## Local verification

- 1,650 Swift tests passed; `Scripts/coverage.sh` passed at 92.84% (32,216/34,701 production lines),
  with the unit-test-only measurement reported separately at 87.50%.
- CLI exit-code contracts, the complete compiler corpus, and strict dead/module-cycle/type-cycle/
  architecture-rule self-analysis passed. Dead-code analysis retains one pre-existing non-gating
  unused-import warning in `ReactNativeEventScanner.swift`.
- Action and cache Python harnesses, shell/Python syntax, YAML parsing and local Markdown links passed.
- Mutations of the original action, public golden and shared reader lock each failed their intended checks.
- Local raw logs are preserved under `.git/evidence-action-corpus-cache-20260921/`.

## Action publication and upload

The publication candidate is the existing Cartograph action: name `Cartograph Swift Analysis`, author `ictechgy`,
search icon, blue branding, and the description in [action.yml](../action.yml). The existing
`0.20.0` release contains the action manifest. Do not move that tag to include these fixes.
The [official publication rules](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-github-marketplace)
prohibit an action name matching another GitHub account. The existing `Cartograph` name conflicts
with the `cartograph` organization, so the development manifest uses `Cartograph Swift Analysis`.
The candidate Marketplace URL returned 404. The signed-in release editor shows that the
GitHub Marketplace Developer Agreement has not been accepted. Public listing is not yet complete;
a new immutable action release is needed for the renamed manifest and fixes.

The [integration workflow](../.github/workflows/action-sarif.yml) builds the real compiler corpus,
downloads the pinned 0.20.0 binary and runs the checked-out composite action with SARIF upload
enabled. Its report must contain actual findings. On GitHub, record the workflow run/head,
upload step completion and matching code-scanning analysis (tool, category, commit and result
count); a generated file or successful artifact upload alone is not code-scanning acceptance.
The user authorized GitHub status queries, branch upload and the live run on 2026-09-21.
The upload action now exposes `sarif-id`; the integration job verifies server processing,
commit/category/tool identity and the accepted result count using that receipt.

Local `python3 Scripts/verify-action.py` executes the actual gate/result scripts for success,
strict findings, report-only findings, tool failure, usage error, missing executable, a report
written on failure, missing output and an unsupported command. It caught the original action
accepting unexpected exit codes and advertising a stale report. The original action fails this
harness. The new action discards stale output, does not upload failed invocations, and rejects
unexpected codes or missing reports. Project-relative SARIF locations are converted to absolute
file URIs before upload, so nested projects map back to their checkout paths. The integration job
checks the saved alert paths as well as result counts. README examples use the supported `args`
input for `--since`.

## Compiler corpus and skill

`Scripts/verify-corpus-commands.py` compares complete JSON documents after replacing only the
absolute project root. The existing fixture produces seven `redundant-public` diagnostics and
three mechanical parameter-name edits. Fix dry runs preserve source hashes. Three affected
goldens cover a test consumer, a directly selected test at depth zero and an empty test result;
excluding tests must expose the configured-path-filter limitation. Removing the public expected
list makes the harness fail. The original corpus sources were not changed.

The skill template and generated copy explain these workflows without treating reachability,
parsing or an empty test list as permission to delete code or skip verification. The existing
frontmatter and template-drift tests validate the installed content. The optional skill-creator
Python validator could not run because PyYAML is absent from both the interpreter and offline
package cache; Ruby's YAML parser also validated the frontmatter. No dependency was fetched.
Local handoff notices were added to kartograph and
dartograph; their product code and skill templates were not changed.

## Reader cache lifetime

Run from a checkout:

```bash
python3 Scripts/manage-index-cache.py
python3 Scripts/manage-index-cache.py --max-age-days 30 --max-bytes 2147483648
# After reviewing the selected entries and stopping older Cartograph processes:
python3 Scripts/manage-index-cache.py --max-age-days 30 --max-bytes 2147483648 --apply
```

The default is a preview. Age is based on a successful-open marker and newer database files,
not the enclosing directory's creation time. The byte budget uses allocated disk bytes, keeps
the most recently used entries, and gives newly used entries five minutes of grace. It is a
soft budget: unmarked/unknown entries are preserved and excluded. Symlinks and unexpected cache
contents are preserved. No automatic cleanup is added to ordinary analysis commands.

The live local index provider holds a shared lock through database use; maintenance requires an
exclusive nonblocking lock and exits 2 if a reader is active. The persistent lock file must not
be deleted. Older binaries do not participate in this protocol, so stop them before applying
maintenance. Injected custom filesystems remain responsible for their own lifecycle. Unmarked
legacy caches require separate review; this script does not claim ownership of them.

`python3 Scripts/verify-index-cache.py` tests preview/apply, age, budget, grace, unknown content,
symlinks and active readers using only temporary directories. Swift tests check shared-lock
exclusion, release and lock-symlink rejection. Replacing shared locking with unlock causes those
tests to fail. The user's existing cache was inventoried, not pruned.

## Bridge memory baseline

```bash
swift build
python3 Scripts/benchmark-bridge-memory.py --build-directory .build/debug \
  --project . --project Fixtures/FalsePositiveCorpus --output /tmp/bridge-memory.json
```

The standalone probe links the built CartographKit library and observes actual source reads.
It preserves the original `sourceCache` and both analysis passes. Sources and fact documents are
not emitted; only counts, sizes, timings and a document digest are recorded. The source byte sum
excludes String/Dictionary overhead. Peak RSS covers the entire instrumented process, including
IndexStoreDB and SwiftSyntax, and does not isolate the cache's allocation cost.

Three debug-library samples on macOS, [raw results](evidence/bridge-memory-20260921.json):

| Input | Source files | UTF-8 payload bytes | Peak RSS bytes (min–max) | Facts |
|---|---:|---:|---:|---:|
| cartograph | 189 | 2,083,941 | 164,790,272–209,158,144 | 0 |
| FalsePositiveCorpus | 17 | 20,446 | 26,378,240–26,476,544 | 10 |

Every source was read once per run, and each project's normalized fact digest was identical
across all three runs. The first run can populate disk caches. These are baselines, not an
optimization comparison or a proof about larger applications. Removing the source snapshot
would risk the second pass observing different source bytes; no such change was made.
