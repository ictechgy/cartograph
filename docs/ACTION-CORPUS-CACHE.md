# Action, corpus and cache follow-up

Date: 2026-09-21. Publication status checked: 2026-09-22. Development branch: `feature/action-corpus-cache`.
The action changes are published as `action-v1.0.0`. Changes here are not included in the
published 0.20.0 action or binary. The cache lifetime and installed skill updates are included
in CLI 0.21.0; the measurements below retain their original revisions and dates.

[CLI 0.21.0](https://github.com/ictechgy/cartograph/releases/tag/0.21.0) was published from `ba9af2f`
after [PR #133](https://github.com/ictechgy/cartograph/pull/133) passed 1,650 tests, 92.83% combined
coverage (87.50% unit-only), compiler corpus, CLI contracts and strict self-analysis.
The [release workflow](https://github.com/ictechgy/cartograph/actions/runs/35777799863) verified the
packaged universal binary before publishing. An independent download matched GitHub's asset digest:
`4b204d2e343281499163df8def35374956d38b813d589519130f1f53244b623f`.
Both architecture slices, version output, bundled documents and CLI contracts passed verification.
[Homebrew PR #50](https://github.com/ictechgy/homebrew-tap/pull/50) updated the formula; host upgrade
and `brew test` passed, and the installed binary matched the downloaded binary byte for byte.
The GitLab Catalog 1.0.0 component remains pinned to its separately verified CLI 0.20.0.

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

The published Cartograph action has name `Cartograph Swift Analysis`, author `ictechgy`,
search icon, blue branding, and the description in [action.yml](../action.yml). The existing
`0.20.0` release contains the action manifest. Do not move that tag to include these fixes.
The [official publication rules](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-github-marketplace)
prohibit an action name matching another GitHub account. The existing `Cartograph` name conflicts
with the `cartograph` organization, so the published manifest uses `Cartograph Swift Analysis`.
The [action-only release](https://github.com/ictechgy/cartograph/releases/tag/action-v1.0.0)
was published on 2026-09-21 at `567d91fb0d4e99866c6f52c8650792baf13b71c7` (release ID `392487216`).
The [published-tag run](https://github.com/ictechgy/cartograph/actions/runs/35547841097) downloaded
that action and GitHub accepted 37 results across 5 rules, without processing errors or warnings.
On 2026-09-22, the release API confirmed the action is public and the latest binary is still 0.20.0.
Marketplace registration completed on 2026-09-22 after the user completed GitHub's account
reauthentication in Chrome. The default branch's name collision and overlong description were
fixed by [PR #131](https://github.com/ictechgy/cartograph/pull/131), merged as
`76219c0900d886dc8f5383cdfd34f3e2a9b77c6f`. It changes the action name and description (117 characters),
plus the existing manifest test's name expectation; runtime metadata is unchanged.
[CI](https://github.com/ictechgy/cartograph/actions/runs/35635573987) passed all 1,647 tests,
the coverage gate at 92.84% and self-analysis. The public listing has the expected name and
`Code quality` category; its [action-v1.0.0 version](https://github.com/marketplace/actions/cartograph-swift-analysis?version=action-v1.0.0)
offers `uses: ictechgy/cartograph@action-v1.0.0`. Both listing URLs returned HTTP 200 without authentication.
The default Marketplace "Use latest version" instead follows the repository's latest release,
`0.20.0`, and labels the explicit action version as older. Use the version-specific link;
the CLI latest release and existing action tag were intentionally preserved.
Public-page captures and comparison evidence are in `.git/evidence-marketplace-20260922/status.json`
and the adjacent HTML files.

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

The [live integration run](https://github.com/ictechgy/cartograph/actions/runs/35521323934) passed.
GitHub accepted analysis `1807230986`, SARIF receipt `7b66d6c4-b50c-11f1-81f9-3c7b574f4584`,
at commit `a0c5206a58ed5fa367ca58e1fb121e9572695702`, category/tool `cartograph`: 37 results,
5 rules, processing `complete`, empty error and warning fields. All 12 distinct saved alert paths
resolve under `Fixtures/FalsePositiveCorpus/` to existing files. The artifact receipt was downloaded
and the analysis API was independently reread; [machine-readable evidence](evidence/sarif-acceptance-20260921.json).
[PR #130](https://github.com/ictechgy/cartograph/pull/130) contains the implementation.

## Compiler corpus and skill

`Scripts/verify-corpus-commands.py` compares complete JSON documents after replacing the
absolute project root. The raw affected-symbol count is independently checked against the full
impact list; only compiler-marked implicit nodes at the fixture’s exact `@Test` expansion site
are separated from that golden count, since Swift 6.3/6.4 generate different helper counts. The existing fixture produces seven `redundant-public` diagnostics and
three mechanical parameter-name edits. Fix dry runs preserve source hashes. Three affected
goldens cover a test consumer, a directly selected test at depth zero and an empty test result;
excluding tests must expose the configured-path-filter limitation. Removing the public expected
list makes the harness fail. The original corpus sources were not changed.

The skill template and generated copy explain these workflows without treating reachability,
parsing or an empty test list as permission to delete code or skip verification. The existing
frontmatter and template-drift tests validate the installed content. The optional skill-creator
Python validator could not run because PyYAML is absent from both the interpreter and offline
package cache; Ruby's YAML parser also validated the frontmatter. No dependency was fetched.
Local handoff notices were added to kartograph and dartograph; their product code and skill templates were not changed.

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
