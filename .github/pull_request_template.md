## What and why

<!-- The diff says what changed. Say why it needed to change. -->

## Verification

- [ ] `Scripts/coverage.sh` passes (line coverage ≥ 90%)
- [ ] `Scripts/verify-cli-contract.sh` passes
- [ ] `Scripts/verify-fixtures.sh "$(swift build --show-bin-path)/cartograph"` passes with the current binary
- [ ] `swift build` passes, followed by all four self-analysis checks:
      `swift run cartograph dead --strict`, `swift run cartograph cycles --strict`,
      `swift run cartograph cycles --level type --strict`, and `swift run cartograph rules --strict`

<!-- Let the tool discover the index store. Recent Xcode build systems ignore a custom
     -index-store-path. Module cycles alone do not exercise type-level cycles. -->

<!-- If this changes a retention rule, say which realistic Swift pattern it covers
     and point at the test that fails without it. -->
