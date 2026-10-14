# One-state runtime correctness validation

This is a bounded correctness diagnostic, with one fixed baseline/Cartograph pair on the already restored
mixed-iOS compiler generation. It reuses the single existing psutil installation and records the complete
outer worker cost. It exports no performance ratio or superiority result.

See [the execution and failure contract](INTEGRATION-BOUNDARIES.md),
[the prospective installer amendment](INSTALLER-REVIEW.md), and
[exact copied-source provenance](COPIED-PROVENANCE.json). Historical original/successor scripts are
explicit test fixtures; production selects the reviewed files named by the controller.

The controller first runs all 394 integration and 90 runtime controls through the reviewed isolated
bootstrap, using a separately sealed test-source manifest and the existing single private `--target`
installation. Both full suite counts, module inventories, runtime receipts and normal exits are required;
skips, missing imports, incomplete execution or failures stop before the AB pair. Their complete costs
remain nested in controller preparation and the outer attempt wall. The actual-engine source inventory
remains separately sealed; its graph/batch parsers and source-authored oracle are unchanged. CI no longer
attempts these dependency-requiring suites before installation.

The current baseline discovery adapter is `include-only-file-dependency-v1`. The native attempt at
`7abb50d9` reached discovery and rejected the record-free `BridgeKit.h` umbrella. Its accepted bytes
contain only quoted includes of `CGCore.h` and `CGQuoteEngine.h`; the active BridgeKit Clang module
reports those headers as Records and the umbrella as a File dependency. This does not establish the
cause of the earlier publication-blocked attempt at `4c7f491d`.

The source-bound `engine_worker.py` successor preserves the frozen primitive/vendor files. It
keeps the original discovery, main-source Record, declared-header, graph, query and input guards and
adds separate coverage only for a sealed `.h` with no source-catalog declarations and exclusively
quoted include/import directives. One active user Clang module File witness must match the declared
namespace, target and SDK. Each quoted project-header target must have one same-unit Record reachable
through every accepted root witnessing the umbrella. Missing, absolute, escaping, aliased, duplicate
or ambiguous targets, conditional/macro/body text and declaration-bearing record-free headers refuse.
Coverage is retained as `file_only_headers` plus the explicit adapter version; no Record is fabricated.
The override is scoped to the isolated baseline engine call and restored even after failure. The helper
and focused controls remain in the existing engine/test modules, preserving the original 64 admitted
contract-source paths and source-count guard.

Focused controls include the actual umbrella fixture, adversarial source/dependency cases and an
unchanged-frozen-red/current-green discovery test. A separate retained-data replay parses all 35 raw
unit outputs and derives named Unit reachability from the seven accepted object roots, reproducing the
record-only failure and passing the narrow new coverage boundary. It verifies copied fixture source
hashes against the original accepted inputs, but reconstructs a declared SDK alias and does not rerun
module-byte, generation, SDK-content, CLI or native-worker validation. Native successor success remains
to be established by a new complete run.

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

The two exact `runs/restored_rebuilt/{baseline,cartograph}/source-catalog.json` artifacts additionally
project the original declaration field `token` to `declaration_lexeme`. Their complete schema and exact types,
original bound engine request, selected plan, current accepted generation and source snapshot must agree.
The unchanged source-catalog producer regenerates every row for byte-equivalent JSON comparison before the
existing diagnostic renderer makes that reversible field change. The manifest retains raw/content hashes,
original input/plan/engine hashes, producer identity and the field mapping; source changes still block.
Other paths, embedded lookalikes, unknown fields and credential values remain subject to the unchanged scanner.
No worker status or process outcome is changed. Run 38430013161's completed child exit 1 remains a separate
unresolved execution failure; its catalog-field publication block does not identify the child failure cause.

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

## Manual actual-engine observer and SDK admission diagnostic

