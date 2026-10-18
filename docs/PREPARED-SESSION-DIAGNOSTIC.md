# Prepared-session diagnostic

`Scripts/benchmark-prepared-indexstore-sessions.py --project-results <raw-project-results.json>`
consumes a successful existing `benchmark-indexstore-project.py` run. It does not build,
edit, or replace that benchmark. Results and raw evidence live under that run's
`runs/prepared-sessions`, within the existing normalized ArgumentParser evidence bundle.

Both processes operate on the same frozen ArgumentParser sources and compiler index:

- The persistent Python baseline runs the pinned real `index-dump` discovery and source-identity
  graph assembly, then retains that graph and its reverse adjacency in memory. Adjacency is rebuilt
  only when discovery creates a new generation. After full shared byte admission, every tool
  request enumerates and stats the current source/config/index inputs and refuses drift.
- Native `cartograph serve --session-freshness-interval 0` retains its analysis session while
  preserving actual per-request freshness checks and its richer evidence and limitations output.

The shared client clocks start immediately before writing each IPC request and stop after
parsing and checking its complete structured response. Oracle grading and evidence-file writes
are outside query clocks. Baseline traversal is never compared directly with native IPC latency.
The native query limit is 1000 (the MCP shared budget); all existing nontruncation, source-oracle,
minimum-depth and negative-control checks still apply, and any truncation fails the diagnostic.

Phases are spawn through graph-ready status; first query; four fixed warm pairs in
AB/BA/AB/BA order; and one forced same-input invalidation, completed rediscovery/refresh,
and first refreshed answer. The baseline repeats real index-dump discovery on refresh. Native
status refresh resets its analysis session. This is not a source-edit/rebuild experiment.
Generation checks require reuse for unchanged queries and exactly one increment on refresh.

`totals` sums per-arm preparation, first query, four warm queries, completed refresh and first
refreshed answer. `totals_including_common_verification_seconds` additionally includes the
shared initial admission, all common byte checks and graph-oracle checks, charged equally to each arm for accounting;
it is not a simultaneous wall-clock measurement. `diagnostic_elapsed_seconds` is the actual
whole-driver duration including both arms, logging and cleanup. Prior tool builds, project
compilation and native identity discovery are reused; their costs remain in the original results.
Full source/index/config byte checks surround preparation, every query pair and the refresh pair; their common cost
is reported separately. The controller grades the actual saved baseline graph after each ready/refresh response,
while the corresponding arm timer is stopped. An invalid graph still fails before a query is accepted.
The separately retained graph-check durations enter the shared inclusive total for both arms, not either IPC timer.
Actual discovery, graph serialization, metadata checks and traversal remain measured.
A shared nine-minute deadline bounds requests and is rechecked after final byte verification,
leaving cleanup time below the ten-minute CI step cap.
SIGTERM enters bounded cleanup, and a cleanup error in one arm does not skip the other.
Successful runs require normal zero process exits. Raw commands,
requests, complete replies, stderr and actual index-dump invocation records are retained.

This is a small prepared-session diagnostic, not a fresh-CLI replacement, cold-cache claim,
generic graph-engine speed comparison, or product-superiority result. No per-query cumulative
process RSS is presented as a query allocation measurement. Python-only contract tests exercise
framing, response limits, deadlines, evidence preservation, unchanged-input reuse, refusal of drift,
real-discovery refresh dispatch and total accounting; real macOS CI supplies execution evidence.
