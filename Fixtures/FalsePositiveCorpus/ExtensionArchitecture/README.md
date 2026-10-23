# Extension source ownership

This generalized compiler fixture comes from user feedback C-P1-4: app-local
conformances on a domain type were attributed to the domain declaration, creating
reverse module/file dependencies. It contains no company source.

`DomainType: AppProtocol` is declared in Presentation. Its protocol, typealias,
and implementation dependencies belong to that source file for file/module
architecture. The type graph intentionally keeps the semantic DomainType owner.
The protocol's DomainType return property creates a genuine semantic type cycle.

Negative controls are the real Presentation-to-Data layer violation and mutual
Left/Right file/type references in CycleControl. Correcting extension ownership
must preserve them. Native compiler execution is required; unit snapshots alone
do not prove which locations a Swift compiler emits.

The bounded rule uses a reference's recorded source location when an included
declaration or file compilation-module fact supports that file. Module attribution
requires one consistent nonempty module; absent/conflicting evidence keeps the
legacy semantic source, so this is not a guarantee that every architectural edge
has known source ownership. Symbol and type graph semantics remain unchanged.

## Native verification

Run in the existing macOS self-analysis job after `verify-feedback.py` has fetched
and verified the public archive, using the exact candidate binary built by CI:

```sh
python3 Scripts/verify-extension-architecture-contract.py
python3 Scripts/verify-extension-architecture.py \
  --candidate "$CARTOGRAPH" \
  --public-binary "$RUNNER_TEMP/cartograph-feedback/release-0.28.0/cartograph" \
  --output "$RUNNER_TEMP/cartograph-extension-architecture"
```

Upload the output's `results.json` and `logs/` even on failure. This compiles and
executes the package once, then analyzes the same unchanged index with both tools.
It compares the entire module/file dependency-pair sets, checks semantic type
cycles, and requires every corrected edge to retain matching occurrence evidence.
The public comparison records whether the reverse Domain edge is reproduced;
an absent reverse edge remains `not-reproduced`. The candidate must preserve the
actual layer violation. Preparation and per-command timing/RSS
receipts are retained; process RSS is not simultaneous process-tree RSS.

An optional `--baseline /path/to/pre-fix-main-cartograph` adds another native
comparison. Its hash and version are recorded, but its source commit must come
from an independent build receipt. Without that binary, `mainBaseline` explicitly
remains unverified. A passing public/candidate comparison does not turn the prior
source-only main review into native execution. No extra tool build is performed.

The default run also builds and analyzes the independent `ExtensionVariants`
corpus. Its additional inferred/conditional/default/alias and nested-member shapes
have their own results, hashes and timings in `variants/`; passing those controls
does not reproduce the private application's reported module SCC.
