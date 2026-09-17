# Harder-task comparison — 2026-09-16

The 2026-09-15 pilot measured six "find the consumers" tasks and found no advantage
for Cartograph on that class of question. This follow-up measures the task classes
the pilot did not touch — bridge handler evidence, transitive dispatch, snapshot
diffs, local-function granularity — against the same arms (Cartograph 0.15.1,
SourceKit-LSP, source search; Periphery 3.8.0 does not implement any of these
queries, so it appears only in the dead-code control).

Everything below is mechanical: `Scripts/benchmark-harder-tasks.py` runs each arm,
times it, saves complete raw output, and grades against a frozen oracle. Raw output
and the scratch corpus live in `~/Desktop/cartograph-evaluation-20260916/`; the
`pigeon-host` fixture is vendored in `docs/evaluation/2026-09-16-harder/pigeon-host/`
so the suite reproduces without the external workspace.

## Corpus and setup

| Subject | Source | Index |
|---|---|---|
| Alamofire `bda9ed5` | pinned checkout, tracked sources untouched | `.build/out` from the 09-15 run |
| Kingfisher `ab1c1de` | same | same |
| argument-parser `93c6888` | same | same |
| `ap-edit` | scratch copy of argument-parser with three call-site edits | rebuilt in place |
| `pigeon-host` | vendored fixture: FlutterBasicMessageChannel stubs + Pigeon-style `CameraApiSetup` + two resolved handlers + one unresolved receiver | `swift build` |

The `ap-edit` change removes both `valueCompletion(arg)` call sites (leaving the
declaration orphaned) and the single `.bashCompletionScript` consumer in
`CompletionsGenerator.swift`. It compiles; `git diff HEAD` reports exactly those
two files plus the captured `before.json`.

## Results

### H1 — bounded per-message callees on a Flutter channel

> "Dart calls `takePhoto` on `dev.flutter.pigeon.host.CameraApi` — which Swift
> declarations execute per message?"

| Arm | Answer | Time |
|---|---|---|
| `bridges --messages` | Exact gold: `{takePhoto(completion:), audit(_:)}` handler-scope deps; dynamic channel preserved with `dynamic-message-channel-names` limitation | 42 ms |
| SourceKit-LSP `callHierarchy` on `setUp` | Registration callers only; cannot bound a handler scope | 290 ms |
| `grep CameraApi.takePhoto` | 1 site (the string literal) | 3 ms |

Only Cartograph produces the bounded set. LSP can locate the closure by hand, but
no LSP request returns "what this handler calls"; the channel name is a string
literal no symbol query resolves.

### H2 — transitive dispatch fan-out

> "Which concrete implementations execute through `Request.task(for:using:)`?"

Gold: 4 direct overrides (`DataRequest:119`, `DownloadRequest:205`,
`DataStreamRequest:146`, `WebSocketRequest:171`) + 1 transitive
(`UploadRequest:110` via `DataRequest`).

| Arm | Direct | Transitive | Time |
|---|---|---|---|
| `query <usr> --depth 3` (`overrides` edges) | 4/4 exact | `UploadRequest` at depth 2 | 449 ms |
| LSP `textDocument/implementation` | 4/4 | **missed** — flat set, no `UploadRequest` | 333 ms |
| `grep "override func task(for request"` | 5/5 sites | indistinguishable without reading | 9 ms |

SourceKit-LSP's implementation request returned the four direct overrides and not
the transitive one — the index records each override's immediate `overrideOf`, and
the request does not recurse. Cartograph's typed `overrides` edge traverses it in
one query.

### H3 — change-impact blast radius

> "These two uncommitted files changed — what declarations/files are affected?"

| Arm | Answer | Time |
|---|---|---|
| `impact --since HEAD` | 82 affected symbols, 13 files, `changeScope` 47 decls | 556 ms |
| `git diff --name-only` | 2 file names; no declaration-level data | <1 ms (raw) |

### H4 — snapshot diff ("what did my edit remove?")

`cartograph snapshot` on the unedited index → edits → rebuild → compare.

| Arm | Answer | Time |
|---|---|---|
| `impact valueCompletion(_:) --before` | before: 17 reachable consumers → current: 0 — the orphan is detected | 563 ms |
| `dead` on the edited tree | flags `valueCompletion(_:)` never used; pristine-repo control flags nothing | 121 ms |
| `impact --since HEAD --before` (file-seeded) | affected sets identical (82 = 82) | 988 ms |

Honest limitation found here: a file-seeded `--before` diff does **not** surface
edges removed *between* two changed files — both endpoints sit in `changeScope`,
not `affected`. The symbol-seeded form and `dead` carry the finding. If this edge
case matters, the comparison should also diff the change-scope subgraphs.

### H5 — local-function granularity (the pilot's one miss)

> "Who calls the local function `failCurrentSource` inside `retrieveImage`?"

| Arm | Answer | Time |
|---|---|---|
| `query failCurrentSource` | Exact: owner `handler(currentSource:retryContext:result:)`, evidence lines {421, 425}, `cartograph:local-function:` id | 382 ms |
| LSP `textDocument/references` at the decl | **0 results** — hover resolves the decl, but local functions carry no USR, so the references query has nothing to look up | 291 ms |
| `grep failCurrentSource` | 3 hits (decl + 2 calls); ownership needs reading | 18 ms |

The pilot's 13/14 exact-local score becomes 14/14 on 0.15.1, and this is a
structural LSP gap, not a tuning one.

### H6 — dead-code regression on 0.15.1

`dead --retain-public` never-used warnings vs the 09-15 improvements baseline:

| Project | Expected | Observed |
|---|---:|---:|
| Alamofire | 21 | 21 |
| Kingfisher | 8 | 8 |
| Argument Parser | 40 | 40 |

No regression.

### Latency — the counterweight

Five samples each on the `af-clock` target, Alamofire:

| Arm | Median |
|---|---:|
| SourceKit-LSP `callHierarchy/incomingCalls` (warm) | **1.1 ms** |
| `grep` | 5 ms |
| Cartograph MCP `cartograph_query` (warm) | 43 ms |
| Cartograph CLI `query` (cold process) | 315 ms |

The warm-MCP figure already includes the query-session cache added in 0.14.0.
The remaining gap is per-request work: every query rebuilds the reachability
report and evidence index even when the caller only wants direct consumers.
A bounded direct-consumer path is the open item.

## Verdict

On the task classes the pilot skipped, the ranking inverts: Cartograph is the
only arm that answers H1 and H4 mechanically at all, and it wins H2 (transitive
override) and H5 (local functions) where SourceKit-LSP has structural gaps.
The price is latency — LSP stays ~40× faster on the warm path — which is the
P1 work item this measurement justifies.
