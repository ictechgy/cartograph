---
name: cartograph
description: Use before deleting any Swift declaration, when cleaning up dead or unused code, and when asked who calls or depends on a declaration in a Swift project. Answers come from the compiler's index, not from text search.
---

# cartograph

`grep` finds text. The compiler index knows which declaration a name resolved to. Use this
tool for questions about Swift symbols, and use `grep` only for things that are genuinely
text — comments, strings, resource names.

## Before deleting any declaration

Run this first and read the whole answer:

```bash
cartograph query <name-or-USR>
```

Then apply these rules. They are the point of this skill, and they apply to every
declaration you are about to remove, whether you got it from `query` or from a list
produced by `cartograph dead`.

1. **`state` is not a verdict.** `unreachable` means "not reachable from any retained root",
   which is a fact about the graph. It is not "safe to delete". Nothing in this tool's
   output ever says a declaration is safe to delete, and you must not infer it.

2. **A retained root is an entry point, a test, or a declaration a retention rule kept.**
   Public API is *not* a root unless the project turned it on — `retain_public` defaults to
   off. In a library or framework whose callers live outside this repository, that means the
   entire public surface is reported `unreachable` and deleting on that basis breaks every
   consumer. Check for `retain_public: true` in `.cartograph.yml`, or re-run with
   `--retain-public`, before you believe an `unreachable` verdict about public API.

3. **Read `limitations` in the same response.** It lists the channels this analysis cannot
   see, counted from the project you are in. If it names Objective-C sources, an
   `unreachable` Swift declaration may be called from a `.m` file the analysis never read.
   If it names Interface Builder documents, connections are matched by class name only. If
   it reports `index-staleness`, the index predates recent edits — rebuild first.

4. **`suppressedByBaseline: true` means the team already decided.** Leave it alone. Do not
   re-litigate a decision that is recorded in the baseline file.

5. **`dependsOn: []` on a type does not mean it depends on nothing.** On a symbol-level
   graph a type's dependencies are held by its members. Follow `members`.

6. **`reason` tells you why something survived.** A value like `interfaceBuilder`,
   `objectiveCAccessible`, `codingKey` or `caseIterableEnumCase` means the compiler index alone
   would have called it dead. Deleting it breaks something the index cannot see.
   `externalBridge` means Dart, JavaScript or Kotlin calls it across a platform channel,
   according to a retentions file the project supplied (`external_retentions_path` or
   `--external-retentions`); run `cartograph dead --explain <name>` with that file in effect
   and it quotes which file and line does so. Without the file the same declaration comes
   back `unreachable`, which is the index's view, not the whole truth.

## When the rules pass

Passing the rules is not permission. The tool has told you what it can see; it has not told
you the code is unused. So:

- Delete only what the user asked you to delete. A clean `query` result is a reason to stop
  worrying about *that* declaration, never a reason to widen the change to declarations
  nobody asked about.
- When the user asked for a sweep, propose the list and say what you checked — the state,
  the reason, and which limitations were in effect — and let them decide.
- If a limitation applies to the declaration in front of you, say so instead of deleting and
  hoping. "This is unreachable, but the project has 12 Objective-C sources this analysis
  does not read" is the useful answer.

## Answers this tool cannot give

- **Objective-C declarations.** Only `.swift` files enter the graph; `bridges` reads `.m`
  files as text for React Native export macros and nothing more. Nothing here tells you
  whether a `.m` declaration is used.
- **Callers in another language.** A Flutter or React Native handler is called from Dart or
  JavaScript, which the index never sees, so it looks `unreachable`. If the project has an
  `ios/` folder inside a Flutter or React Native app, or a `.m` file with `RCT_EXPORT_*`,
  treat `unreachable` on a handler as unknown. A retentions file being in effect
  (`limitations` lists `external-retentions`) does not change that for a declaration whose
  `state` is still `unreachable`: the join may have missed it, and `limitations` will say
  why (`external-retentions-unmatched`, `-ambiguous`, `-stale`). Only a `retained` or
  `retainedByMember` state with `reason: externalBridge` means the other side was found
  calling it (or one of its members).
