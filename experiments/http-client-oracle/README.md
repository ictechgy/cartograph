# HTTP client oracle

A synthetic app client that makes 35 requests through Foundation, URLComponents, Alamofire 5.12.2 and
Moya 15.0.3, and the request lines a local server actually received. It is the evidence behind the
library rules of `cartograph routes`: what `appendingPathComponent` does with `?`, `#`, `%` and leading
slashes, what Moya's `URL(target:)` sends for an empty or `?`-bearing `path`, and which verb each
Alamofire call uses by default.

- `Sources/OracleClient` is the app code. Every request carries an `oracle:` comment on the line where
  its `route-call` fact lives (the call expression, or the router's `path` arm); `id@case` picks one of
  several facts on a line by enum case.
- `record.sh` builds the runner, starts `recorder.py` on an ephemeral 127.0.0.1 port, runs every case
  through it as an HTTP proxy (the client keeps its literal host), and writes `recorded.json`. It needs
  network access for SwiftPM, so CI does not run it. The server exits when the runner finishes.
- `Tests/CartographSyntaxTests/HTTPClientOracleTests.swift` replays `recorded.json` against the facts
  scanned from `Sources/OracleClient` on every test run, offline: each template, with `{}` standing for
  one non-empty segment, must match the recorded path, and the verb must match.
- `compare.py` does the same comparison on real `cartograph routes` output (with index USRs) and prints
  an agreement table:

```bash
(cd experiments/http-client-oracle && swift build)
cartograph routes --project experiments/http-client-oracle > routes.json
python3 experiments/http-client-oracle/compare.py routes.json
```

The recording was made on macOS 26.7 (25G229) with Swift 6.4. Foundation's URL encoding changed across
OS releases before; re-record on a new OS before trusting a rule that depends on it.