The optional `--calibration-mode native-observer-v1` path is diagnostic source. The ordinary
restored-state AB path remains the default. `.github/workflows/native-calibration.yml` requires a full
source SHA equal to the dispatch SHA, a read-only checkout and the exact reviewed image/toolchain
expectation in `Scripts/benchmark-inputs/native_calibration_expectation.json`. An unavailable or changed
image, machine, compiler, SDK, alias or declared absence refuses; the workflow does not select a newer
replacement. Its 45-minute overall cap can interrupt the sum of individual stage budgets. An interrupted
run is incomplete, and the declared maximum durations do not promise every stage will execute.

The manual workflow defaults to `mode=calibration`. Its separate `sdk-publication-only` mode retains
the same exact source/native checks, controls and measurement installation, then captures the two roots
once and invokes the existing safe SDK publisher. Tool/fixture builds, mixed generations, compiler-path
discovery, later seal checks and all 32 engine invocations are skipped. The projection explicitly records
the absent later seals and keeps `accepted=false` and `final_protocol_ready=false`. This smaller diagnostic
can expose a fresh publication failure category; it cannot recover the missing category from an earlier
run or establish observer eligibility. Unknown, empty or missing execution-mode fields refuse before
checkout; none of these modes changes the scanner, caps, expectations or calibration thresholds.

