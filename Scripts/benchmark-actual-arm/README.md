# One-state runtime correctness validation

This is a bounded correctness diagnostic, with one fixed baseline/Cartograph pair on the already restored
mixed-iOS compiler generation. It reuses the single existing psutil installation and records the complete
outer worker cost. It exports no performance ratio or superiority result.

See [the execution and failure contract](INTEGRATION-BOUNDARIES.md),
[the prospective installer amendment](INSTALLER-REVIEW.md), and
[exact copied-source provenance](COPIED-PROVENANCE.json). Historical original/successor scripts are
explicit test fixtures; production selects the reviewed files named by the controller.

The controller first runs all 139 integration and 43 runtime controls through the reviewed isolated
bootstrap, using a separately sealed test-source manifest and the existing single private `--target`
installation. Both full suite counts, module inventories, runtime receipts and normal exits are required;
skips, missing imports, incomplete execution or failures stop before the AB pair. Their complete costs
remain nested in controller preparation and the outer attempt wall. The actual-engine source inventory
remains separate and unchanged. CI no longer attempts these dependency-requiring suites before installation.

For a local environment that already has psutil 7.2.2, the direct developer controls are:

```sh
python3 -m unittest discover -s Scripts/benchmark-actual-arm -p 'test_*.py' -v
python3 -m unittest discover -s Scripts/benchmark-actual-arm/runtime -p 'test_*.py' -v
python3 Scripts/verify-native-measurement-contract.py
```

Only normalized safe evidence is uploaded. SDK content acceptance, real-arm observer calibration,
independent holdouts and final paired performance sessions remain separate gates.

The first native integration attempt (run 38253805122) stopped in the prematurely scheduled offline suites:
three module imports lacked psutil. In-process publication tests also failed while the actual isolated
publication CLI control passed. The original log does not retain the precise interpreter-mismatch predicate,
so its historical cause remains unresolved. Current controls preserve exact interpreter spelling equality,
explicitly distinguish it from physical temporary-directory aliases, and report only hashed spelling and
boolean physical-identity diagnostics on mismatch. The verified bootstrap supplies identical isolation
flags to future suite and publication processes; this is prospective validation, not recovered old evidence.

Running the controls inside that bootstrap exposed a separate test-fixture assumption about the outer
bytecode-cache prefix. The stale-cache control now explicitly creates the stale fixture inside its copied
package. The bootstrap/runtime implementation and its prohibition on loading that stale bytecode are unchanged.

Publication converts only request-bound runtime module maps into sorted named-entry lists. This prevents
an ordinary stdlib module named `token` from being mistaken for a credential-field key. Every original
runtime receipt and map digest is verified before a lossless roundtrip check; original receipts remain
execution authority. The existing credential/path scanner then checks all projected fields, including
module records. Raw whole-file/map hashes retain their original meaning; normalized public paths and
bytes are verified with the manifest's normalized hashes, not against private raw-map digests.

The private vendored normalizer now has an explicit identity-default input-transform hook and constructor
injection point. This is a reviewed implementation delta, recorded in the provenance overrides. Its scanner
and default CLI behavior are unchanged. Failure-only controller root receipts preserve detailed prerequisite
logs even when the state worker has not started; existing worker output is never replaced.
