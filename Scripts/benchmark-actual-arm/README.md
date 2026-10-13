# One-state runtime correctness validation

This is a bounded correctness diagnostic, with one fixed baseline/Cartograph pair on the already restored
mixed-iOS compiler generation. It reuses the single existing psutil installation and records the complete
outer worker cost. It exports no performance ratio or superiority result.

See [the execution and failure contract](INTEGRATION-BOUNDARIES.md),
[the prospective installer amendment](INSTALLER-REVIEW.md), and
[exact copied-source provenance](COPIED-PROVENANCE.json). Historical original/successor scripts are
explicit test fixtures; production selects the reviewed files named by the controller.

The controller first runs all 313 integration and 60 runtime controls through the reviewed isolated
bootstrap, using a separately sealed test-source manifest and the existing single private `--target`
installation. Both full suite counts, module inventories, runtime receipts and normal exits are required;
skips, missing imports, incomplete execution or failures stop before the AB pair. Their complete costs
remain nested in controller preparation and the outer attempt wall. The actual-engine source inventory
remains separately sealed; its query adapters and source-authored oracle are unchanged. CI no longer attempts these dependency-requiring suites before installation.

For a local environment that already has psutil 7.2.2, the direct developer controls are:

```sh
python3 -m unittest discover -s Scripts/benchmark-actual-arm -p 'test_*.py' -v
python3 -m unittest discover -s Scripts/benchmark-actual-arm/runtime -p 'test_*.py' -v
python3 Scripts/verify-native-measurement-contract.py
```

Runtime configuration version 3 separates the installation-selected executable spelling from the exact
reported spelling observed in the original selected startup probe. Every suite, state, engine and observer
launch still requests that installation-selected path. Before and after execution, receipts must report
only the probe-established path and the same current physical interpreter, source and startup profile.
The original installation binder and direct/one-exec limit remain unchanged. Versions 1 and 2 remain
explicit historical fixtures and cannot gain this relation's admission.

Successful publication now requires both arms' original input, arm, worker, command, measurement, observer
and runtime/environment receipts. Embedded copies must agree with those originals, and their hashes are
checked again after staging. A passed summary with missing originals is insufficient.

The 2026-10-13 cloud reconstruction starts from published PR171 head `1246bd07`; unpublished local artifacts
from the lost workspace remain unavailable. Fresh Linux controls exercise the comparator and real Python
subprocesses. They do not establish macOS launcher behavior or a native Cartograph comparison; that needs
the existing macOS CI job. Historical evidence archives are unchanged.

Only normalized safe evidence is uploaded. SDK content acceptance, real-arm observer calibration,
independent holdouts and final paired performance sessions remain separate gates.

The prospective interpreter-failure projection adds 25 pure/mocked integration controls; their source-only
freeze is not execution evidence. It does not alter the original exact phase-command/interpreter spelling
comparison. A typed internal ValueError carries the failing fixed helper phase, original measurement hash,
and both observed spelling hashes. Physical identity is either observed at failure as a boolean or explicitly
unavailable. The bounded pre-record parser accepts the extension only for the exact spelling-mismatch reason,
selected-launch or installation-binding stage, ValueError classification, and normal exit 1.

Each retained startup probe may independently expose requested/reported spelling hashes and physical identity
equality, bound to exact request, observation, process and source-inventory hashes. Missing historical or current
observations remain unavailable; one failed projection does not erase the aggregate collection outcome or cost.
A selected request can expose direct/one-exec mode only after its original installation, arguments, source and
startup-profile bindings pass again. Request-only verification never proves an exec occurred or fills a missing
selected-process observation. None of these summaries is execution authority. Diagnostic reads remain inside
the original child or publication wall; costs are never excluded or subtracted. Earlier generic failures and
round 29's missing details are not upgraded by this prospective schema.

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

The next native attempt (run 38260361983) retained a completed pre-record TypeError refusal and no AB
result. Its accepted mixed setup has `developer_dir: null`, meaning no explicit override was requested;
the compiler, library, platform and SDK paths are still explicit. The original traceback is unavailable.
Replaying that exact null shape against the old controller reproduces `Path(None)` before raw output.
The successor derives one developer directory only from the accepted physical compiler/library toolchain
and requires the SDK/platform to belong to it. An explicit override must agree. Lexical/physical directory
identities are recorded and rechecked with every generation guard; different toolchains, escaping aliases,
replacement directories and absent context refuse execution. There is no ambient Xcode lookup, additional
root acceptance or weakening of interpreter equality. These directory identities are not SDK content seals.

The normalized native receipts merge developer aliases into one token, so the original alias spelling
cannot be fully replayed on Linux. An explicit Xcode bundle-alias control resolves the selected lexical
ancestor to exactly the accepted physical developer directory and watches the traversed alias identities.
It neither searches for another Xcode nor admits a different physical SDK/toolchain context.

Run 38265144652 retained another completed pre-record refusal, now with the generic ValueError envelope.
Its precise predicate and stage are unavailable; no alias or interpreter cause is assumed and no AB
execution is established. A subsequent diagnostic-only addition wraps the existing finite pre-record
stages without changing their admission predicates. A controlled reason identifier is emitted only for
an exact known error message; other messages are represented solely by their full SHA-256. The outer
attempt verifies the bounded typed JSON against the original stderr bytes and actual process return.
Signals, timeouts, malformed/changed logs and historical unavailable logs cannot certify a stage.
Publication rechecks the same diagnostic and preserves original red/incomplete exit and costs. No raw
exception messages, paths, environment or source data are added to the safe envelope.

