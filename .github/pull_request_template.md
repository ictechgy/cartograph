## What and why

<!-- The diff says what changed. Say why it needed to change. -->

## Verification

- [ ] `Scripts/coverage.sh` passes (line coverage ≥ 90%)
- [ ] Self-analysis passes:
      `swift build -Xswiftc -index-store-path -Xswiftc .index-store` then
      `cartograph dead|cycles|rules --index-store .index-store --strict`

<!-- If this changes a retention rule, say which realistic Swift pattern it covers
     and point at the test that fails without it. -->
