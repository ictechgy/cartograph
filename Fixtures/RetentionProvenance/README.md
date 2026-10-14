# Isthmus retention composition fixtures

These exact bytes were generated with Isthmus built CLI runtime commit `8061ed4e43b207044025dd723b0d3d7072f23218` (documentation successor `f8d823f07c7a59b95e9783640f4b6aed4b13813b`). The public synthetic `fixtures/bridge/dart.json` and `swift.json` retain their original `/fixture`, `s:handler` / `Handler.handle`, camera/photo and `lib/bridge.dart:4` identities. The receiver adds a source-changed warning; the zero case removes method-invoke facts. All actual CLI invocations exited 0 with empty stderr.

`unknown-version` is an explicit derived forward-compatibility control, not an output emitted by Isthmus: only the matched provenance version and opaque Unicode context are changed. Baseline, stale and unknown retain identical full retention/evidence arrays. Do not regenerate or rewrite roots to hide a consumer failure.

The tests use the real store, service, snapshot capture and public restore entry points with a synthetic indexed graph. They do not establish actual compiler-capture completeness or deletion safety. Full macOS integration remains required.

Exact SHA-256 bytes:

- `cartograph-baseline.json`: `d986ce168d8a97ca70c070ef5ed4f7b5b2c7ea84cde909ccd4c49cd4b0a54696`
- `cartograph-stale-matched.json`: `6169e543c0d04542c7b3b8fa3950d77309990a6e96c5273ded9002b3e10b8fb5`
- `cartograph-unknown-version.json`: `f04a630fbee8318eb49734aa1f0986d6854ac724b6f5d30fafc100837fc53759`
- `cartograph-zero-retentions.json`: `ef6065fc3b68bb4a6e540fc306b989436b88b610d88100b2b38bfccf674f3b59`

## Current producer handoff — 2026-10-14

The historical files above remain unchanged. The separate `cartograph-current-*.json`
files are original outputs of the newly built Isthmus CLI, captured from the committed
`current-input-*.json` synthetic inputs. Their local build commit was
`bdbdd589a8159b13d25dc23e11e1586bc0125ffb`; published PR #150 head
[`eb9f0d94c4dea02c3f60a2949273a094965650e8`](https://github.com/ictechgy/isthmus/commit/eb9f0d94c4dea02c3f60a2949273a094965650e8)
has the identical source tree `f6c67f495864395b7c75ecfe76b3d2f5628f5e5c`.
These are distinct commits, and the package version `0.13.1` is not a claim that
this producer feature has been released.

`current-producer-capture.json` records the source, built entry/retention hashes,
input/output hashes, actual zero child exits, empty-stderr hashes and process walls.
The six source pins and all 81 emitted JavaScript files and their inline source-map
contents were independently reconciled before this fixture handoff. No output or
root was rewritten to fit the consumer.

For each recorded case, the portable reproduction command is:

```sh
node <isthmus-checkout>/dist/cli/main.js retentions <dart-input> <swift-input> --for cartograph
```

Use the two input paths listed for the case. The baseline and stale cases preserve
identical roots and caller evidence; the zero case removes the authored invocation
and still carries both source headers and the stale warning. The native Swift tests
exercise the existing real store/service/query/explain and snapshot restore/rebase
paths with a synthetic indexed graph. They do not prove actual compiler capture
completeness, deletion safety, registry publication or Kartograph compatibility.
Reproduction creates a fresh conversion timestamp; keep these original captured
bytes and compare the preserved facts and source context rather than overwriting them.
