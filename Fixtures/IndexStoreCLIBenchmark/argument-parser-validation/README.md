# Pinned real-project validation

This workload asks which source-declared callables can call the constrained
`StringProtocol.editDistance(to:)` declaration in swift-argument-parser 1.8.2,
directly or within three/five caller hops. The source-authored answers contain
exactly 1, 4, and 10 callables. Repeated call sites, closures, recursion,
initializer calls, a diamond, and deprecated overloads are included.

This is **validation only, not the final holdout**. Neither the project nor its
source-static workflow replaces the final multi-target/mixed-language,
edit/refresh/restoration protocol. No superiority conclusion is emitted.

## Source provenance and frozen contract

- Project: <https://github.com/apple/swift-argument-parser>
- Revision: `6a52f3251125d74daf04fcbd5e6f08a75d074382` (tag `1.8.2`)
- Build: `ArgumentParser`, including local `ArgumentParserToolInfo`; 53 Swift files
- License: Apache-2.0 WITH Swift-exception; full text in the upstream `LICENSE.txt`
- [DESIGN.md](DESIGN.md) documents the source-only audit, source scope, exact
  answer semantics, and the final-holdout limitations
- [oracle.json](oracle.json) contains the independently authored 13 edges,
  17 syntactic call sites, expected minimum depths, and explicit negatives
- [source-manifest.json](source-manifest.json) pins all build-source bytes
- [SHA256SUMS](SHA256SUMS) preserves the original frozen evidence hashes
- [runner-protocol.json](runner-protocol.json) declares execution and measurement
  choices. Its hash and both adapter hashes are snapshotted before observation

No comparison-tool output was used to write the original oracle. The runner
verifies its fixed hashes, source bytes, declaration anchors, and call-site text
before it builds the public project. Oracle files are never generated or updated
from tool outputs. A compiler representation the adapters cannot resolve fails
with raw evidence for human review.

## Run

First create successful raw setup evidence with the synthetic harness, including
a real pinned `index-dump` build and (on macOS) the desired Cartograph binary:

```sh
python3 Scripts/benchmark-indexstore-cli.py \
  --cartograph-package "$PWD" --output /tmp/cartograph-cli-setup
python3 Scripts/benchmark-indexstore-project.py \
  --setup-results /tmp/cartograph-cli-setup/results.json \
  --output /tmp/cartograph-project-validation --repetitions 4 \
  --cartograph-graph-mode include-self-loops
```

Use an absent or empty output directory. The runner reuses the exact recorded
binary and `libIndexStore` hashes and compiler version; it does not build a proxy
comparator. It clones the pinned public project into a new standalone checkout,
builds a fresh scratch directory with index emission enabled, and requires one
actual populated index store. Both arms read that same immutable physical store.

For an offline Git source mirror, add `--project-source /path/to/local/checkout`.
That path is cloned into the output directory; its existing build/index is never
analyzed. The resulting clone must have the exact pinned revision and source tree.

On Linux, only the comparator diagnostic is supported:

```sh
python3 Scripts/benchmark-indexstore-project.py \
  --baseline-only --setup-results /tmp/baseline-setup/results.json \
  --output /tmp/public-project-baseline --repetitions 2
```

The setup evidence must itself come from a successful base-harness diagnostic.
A successful diagnostic reports `baseline_only`, never `passed`. It cannot prove
Cartograph correctness or a product speed comparison.

Run the offline regression tests without either product or Swift:

```sh
python3 Scripts/verify-indexstore-project.py
```

## Interpretation and evidence

Each arm resolves its own compiler identities from source locations. It does not
borrow the other arm's USRs. All in-scope source callers remain eligible for
false-positive scoring, including callables absent from the expected answer.
Exact source-ID sets, minimum depths, explicit negative controls, and the 13
fully audited incoming edges are checked. Missing, ambiguous, malformed,
truncated, unexpected, and unmapped reachable answers fail closed.

The combined timed user task needs one depth-5 minimum-distance response;
depth-1/3 subsets are derived from it. Separate native depth-1/3/5 commands check
the CLI boundary contract outside that combined-workload timing.

The baseline reuses the graph assembled from actual upstream `index-dump` unit
and record output, reading its persisted graph and performing one BFS in each
new Python process. Cartograph uses one real native CLI query process per
combined workload. These are **different state regimes**, with native ingestion
included in Cartograph's process time. These descriptive numbers are not a fair
final persistent-session comparison. The final 10-query protocol must give each
arm equivalent reuse opportunities, including available native/MCP session reuse.

Discovery/assembly, tool setup provenance, and the fresh project compilation are
reported separately. Both the first observed query after discovery and balanced
AB/BA repeated process measurements are retained. No cache flush is claimed.
Every process records its command, stdout/stderr, timeout, wall time, and OS
`wait4` RSS. RSS is not simultaneous aggregate process-tree memory; peaks are
never summed. No raw-byte-to-token or latency conversion is asserted.

The output directory preserves the frozen source evidence and executing adapter
copies, `setup/preregistration.json`, reused setup evidence, all raw native output,
source/index manifests, independent normalized graphs, exact grades, first and
repeated measurements, and `results.json`. Failed runs are evidence too: keep
them and review the compiler/source discrepancy without changing expected answers
to agree with a product.