Run 38269035141 gives the first specific native boundary: installation-binding refused because the
current interpreter spelling differs from a prior helper command. All original helper commands and
prospective selected paths use the same installation-selected Homebrew spelling. An exact whole-argv
hash replay identifies the supervisor request as the shorter Homebrew launcher spelling. The child's
reported spelling and current physical identity are not recovered from that envelope. Earlier generic
refusals remain unclassified.

A prospective selected-launch step first binds the unchanged original installation receipts to their
exact selected spelling and checks the current interpreter is the same physical file, metadata and bytes.
It records an exclusive request in the existing attempt directory and may replace the already measured
child once using that selected spelling, fixed isolated flags, original arguments and unchanged private
environment. The replacement must actually report the exact selected spelling and pass the original
installation binder; framework-launcher rewriting still refuses, without another exec. No package is
installed again. Original preparation, exec, repeated verification and teardown stay inside the original
outer child cost. Nested preparation/observation fields are diagnostic intervals, never additive endpoint
components or exclusions.

A successful controller and public completion require the original request, actual selected-process
observation, installation binding, source/argument hashes and runtime interpreter to agree. The publisher
rechecks the request/observation after staging and verifies exact raw-copy hashes before accepting complete
evidence. Missing or changed launch details retain a red safe attempt. The credential/path scanner is
unchanged. Local alias controls do not establish native Homebrew behavior, SDK acceptance or loader closure.


Run 38274111344 stopped before creating the selected-launch request: the actual child's environment
failed exact equality with the requested private environment. The safe native envelope identifies only
that predicate; it does not identify a differing key or value and does not establish an exec or AB result.
A diagnostic-only successor preserves that refusal and adds fixed identifiers for missing or changed
expected keys, the count and SHA-256 of sorted extra key names, and presence identifiers for three
predeclared Python/macOS startup candidates. No environment values or unknown names are published.
The bounded stderr parser accepts this extension only for the exact selected-launch ValueError/exit 1
and rechecks the original log identity at publication. It does not grant any new environment admission.

A Linux Python 3.12.14 process replay with the exact `-I -S -B` flags preserved the requested environment.
Removing `LC_ALL` in a separate control caused Python to add `LC_CTYPE`, even under isolated startup.
This establishes a diagnostic control only; the original native environment and macOS cause remain
unavailable until an actual prospective observation. Local controls never substitute for that evidence.

Run 38278741516 identifies one additional startup key in the actual child: the fixed identifier for
`__CF_USER_TEXT_ENCODING`, with no missing or changed expected keys. The two-envelope artifact does not
reveal its value or exact origin and contains no selected-launch or AB result. Earlier failures remain
unclassified. Official CoreFoundation/CPython source supports a prospective startup hypothesis, not a
claim that the historical runner used those exact source revisions.

The prospective successor collects at most two fresh, physically identical interpreter spellings inside
the already supervised correctness child. Every outgoing environment remains the exact original fixed
private request. A bounded Darwin-only addition is admitted solely when its UTF-8 length and SHA-256
agree at early/post-controller-import observations, across both probes, and in each actual selected,
contract-suite, state, engine and observer process. Unknown additions, changed or missing requested
keys, changed value hashes and incomplete probes refuse before later execution. No value is copied
from an ambient environment, deleted, overwritten, guessed or published. The profile describes Python's
observed environment mapping; it does not establish native cached state or loader closure.

Probe imports compile the exact admitted source bytes, including local transitive imports, rather than
trusting bytecode caches. Lexical and physical local aliases cannot escape that source inventory. Final
request/log/observation rereads are followed by source, interpreter and directory guards. A one-exec
replacement reuses the exclusive verified collection and cannot launch another probe or second exec.

The preceding runtime configuration version 2 binds the shared profile plus an exclusive environment request for each
actual process. Original request/interpreter/package/code and terminal checks remain mandatory. Historical
version-1 runtime controls remain available as explicit unit fixtures, but complete current controller
publication at that revision required version 2 and the verified selected-launch collection.
Current publication requires version 3 and its exact selected-probe interpreter relation. This changes the local
bootstrap and measurement adapters; the frozen measurement worker and strict normalizer bytes remain
unchanged. Provenance distinguishes these changes from historical copies.

The original collection and exact copied evidence keep their raw hashes. A copy manifest maps original
private log locations to public artifact-relative members without changing receipt semantics. Publication
rechecks the original collection, each copied byte stream, actual environment-request receipts, runtime
observations and staged hashes. A failed collection keeps its original typed outcome/hash and nested cost
in the safe attempt summary. Startup collection, rechecks, selected exec, suites and both actual arms all
remain within the original whole-child wall; nested measurements are explanatory and never added twice.
Native startup behavior, current SDK content acceptance and performance proof remain unestablished.

The controller and publisher also compile their bounded initial local imports directly from the fixed source inventory. The policy file itself is read without following links or consulting bytecode caches. Unknown local source/bytecode and lexical aliases escaping that inventory refuse before their bodies execute. Standard-library/loader closure remains outside this bounded claim.

Local native-extension loader create/exec paths are also rejected before native code can run, using both lexical and resolved origins. This applies only to the declared controller source tree; the separately sealed private psutil installation remains outside that tree. Regression controls mock the native loader and never compile or load a new binary.