The resource regime `github-hosted-macos-26-standard-m1-3core-7gib-v1` prospectively requires the
[documented standard runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners):
Apple M1 (Virtual), three logical/physical cores and 7,516,192,768 bytes of RAM. It does not accept either
hardware profile interchangeably. [The first manual attempt](https://github.com/ictechgy/cartograph/actions/runs/38556206718)
failed `native-machine-mismatch` before SDK sealing or any engine invocation: its former expectation
required M2 Pro, five cores and 14 GiB, while the standard label supplied M1, three cores and 7 GiB.
The original M2 expectation remains preserved at commit `5a9ee5e4da14c9bcd36941ae004e949f94ba2c98`
with SHA256 `484080a6ea231795c81349da13ab55bb8f6670942d353ef74838db6956d11cde`; the successor names
that immutable source and failed run explicitly. A prior moving-`macos-latest` M2 observation was discovery
evidence, not a standard-label guarantee. This separate regime leaves exact software/tool hashes, SDK
roots, invocation schedule, overhead thresholds and bounds unchanged. Matching the documented profile
is a prerequisite for a new attempt, not validation of the failed attempt or acceptance of its SDK.

Before covered compilation, the existing SDK content helper captures the complete iPhoneSimulator SDK
and Xcode toolchain roots. It checks them after the existing mixed validation generations and after the
calibration attempt. The later compiler-search proposal is bound to those same roots, compiler hashes,
ordered six object/module commands, aliases and absence witnesses. These candidate receipts retain
`accepted=false` and `final_protocol_ready=false`; success is input evidence for review. The host macOS SDK
used to build the tools, OS/dynamic-loader closure, target linking/JIT/execution, atomic snapshotting and
continuous descendant containment are outside this two-root policy. Tool binaries and generation inputs
retain their separate existing identities. No reviewed final adapter or untouched holdout is introduced.

`state_inputs.calibration_plan()` is the literal 32-invocation schedule: baseline and Cartograph, each with
four direct/observed timing pairs and four independent direct/observed memory pairs. Every call has a fresh
engine directory; every observed call also has a fresh observer directory. AB/BA orders are fixed before
execution, with no replacement or reseeding. Each actual isolated engine executes the existing restored
mixed fixture and authored oracle. Complete same-engine graph/observation documents must also agree as
typed JSON, preserving array order, multiplicity and limitations. The 900-second shared phase requires
its full 240-second child budget before admitting each invocation and stops at the first failed or
incomplete operation. Failed histories are retained without successful certification.

Timing pairs compare the same engine-process boundary: after stream files are opened, immediately before
Popen through blocking root wait. For each engine separately, the median of its four observed/direct wall
ratios must be at most 1.05 and every ratio at most 1.10. This is a predeclared empirical eligibility screen,
not a population confidence bound or a product-speed comparison. Memory sessions separately verify every
rotated chunk, process identity, sample order/count, enclosing wall and summary. Their overhead is
reported separately, without primary timing eligibility; 10 ms sampling can miss short-lived descendants.

Original build, installation, SDK discovery and generation costs remain available through existing
normalizers. Each SDK seal-phase child interval includes that child's receipt serialization and teardown
and is charged fully to both engines, without halving. The supervisor records its broader wall before its
own receipt; its final serialization/teardown is still outside that interval. Observer bootstrap and
verification, state/controller/outer caller costs are separate retained boundaries, not subtractions from
engine time. These diagnostic clocks do not establish a fully composed final-protocol endpoint.

Large SDK seals use an explicit reversible entry-chunk projection. Every original entry, order,
multiplicity, field and raw hash is retained; equal postcheck entry sets may reference the candidate only
after equality verification. The inverse and all original source identities are checked again after
publication. Paths in the public derivative are normalized, so it is not byte-identical to the raw seal.
The unchanged scanner still limits each file to 8 MiB and each bundle to 64 MiB; overflow or a privacy
refusal has no raw fallback. Projection, normalization and recheck costs remain separate. Publication
failures log only a fixed scanner category and validated artifact/value SHA256 identifiers; arbitrary
exception text, paths and values are not logged. These diagnostics preserve the original failure and costs.

[The standard-regime attempt](https://github.com/ictechgy/cartograph/actions/runs/38564258706) completed all
32 calls with matching same-engine outputs, but was ineligible: Cartograph's first timing ratio was
1.1506344551, above the unchanged 1.10 per-pair bound (median 1.0045964348). Baseline timing passed
(median 0.9816959952, maximum 1.0298539215). Memory remains a separate descriptive observation. The failed
calibration bundle was retained; the SDK candidate's reversible projection passed but ordinary
normalization failed. The original failure category was not retained publicly and cannot be
recovered by this diagnostic change. The after-calibration phase also requires controller success, so its
nonzero exit alone does not establish SDK content drift. Full SDK final-seal readback and observer timing
eligibility remain unaccepted; no replacement samples, final holdout or final paired benchmark are implied.

[The separate SDK-publication-only attempt](https://github.com/ictechgy/cartograph/actions/runs/38581186386)
completed its before-compilation capture with zero engine calls, then refused publication. Its safe
`unmapped-absolute-path` diagnostic identifies the before-compilation results artifact and the value
`/v1` by SHA256. The source reproduces a lexical scanner failure on the declared `include/c++/v1`
absence witness after an approved root replacement. The failed raw JSON is unavailable, so this does
not identify its exact original field or explain the earlier run's failure. The successor scanner
recognizes a complete lexical path only when its root was actually replaced; public output retains
the same logical-root text, while above-root traversal and unmapped suffixes still refuse. Credentials,
Windows paths, artifact scope and byte caps remain screened. This source correction does not establish
SDK admission or final-seal acceptance, or reverse the retained observer timing refusal.

[The first mapped-path native CI attempt](https://github.com/ictechgy/cartograph/actions/runs/38585899731)
passed its executable validation but refused measurement, SDK-discovery and comparison publication.
The safe value hashes match the already-retained Homebrew `python@3.14` path suffixes. Those unsupported
suffix characters left an internal marker visible to the path scanner. The successor restores any
unconsumed marker to its prior logical-root text before the existing absolute-path scan; it does not
expand the trusted component alphabet. The specific-alias and above-root checks still govern paths
granted new masking. The original native refusal remains retained, and this correction has no manual
observer execution result. The later SDK-only result is recorded below.

[The changed-source SDK-only attempt](https://github.com/ictechgy/cartograph/actions/runs/38601748380)
again completed its before-compilation capture with zero engine calls. Publication then refused
`/v1` in the first projected SDK entry chunk, identified by the retained artifact/value hashes.
The original seal stores entry paths and symlink target paths relative to their declared roots;
those strings do not undergo an absolute-root replacement. A real temporary SDK directory and
contained symlink reproduce this mechanism through the original capture and publication helpers.
The failed raw chunk is unavailable, so its exact offending entry or field is not established.

The successor internal projection format is version 2. Only validated `entry.path` and symlink
`target.path` fields become explicit `path_components` arrays. Their full unsplit strings pass the
existing sensitive-content and Windows-path checks before encoding, and every projected byte still
passes the unchanged normalizer. The strict inverse restores each exact original path string before
the existing original-value and content-identity checks; other fields, entry order, counts, original
hashes, costs and byte caps remain bound. Invalid or mixed path forms, unknown fields/roots and
noncanonical components refuse, even when enclosing checksums are recomputed. Version 1 artifacts
remain preserved with their original source; the version 2 reader does not silently reinterpret them.
Early privacy refusals from the projection retain the wrapper's generic safe failure diagnostic;
ordinary normalizer refusals keep their existing category/hash diagnostic.
[The v2 SDK-only attempt](https://github.com/ictechgy/cartograph/actions/runs/38615315223) passed capture
and safe publication on exact source `1b06789a1b3d29dfca94978d4464e3d5c79805bb`. Independent readback
reconstructed all 17,142 entries (13,831 files and 171 symlinks), both content/canonical identities and
264 published manifest rows. Its content identity is
`50fcaf77a96f5701e55ff5d16812d0d8ec2fdb2d250a826e58447dac4371613c`. This establishes that attempt's
before-compilation candidate only. It does not supply earlier missing seals or prove compiler-generation
closure. Candidate-only flags, absent later seals and the retained observer timing refusal remain.


### Prospective compiler-only generation brackets

The explicit `sdk-generation-only` mode is a validation-only route. It uses the existing mixed-iOS
compiler fixture with `fresh-shared-v2`, iPhoneSimulator and deployment target 16.0; no product hook,
Cartograph/index-dump build, query, engine invocation or final holdout is selected. The eight fixed
build-generation attempts retain 48 planned top-level compiler commands and expect 43 actual commands:
seven complete six-command builds plus the first Clang command's expected positive header-delete
failure. Five intervening source-only states execute no compiler. A timeout, cancellation, signal or
incomplete cleanup cannot stand in for that expected compiler failure and stops further phases.
The existing 11 setup probes and ten restored-state discovery probes remain explicit, in addition to
the unchanged native admission probes. Every actual compiler argv, source state and generated-output
identity must match its stage-specific recipe; later restored discovery does not excuse an earlier
command difference.

The initial full two-root capture is followed by a full content read before and after each of the eight
attempts and one final read after restored-state discovery: 18 full SDK/toolchain reads. All must bind
the independently reconstructed candidate content identity above. The generation projection has a
separate fixed 19-record map: initial, 16 generation boundaries, final post-discovery and an explicitly
missing after-calibration record. Stopped prefixes preserve missing later records; a hole or an extra
record refuses. Entry references require verified equality and preserve every original field, cost and
hash. The same v2 inverse and unchanged 4 MiB chunk, 8 MiB/file and 64 MiB/bundle limits apply.

Admission, setup, compiler and selector children use exactly eight environment keys: fixed system PATH,
C locales, the reviewed DEVELOPER_DIR/ImageOS/ImageVersion and fresh owned HOME/TMPDIR. The exact
values and directory identities are bound before admission. PATH alone is represented as its four fixed
ordered components in public receipts and reconstructed exactly for execution; no inherited language,
plugin, dynamic-loader or Python overrides are admitted. Expected cache content changes in the owned
directories are allowed, while replacement of those directories refuses.

One 1,800-second monotonic controller budget includes admission and receipt work. A phase starts only
if its entire declared child allowance remains: 570 seconds for initial/final admission, 1,200 seconds
for the complete lifecycle, and 180 seconds for discovery. These maxima sum to 2,520 seconds, exceeding
the controller budget deliberately: an unstartable next phase remains not-started and the attempt is
incomplete; allowances are never silently shortened and complete execution is not guaranteed.
The lifecycle uses its own single deadline,
including setup, hashing, compiler work and receipt work; nested command limits cannot extend it.
One fixed outer invocation observes the controller's actual exit with an 1,815-second allowance inside
the 31-minute workflow step. Publication binds its exact command, interpreter/source hashes, original
streams, typed exit and elapsed wall; a complete inner JSON cannot override a failed outer result.
The enclosing child intervals include child receipt serialization and teardown. Boundary/compiler
subintervals are retained for attribution and must not be added again to the enclosing shared cost.
Full shared costs are assigned identically to each arm; final controller receipt/teardown and publication
costs remain separately scoped, so no composed comparison endpoint is reported by this diagnostic.
The existing 45-minute job cap can interrupt later publication. Upload of an incomplete attempt is
best effort, never guaranteed by the sum of individual step limits.

These brackets observe endpoints on a mutable filesystem. They do not prove atomic reads, exclude an
intervening change-and-restoration, or close host macOS SDK, OS/loader, link/JIT or target runtime inputs.
A compiler driver exit does not establish detached-descendant containment. Successful output remains
`accepted=false`, `final_protocol_ready=false` and validation-only. The rejected observer screen is
unchanged, and this source preparation has no native generation-bracket execution result yet.


The first native CI check of this generation route (CI506, source `1af4c465`) retained a
one-error synthetic-publication refusal before any compiler-generation validation ran. Its safe value
hash identifies `/Cellar/python@3.14/3.14.7`; the stack and prior interpreter record support a relative
Homebrew interpreter-symlink target as the mechanism. The complete failed link-target bytes were not
retained, so the exact original field value is not claimed as recovered. The prospective real temporary Homebrew-shaped
symlink control checks that suffix through the original unchanged scanner.

Only this new interpreter-alias record encodes each symlink target as explicitly marked slash-split
components plus its original UTF-8 SHA256. Joining those components preserves leading, repeated and
trailing separators and `..` as inert observed link metadata. The unsplit target receives the unchanged
sensitive-value and Windows-path checks both before encoding and after inverse reconstruction. The
entire reconstructed alias chain and physical executable identity must match fresh filesystem evidence;
a matching rehash alone cannot admit changed metadata. Other fields, order, generic scanner rules and
publication caps remain unchanged. The corrected ordinary CI507 and post-main508 passed, including the alias controls and
ordinary publication. These results do not establish generation-bracket or direct-timing eligibility.


### Safe generation supervisor failure summary

Generation-only run6 (`38638885985`, source `d19ead28`) retained an early supervisor
`incomplete`/125 outcome and a generic SDK-publication refusal. Its sole published artifact was
measurement setup evidence. No generation phase originals were published, so its exact cause,
completed compiler commands and SDK-read counts remain unknown. The earlier observer timing
refusal and missing SDK seals remain separate retained results.

The supervisor now projects a future completed child's final stdout JSON, or its existing early
refusal stderr JSON, into fixed phase/type enums and strict lowercase SHA-256 identifiers. The
summary includes only the actual typed returned/observed exit and finite child wall, plus hashes
under three fixed original-stream labels. It prints no raw path, arbitrary exception text, command,
environment value or stream contents. Missing, malformed, changed, nonregular or oversized originals
produce a fixed unavailable summary; unproved child cleanup prevents further stream reads. A zero
child with unavailable originals remains incomplete. A success JSON can never override actual125.

Diagnostic read cost lies inside the existing full supervisor caller interval; the actual child's
status and wall remain unchanged. Publication independently recomputes the typed summary from the
verified originals. The execution schedule, 1800/1815-second bounds, strict scanner, source admission
and publication caps are unchanged. This is prospective diagnostic coverage, not a reconstruction of
run6's missing receipts or a completed native generation validation.

### Prospective native waitid capability only

The separate manual `waitid-capability.yml` route prepares one fixed synthetic capability check,
not a replacement timing result. It requires an explicit full source SHA equal to the dispatch source,
the reviewed macos-26 image and the selected/physical Python 3.14.7 executable identity. Two fixed Git
metadata children bind the exact five runtime source paths/modes/blobs before and after one capability
child. The executable pin does not close Python framework/stdlib or dynamic-loader inputs.

Twelve fixed cases allow at most thirteen directly owned actors and two live/unreaped actors at once.
Native `os.waitid(WEXITED | WNOWAIT)` is required; unsupported primitives refuse without a fallback.
Each actor has its own five-second watchdog. The ten-second case and 120-second suite bounds retain
actual terminal observations, individual cleanup and later reap agreement. The cases cover normal and
signal exits, timeout/TERM resistance, sequential/joint release, a live member and an explicitly owned
session escape. These observations cover the enumerated actors, not arbitrary descendants. The live,
escape and cleanup-needed observations retain their incomplete/scope-violation meanings even when the
expected capability case passes.

The outer child allowance is 150 seconds, followed when needed by seven-second TERM and three-second
KILL-wait cleanup. Short waits share one absolute deadline; cancellation is deferred through reap and
anchor assignment. No numeric PID/group signalling follows a reap or uncertain wait failure. If a
child may still write, its stream digests, inventory and publication are withheld. A failed actual
workflow process exit cannot be overridden by an already-flushed complete JSON receipt. Complete
publication binds all 38 original files, exact ledgers, source/interpreter identities and empty actor
streams before and after the unchanged scanner. Its existing 8 MiB/file and 64 MiB total caps remain.
The five-minute job makes timeout-time artifact retention best effort. Nested process, caller and
publication costs remain separate; the caller receipt excludes its own serialization and teardown.

All results retain `capability_only=true`, `descendant_closure_eligible=false`, `timing_eligible=false`,
`final_protocol_ready=false` and zero engine calls. Real-engine completion/no-detach admission remains
separate, and run2's rejected timing-observer sample is unchanged. No native capability result is
credited by this source preparation. The local mocked controls passed 17 inner methods and 27 outer
methods across two attempts; the first attempt retained a zero-test discovery exit5 for the hyphenated
outer filename. Direct-file invocation and a workflow regression assertion corrected that route.
Test-scoped placeholders fill only absent native names for pure mocks and restore absence afterward;
they never enter the capability child. Actionlint and four shell syntax checks passed; no shellcheck
result is claimed.

Existing ordinary CI workflow bytes are unchanged, but its broad SDK test discovery also includes the
new 17-method inner mock suite. The 27 outer methods remain local/manual-route checks. Neither suite
starts capability actors or establishes native primitive availability.

### Prospective runtime cache metadata compatibility

[CI510](https://github.com/ictechgy/cartograph/actions/runs/38641649265), on source
`c0ab7d1b74f17b4ff930a5607478ab69f40a7100`, remains a retained failure. Its Python 3.15.0 runtime
suite ran 90 tests with one `KeyError: bytecode_cache` in
`test_captured_stale_package_bytecode_is_never_loaded`; integration passed all 394 tests. The error
followed the fixture's successful child-exit and psutil 7.2.2 assertions. Its exact nested receipt was
not separately retained, so the original module metadata cannot be reconstructed from that assertion
failure alone. Whole-state execution did not start, and CI510 has not been replayed or regraded green.

Python documents that [3.15 no longer sets module `__cached__`](https://docs.python.org/3/reference/datamodel.html#module.__file__)
and exposes the cache path through [`ModuleSpec.cached`](https://docs.python.org/3/library/importlib.html#importlib.machinery.ModuleSpec.cached).
This successor reads that modern field first, with explicit legacy fallback when it is absent or
`None`. Both present paths must resolve identically; empty, non-string, invalid or conflicting metadata
refuses with `ValueError`. Missing metadata does not claim a verified absent cache. A declared path
still records `exists=false` when no file is present, or the observed file's complete byte/hash identity
when it exists. Existing origin/private-cache confinement, file hashing and byte caps remain unchanged.

The malicious timestamp-valid stale-bytecode fixture, child exit-zero assertion, psutil version check
and required absent-cache assertion are byte-preserved. Nine additional local source-backed controls
cover spec-only metadata, legacy agreement/fallback, absent versus missing metadata, malformed/conflicting
values, direct/symlink escapes, the explicit private cache root and byte caps. The retained spec-only
first-red used real source/cache files and a real `ModuleSpec` without `__cached__`; unchanged source
failed the required cache-row assertion. The successor passed all 23 focused identity methods and one
full isolated schema3 replay of 394 integration plus 99 runtime methods, with zero skips or failures.
The focused 23 are also included in those 493 unique suite methods. The malicious stale-code fixture
remained byte-identical throughout.

That local Linux replay copied the existing psutil 7.2.2 dependency and used explicitly synthetic
installation provenance. Its declared allowance was 300 seconds per suite, 630 seconds for the caller,
and 660 seconds overall with 20 seconds of cleanup grace. Actual integration/runtime child walls were
201.315739/45.892718 seconds. The integration wall exceeds the unchanged native 180-second allowance;
local success does not establish native budget eligibility. All 204 current-source and five retained-input
brackets matched. Corrected ordinary CI512 passed all 394 integration and 99 runtime methods within
the unchanged 180-second native allowance on its bound Python 3.14.7 interpreter. That result does not
claim a native Python 3.15 successor run. This change supplies no native benchmark, compiler-generation,
observer-eligibility or final-protocol result.

### Prospective early-admission failure retention

The first manual capability run, [38646168312](https://github.com/ictechgy/cartograph/actions/runs/38646168312),
used source `d1821b20ca865ac43b014f48699cdc19f22c4bc8` and tree
`c036fb6d2249b664c25ea7bb70335f0985b6ddef`. Its 17 inner and 27 outer mock methods passed;
the observation step exited 1 and publication exited 125 with `KeyError`. The safe message SHA256
`a81f2c5cf82730e8069e59c7f74129cbb564a42322c2b549692843c76e348dcc` matches
`str(KeyError('source_before'))`. The run retained zero artifacts. This identifies the secondary
missing-source-record failure only: the primary admission reason and actual metadata-child,
capability-child and actor counts remain unavailable.

The prospective correction retains fixed admission reasons, bounded typed version/OS/image fields,
and executable-path, file-identity and exception hashes. Malformed observations are unavailable or
hash-only. Physical admission also requires six exact nonnegative identity integers, regular-file
mode and size equal to observed executable bytes. Python 3.14.7, Darwin 25.6.0/arm64, image
`macos26` / `20260907.0351.1`, executable/source pins and all child budgets remain unchanged.

Missing `source_before` is permitted only at the literal pre-child interpreter-admission checkpoint,
with no source, command or capability records and exactly empty original membership. Retention
requires an integer shell exit in 1–255, finite nonnegative non-boolean caller cost and exact scope
strings. The unchanged scanner can retain the two terminal receipts as incomplete evidence;
publication success never replaces the original failed exit or creates completed membership or
actor counts. Later partial attempts retain their existing source/interpreter checks, and uncertain
child ownership still suppresses material reads and publication. All capability-only and false
eligibility flags above remain unchanged; no admission fallback is introduced.

The retained baseline-compatible first-red reproduced exactly `KeyError('source_before')` through
the real early-failure execute/status/publisher route. The successor then passed all 43 outer and
17 unchanged inner mock/file controls, with all nine current-source and five retained-input brackets
equal. The outer controls include actual temporary-file identity observations and unchanged-scanner
publication, while command and actor launches are blocked. The declared local limits were 30 seconds
per child, 120 seconds overall and 10 seconds cleanup grace; actual successful child and outer exits
were zero. No native retry or capability, descendant-closure, timing or final-protocol acceptance is
established by this correction.
