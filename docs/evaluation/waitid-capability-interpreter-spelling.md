# Prospective waitid capability interpreter spelling

This source change separates three exact roles:

- The configured workflow launch command remains
  `/opt/homebrew/opt/python@3.14/bin/python3.14`.
- The prospective runtime `sys.executable`, capability-child argv, and actor argv
  must be `/opt/homebrew/Cellar/python@3.14/3.14.7/bin/python3.14`.
- Both aliases must reach
  `/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14`,
  still exactly 34640 bytes with SHA-256
  `87d4df53fd91304be5bac391fb204643c36b7df2023c04a0953bcbc7d4fdf634`.

The runtime spelling is one literal prospective contract. There is no alternate
interpreter search, fallback, installation, or relaxed physical-byte admission.
Each alias receives a fresh physical observation through the existing bounded
no-follow observer. Both six-integer regular-file identities must be equal,
including device, inode, mode, size, mtime, and ctime.

Both alias chains bracket both physical observations. The walker records actual
symlink expansion, including expanded target ancestors, in component order. Each
chain is limited to 128 observed components, 32 symlinks, and 16384 bytes per link
target. Directory identities retain device, inode, and mode; regular-file and
symlink identities retain all six fields. Component names and link-target text
are retained only as hashes; link-target byte length is also retained. Directory
content timestamps are excluded because unrelated sibling creation does not
replace a directory. Missing, unreadable, nonregular, cyclic, or over-limit
chains refuse before their physical observer runs.

A successful receipt distinguishes configured and runtime observations and each
chain before and after physical inspection. Execute endpoints and both publication
checks compare every identity field; only measured observation/binding costs are
excluded. All new admission reads remain charged to the caller interval. No new
composed timing endpoint is introduced. The fixed image, OS, Python version,
source-query paths/modes, environment, 12 cases, 13-actor ceiling, 150/120/10/5
bounds, and 7/3 cleanup bounds remain unchanged. Workflow launch argv remains the
configured opt alias; child and actor argv checks use the prospective runtime
spelling, consistently with their existing `sys.executable` launch expressions.

## Historical evidence is unchanged

Run2 `38659730547` refused `selected-python-mismatch` before physical inspection.
Its observed selected-path SHA-256
`8e4121d16bb4a19e1a36abf8fbddea67e6a2b88c1b0d5ea116149bd7baaa261c`
corresponds to the proposed Cellar/bin spelling; the configured opt spelling hashes
to `b943d5b04b6c1a38452fd18788100affdbce154455f0be7a933dfcdffca5f0db`.
That is a retained spelling mismatch, not evidence of physical byte equality or
the macOS launcher mechanism. Run1's primary reason remains unknown.

## Controls and limits

The authored controls use real temporary Homebrew-shaped relative symlinks and
regular fixture bytes, with exact test-only expectation injection. The configured
source-command role, observed runtime spelling, and shared physical target remain
separate. Child/source-command execution is mocked; no actor entrypoint, native
primitive, compiler, or actual engine call is needed. The complete control follows
execute, main exit, saved shell status, outer/actor argv regrade, and the unchanged
normalizer/publisher. Negative controls retain the primary admission refusal and
scan incomplete evidence, or preserve a later identity/publication refusal.

Controls cover both alias roles, same-byte alternate files, same-target alias
replacement, physical identity replacement, changed bytes/size/hash, missing or
broken links, nonregular targets, directory-required symlink targets ending in
`/python3.14/.` or `/python3.14/`, loops and bounds, unreadable edges, malformed
identities, pre/post drift, rehashed receipt disagreement, and publication drift.
Authored controls are not evidence of a test pass or native capability support.
Independent correspondence review and separately authorized bounded local controls
must precede any native decision.

Endpoint checks cannot exclude an intervening ABA mutation between reads. The
framework, standard library, and dynamic-loader closure remain unproved. This
change establishes neither arbitrary descendant containment nor real-engine
timing eligibility, and it does not authorize another native attempt.
