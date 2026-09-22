# Cartograph CI for GitLab

Run [Cartograph](https://github.com/ictechgy/cartograph) on a macOS runner to analyze Swift compiler
indexes for unused code, dependency cycles and architecture rule violations. This component
publishes GitLab Code Quality findings and preserves the complete native report with analysis limitations.

## Component: `cartograph`

The component and CLI are versioned separately. The example below pins the component to `1.0.0`;
its default CLI binary is the existing Cartograph `0.20.0` release.

```yaml
include:
  - component: gitlab.com/ictechgy/cartograph-ci/cartograph@1.0.0
    inputs:
      runner-tags: [macos]
      command: check
      project: .
```

The default job belongs to the `test` stage. You can choose its stage and job name using inputs.
Input descriptions and defaults are defined in [the component](templates/cartograph.yml).
The template is self-contained: including it does not require cloning the component repository
or downloading helper scripts into the consumer's checkout.

### Runner and build requirements

- macOS 14+, a compatible Xcode/Swift toolchain and Python 3.9+.
- A runner whose tags match `runner-tags`. The `macos` tag is a convention, not a runner this
  component provisions. An existing self-managed Mac can be registered as a GitLab runner.
- The binary download needs public HTTPS access to GitHub release assets. No GitHub token is required.
  Downloads are checked against the declared SHA-256 before the executable is extracted.
- `build: swift` runs `swift build` in `project`. For Xcode or custom builds, use `build: none`
  and build the index in the same job's `before_script`, or restore a compatible index first.

GitLab-hosted macOS runners have their own eligibility, runner tags and images. See
[GitLab's macOS runner documentation](https://docs.gitlab.com/ci/runners/hosted_runners/macos/).
Choose a toolchain compatible with your application and Cartograph; a Linux runner cannot execute this binary.

### Existing builds and additional arguments

```yaml
include:
  - component: gitlab.com/ictechgy/cartograph-ci/cartograph@1.0.0
    inputs:
      job-name: swift-architecture
      runner-tags: [macos]
      project: ios
      build: none
      command: check
      args: '--retain-public --limit 500'
      fail-on-findings: false

swift-architecture:
  before_script:
    - xcodebuild build -project ios/App.xcodeproj -scheme App -derivedDataPath ios/DerivedData
```

`args` uses shell-like quoting to split words, but never evaluates a shell. Dollar signs are
literal; interpolate dynamic values in your own job configuration if needed. The component owns
`--project`, `--report-format`, `--output`, `--strict` and `--quiet`; use inputs for their supported settings.
An existing executable can be supplied with `binary`. To download a different CLI release,
change both `version` and its matching archive `sha256`.

### Findings, failures and reports

By default, CLI findings fail the job with exit code 1. `fail-on-findings: false` permits findings
while retaining the reports. Tool errors, usage errors, failed builds, missing/invalid reports,
checksum mismatches and paths outside the checkout always fail the component with exit code 2.
Old reports are removed before execution so a failed invocation cannot upload stale findings.

The job publishes:

- `gl-code-quality-report.json`: located diagnostics in GitLab's Code Quality format.
- `cartograph-report.json`: the original JSON document, including analysis limitations and diagnostics without locations.
- `cartograph-status.json`: the CLI exit code and, after successful conversion, diagnostic counts.

GitLab severity is `info` for CLI information, `minor` for warnings and `major` for errors.
Fingerprints use the rule, repository-relative file and stable diagnostic subject (message when
there is no subject), so moving a declaration down a few lines does not create a new identity.
Nested project paths are rebased to the checkout root. A diagnostic without a source location
remains in the raw report and affects the gate, but is not assigned a fabricated Code Quality location.

Findings describe compiler graph evidence, not permission to delete declarations. The default
`retain_public` is false; libraries with external callers commonly need `--retain-public`.
Review the native report's actual limitations, dynamic/runtime consumers and relevant tests before editing.

Code Quality comparisons need reports from both the target branch and the merge request pipeline.
The available report views depend on the GitLab tier; see
[Code Quality](https://docs.gitlab.com/ci/testing/code_quality/).

## Contribute and validate

Run the real template payload's behavioral tests with Python's standard library:

```sh
python3 -m unittest discover -s tests -v
```

The project pipeline includes this exact component at `$CI_COMMIT_SHA`, compiles the tracked Swift
fixture on a project runner tagged `cartograph-ci-macos`, uploads findings and verifies the reports.
Maintainers can override `CARTOGRAPH_CI_RUNNER_TAG` for an eligible runner. When using GitLab-hosted
macOS, also set a compatible `image` on the `cartograph-corpus` job. Shell runners use their installed toolchain.
It also runs the behavioral tests on Linux. A release cannot skip the macOS integration job.
Configure an eligible runner before creating a version tag; no runner is installed or registered by this project.

To exercise the full upstream compiler corpus locally on a Mac:

```sh
python3 tests/verify_live.py \
  --corpus /path/to/cartograph/Fixtures/FalsePositiveCorpus \
  --output /tmp/cartograph-gitlab-evidence
```

This downloads the pinned binary and checks all converted diagnostics, real source paths, and
the upstream corpus's complete unused-symbol golden. `--binary /path/to/cartograph` uses an
existing executable instead.

For Catalog publication, set a public project description, enable **CI/CD Catalog project** in
the project settings, then create a semantic version tag after validation. The pipeline's
`release:` job publishes the Catalog release; creating a release only through the REST API is insufficient.
See [GitLab component publication](https://docs.gitlab.com/ci/components/#publish-a-component-project).

MIT licensed. The analyzer remains maintained in the upstream Cartograph repository.