- **Declarations behind an uncompiled `#if` branch.** The index store knows only the configuration
  that was actually built, so a declaration used only from a branch that did not compile looks
  unreached. Do not treat `unreachable` as settled for code inside `#if` until it has been built
  in that configuration.
- **Anything you changed in this session.** The index is written by the compiler at build
  time. If you edited Swift and did not rebuild, the answer describes the code as it was
  before your edit.
- **Whether a rename is safe.** Interface Builder outlets and actions are matched by class
  name, and `@objc` names are strings. Renaming can break the same connections that deleting
  would.

## Answering "who uses X?"

```bash
cartograph query MyType             # direct users and dependencies
cartograph query MyType --depth 2   # two edges out, in both directions
```

Each neighbour carries `edges` — every relation reaching it, such as
`["call", "overrides"]` — plus `module`, `depth` and its declaration site. Note that
`location` is where the neighbour is *declared*, not where it uses your symbol.

A name matching several declarations comes back as `status: "ambiguous"` with candidate
USRs. Ask again with one of the USRs rather than guessing.

`truncated` says the answer hit `--limit`. Raise the limit or narrow the question; do not
report a truncated list as complete.

## Sweeping a whole project

Every entry in these lists is a declaration, so every rule above applies to every entry.
A long list is not a mandate.

```bash
cartograph dead --report-format json    # every unreachable declaration, with `limitations`
cartograph dead --explain MyType        # why one declaration survived, in prose
cartograph dead --since origin/main     # only what this branch touched
cartograph cycles                       # circular dependencies, with the link to cut
cartograph rules                        # layering violations
```

## Asking about many declarations at once

Do not loop `cartograph query` over a `dead` report. Each run reads the whole index again;
the answers are cheap and the preparation is not. On a 7,466-symbol app, asking about all
43 findings one at a time took 19.6 s and one batch took 0.47 s, with identical answers.

```bash
cartograph dead --report-format json | jq '[.diagnostics[].subject]' > /tmp/requests.json
cartograph query --batch /tmp/requests.json
```

The file is a JSON array of 1 to 1000 names or USRs. Results come back in request order
with duplicates kept, so you can pair the two arrays by index, and each element is exactly
what a single `query` returns — the rules above apply to every element. `ambiguous` is a
normal result. If one name is missing the exit code is 64 but every other answer is still
in the output, and the missing names are listed on stderr — read the output before reacting to
the exit code. A batch also answers every request from one snapshot, so a sweep cannot straddle
a rebuild.

## Do not read the whole graph

`cartograph graph --format json` emits every node and edge — tens of thousands of edges on
a real project. Loading that answers no question you could not answer with `query`, and it
crowds out the context you need to do the actual work. Ask about the symbol you care about.

## Exit codes

`0` success · `1` findings with `--strict` or a threshold exceeded · `2` tool failure, such
as a missing index store · `64` usage error, including a name that matches nothing.

A `64` from `query` means the name does not exist in the index. That is not evidence the
code is unused — check your spelling, and check whether the target was built.

A `2` that says the index store knows none of this project's declarations means the tool
saw nothing at all. Do not treat it as "nothing is wrong". The message names what it read
and how many source files were in scope; the usual causes are a `--project` pointing at the
wrong directory, an index built for another checkout, and include/exclude patterns that
removed every file. Fix the cause rather than passing `--allow-empty-index`, which silences
the check and makes every later answer a statement about nothing.

## If there is no index store

Look for one before starting a build. An app already built in Xcode has a store under
`~/Library/Developer/Xcode/DerivedData/<name>-<hash>/Index.noindex/DataStore`, and Cartograph
finds it when `--project` points at the directory that holds the `.xcodeproj` or `.xcworkspace`.
In a Flutter or React Native app that is `ios/`, not the repository root, so try
`cartograph query <name> --project ios` before anything else. If the build used
`-derivedDataPath`, pass that directory with `--derived-data <path>`.

Only if none of that finds a store does the project have to be built:

```bash
swift build
xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
```

Then pass `--index-store <path>` if it is not found automatically. A full `xcodebuild` can
take minutes and needs a working signing setup, so ask before starting one.
