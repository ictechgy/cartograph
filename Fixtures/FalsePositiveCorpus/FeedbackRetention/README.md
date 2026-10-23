# Owner-conditioned synthesized-property retention

This separate SwiftPM corpus generalizes user feedback C-P1-3: an unconstructed
outer class containing an `Equatable` State stayed retained because State's
stored property was an unconditional retention root. No company source is used.
It is nested here so the existing corpus entry point and frozen expectations
remain independent; `Scripts/verify-retention-feedback.py` builds this package.

The entire unused-symbol list is fixed in `expected-unused.txt`. Dead nested
Equatable, Hashable, extension-conformance and plain owners sit alongside live
synthesized equality/hashing and a referenced nested type. The verifier runs the
executable, compares the exact list, and requires the paired pre-narrowing binary
to disagree on `NeverMadeStore` while still reporting `NeverMadePlain`.

Native execution is required. A source review or a passing synthetic corpus is
not a measurement on the reported workspace. The same verifier acquires the
three public revisions already documented in `docs/evaluation/2026-09-15-comparison.md`,
builds each once, and analyzes the same unchanged index with both binaries.
It writes full findings, limitations, preparation cost, source-name occurrences
and a pending review template. Each newly reported declaration requires manual
review before the narrowing gate passes. Zero new findings means that review set
is empty; missing projects or failed builds never count as zero findings.

The rule still preserves Equatable/Hashable stored properties when their owning
type is reached. Those properties do not independently retain an otherwise
unreachable owner or its ancestors. Codable and explicit retention reasons are
unchanged. The product README and Korean README must state this scope when the
owner integrates the change.

## CI integration

On the existing macOS runner with the repository's selected Xcode, after committing
the exact candidate, run the offline contracts and then the native gate:

```sh
python3 Scripts/verify-retention-feedback-contract.py
python3 Scripts/verify-retention-feedback.py --output "$RUNNER_TEMP/retention-feedback"
```

Allow about 45 minutes for a fresh paired Cartograph build and the three public
project builds. Each subprocess has a bounded timeout and 64 MiB output cap.
Upload `retention-feedback/results.json`, `summary.md`, `manual-review-template.json`
and `logs/` with `if: always()`; full source/index/build trees need not be uploaded.
The script must not share its output directory with another run. It copies the
committed source, builds a baseline that changes only the two reason flags, copies
that binary, and incrementally rebuilds the restored candidate in its isolated
scratch. The original checkout is never edited by this preparation.

Exit 3 means measurements completed but newly reported declarations still need
review; it must not be converted into a passed narrowing gate. Inspect every
new diagnostic and its source-name matches at the recorded revision. Fill the
template with a reviewer, `decision: "confirmed"`, and specific evidence. A false
positive must be fixed; merely signing its row is not acceptance. Review keys bind
the production source hashes, project revision, scope and exact diagnostic.

To check reviewed artifacts without rebuilding or downloading anything:

```sh
python3 Scripts/verify-retention-feedback.py --output path/to/artifact \
  --validate-only --review path/to/completed-review.json
```

A future full run can receive the same `--review` file only while its keys still
match. Stale or extra keys fail. A failed corpus/build or fewer than three distinct
pinned projects remains incomplete even when there are no new findings. The
existing full corpus, coverage, self-analysis and CLI gates remain required.
