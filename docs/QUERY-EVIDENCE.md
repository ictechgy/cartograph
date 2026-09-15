# Optional query evidence contract

`query` adds two optional fields without changing required fields, status values,
exit codes, or the `symbol-query-batch` v1 envelope. Unsupported producers omit
these fields. Absence means the producer supplied no such evidence; it does not
prove an empty reference set or complete analysis.

## Reference evidence

Each `usedBy` or `dependsOn` neighbor may contain `referenceEvidence`:

```json
{
  "items": [
    {
      "sourceUSR": "caller",
      "targetUSR": "intermediate",
      "viaUSR": "intermediate",
      "kind": "call",
      "origin": "compiler",
      "location": { "path": "/project/File.swift", "line": 42, "column": 9 }
    }
  ],
  "totalCount": 1,
  "omittedCount": 0
}
```

The neighbor's existing `location` remains its **declaration**. Evidence locations
identify the actual indexed/source occurrences. Locations use one-based lines and
UTF-8 columns. An unavailable or invalid location is omitted; a declaration
location is never substituted for it.

`sourceUSR` and `targetUSR` preserve the actual edge direction. `viaUSR` is the
adjacent node one depth closer to the requested subject. For incoming `usedBy`,
the neighbor is the source and `viaUSR` is the target. For outgoing `dependsOn`,
`viaUSR` is the source and the neighbor is the target. All same-minimum-depth hops
are represented. A depth-2 neighbor is not labelled a direct caller of the original
subject. `members` and `declaredIn` are containment and omit this evidence field.

| `origin` | Meaning |
|---|---|
| `compiler` | Derived from compiler index occurrences and their relations. |
| `syntax` | A local call/function-value reference supplied by source analysis. |
| `compilerAndSyntax` | The compiler supplied the target/occurrence; source analysis refined its local owner. |
| `inferred` | The index adapter correlated or attached otherwise unattributed compiler facts. |
| `unknown` | The input did not record provenance, including older snapshots. |
| `graph` | The graph contains the relationship but no matching occurrence was supplied. |

Origins describe evidence production. They do not establish runtime execution,
analysis completeness, or deletion safety. Provenance is stored on indexed
references and survives snapshot capture/rebasing. Legacy references decode as
`unknown`; their provenance is not guessed from an identifier.

Exact duplicates are folded; different relationship kinds or origins remain
separate. `totalCount` counts distinct evidence records, including records without
locations, **not runtime calls or compilation frequency**. Items are ordered by
location (missing locations last), then source, target, via, kind, and origin.

Cartograph emits at most 20 records per neighbor and 200 across one query result,
processing `usedBy` before `dependsOn`. `omittedCount` records the remaining number.
Budget exhaustion may produce `items: []` with a positive omitted count. Existing
`truncated.usedBy`/`dependsOn` still describe omitted **neighbors**. Inspect the
indicated source or the captured snapshot's complete references when records are
omitted. The evidence index is prepared once per query session.

MCP query batches also share a budget of 200 reference records and 50 local-function
diagnostic records across the complete response, in request order. Each result keeps
its original totals and reports additional omissions when that shared budget runs
out. Subjects, neighbors, statuses, request order, and duplicates are preserved.
Standalone CLI batches retain the per-result limits described above. Re-query a
specific symbol when shared-budget omissions hide evidence you need to inspect.

## Unrefined local functions

The top-level optional `localFunctionDiagnostics` object has the same bounded-list
shape: `items`, `totalCount`, and `omittedCount`. Every item contains:

- `name`: local function name with argument labels.
- `location`: the source declaration's path, line, and UTF-8 column.
- `ownerName` and optional `ownerUSR`: its indexed enclosing declaration.
- `reason`: the stable reason the function was not refined.
- `action`: an English suggestion for checking the evidence or rebuilding.

Reasons distinguish freshness failures (`sourceNotFresh`, `indexDateUnavailable`,
`sourceDateUnavailable`), unsupported source (`unsupportedSyntax`,
`conditionalCompilation`, `macroExpansion`, `unknownAttributes`, `localType`,
`sourceLocationRemapping`, `parseError`), and binding conditions (`ambiguousOwner`,
`ambiguousName`, `shadowedName`, `noEntryChain`, `conflictingIndexReference`,
`filteredEdgeKinds`, `existingDeclaration`). A reason explains the skipped
refinement; it is not an unused-code diagnostic.

Cartograph selects one deterministic reason per source declaration, sorts by
location/name, and emits at most 50 items. Details respect configured path filters
and are included for `found`, `ambiguous`, and `notFound`, including batch/MCP
responses. If no details exist, the field is omitted. Missing or unreadable source
still uses the existing source limitations: the tool cannot invent names it did
not read. The existing `limitations` strings remain present and unchanged in role.

Detailed diagnostics are captured in analysis snapshots and their locations rebase
with the project. Live enrichment recomputes current reasons; old reasons are not
reused to describe newly edited source. The additional fields do not change graph
edges, retention rules, or whether a declaration is reported unused.

## Companion tools

Kartograph and dartograph remain valid producers when they omit these optional
fields; no language-specific evidence is fabricated to fill them. Their existing
dynamic JSON consumers tolerate unknown keys. Isthmus uses a separate bridge query
schema, which is unaffected. This extension does not change `bridge-facts` or the
graph-exchange contract. Agent guides should interpret absent optional evidence as
unavailable, and read omission counts before acting on a partial list.
