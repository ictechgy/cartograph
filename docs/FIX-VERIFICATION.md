# Optional verification for mechanical fixes

`fix` plans mechanical edits by default. `fix --apply` keeps its existing parse-checked,
per-file atomic writes. To check the edited project with one command and recover this
run's edits on failure, explicitly select verification:

```sh
cartograph fix --apply \
  --verify-command '["swift","build","--build-tests"]' \
  --verify-timeout 600 \
  --recovery-directory /tmp/my-new-fix-review
```

For Xcode, pass the complete scheme, destination and configuration arguments appropriate
for your project. A passing command establishes only what that command checks; it does
not establish every target, platform or private application configuration.

## Execution contract

- `--verify-command` is a JSON array of strings containing the executable and each argument.
  Cartograph passes these arguments directly, without interpreting shell expansion, quoting,
  pipelines or substitutions. Select an explicit script or interpreter when needed.
- Verification requires `--apply`. `--verify-timeout` and `--recovery-directory` require
  `--verify-command`. Empty argv, empty executable, NUL bytes and nonfinite or out-of-range
  timeouts are usage errors (64), before analysis or execution. Timeouts are 0.1–86400 seconds;
  the default is 600 seconds.
- The command runs at the physical project root and inherits the CLI's environment, including
  `PATH`. Two additional variables identify local evidence: `CARTOGRAPH_FIX_PROJECT` and
  `CARTOGRAPH_FIX_RECOVERY_DIRECTORY`. Environment values are not recorded in the journal.
  Standard input is `/dev/null`; stdout and stderr each have a 1 MiB retained-output budget.
- This is an explicit trusted-command execution facility, not a sandbox. A verifier can run
  build tools and modify other files. Its Git operations, generated files, dependency lockfiles,
  caches and other side effects are outside the source rollback contract.
- Only the verifier's newly created process group receives termination signals on timeout,
  interruption or excessive output. Cartograph sends TERM, then KILL after 100 ms to that group.
  A verifier leaving background children is a verification failure. Existing processes in other
  groups are not targeted. A hostile command escaping the group is outside this contract.

## Apply and recovery contract

Before writing anything, Cartograph rechecks all planned files against the exact bytes used
to calculate the edit. Verified application requires regular files physically inside the
project. It retains original bytes and POSIX modes in a new private directory outside the
project. Existing recovery directories are refused. The directory is mode 0700; backups,
journal and logs are mode 0600. The default directory is a unique system temporary directory.
Verified application is bounded to 10000 files and 64 MiB of original source; exceeding either
bound fails before writing source and requires a narrower scope.

The journal `recovery.json` identifies each file, its backup, original and replacement SHA256,
mode and whether a write was attempted. The selected command then sees the applied edits.
Successful verification keeps the edits. A write error, nonzero command exit, launch error,
timeout, output overflow, SIGINT or SIGTERM fails the run and attempts recovery.

Recovery compares the current bytes and file identity with the bytes and identity Cartograph
recorded immediately after writing. It restores only an unchanged Cartograph-owned edit.
If a verifier or another editor changes, replaces, removes or redirects that file, Cartograph
preserves the new state, retains the original backup, reports the conflict or restore failure,
and exits 2. It never uses `git reset`, `git stash`, `git checkout` or rewrites the index. Preexisting
staged, unstaged, untracked and ignored files therefore remain available; arbitrary Git changes
performed by the selected verifier are not undone.

Multi-file writes are not an operating-system-wide atomic transaction. Keep other edits idle
while applying. SIGKILL, power loss or a crash cannot run automatic recovery; retained evidence
is available for manual review and is not a claim of crash-safe durability. Byte content and
POSIX modes are restored; inode, timestamps, ACLs and extended attributes are not promised.

## Reading the result

`--format json` keeps the `mechanical-fixes` v1 document and adds an optional `verification`:

```json
{
  "status": "failed",
  "exitCode": 1,
  "rollback": "restored",
  "recoveryDirectory": "/private/tmp/my-fix-evidence",
  "detail": "Verification exited 1."
}
```

The normal result omits this field when verification was not selected. `passed` means the
selected command exited zero and the owned source edits remained unchanged. Failure exits 2
regardless of `--strict`; successful verification preserves the existing skipped-fix/strict
contract. Signal interruption also exits 2 after recovery, with the signal recorded in JSON.

`rollback: restored` means all attempted edits were restored or already held their original
bytes. `conflict`, `restore-failed` or `conflict-and-restore-failed` requires manual inspection.
The document's `applied` flag can remain true when partial conflicting edits are retained;
always inspect verification and rollback status together. Recovery evidence is retained after
success too; remove it when review is complete. It may contain private source and command logs.

For manual recovery, first preserve the current file separately, inspect `recovery.json`, and
compare the current file with its recorded replacement SHA256. Read the named original backup
before deciding what to restore. Cartograph does not silently copy a backup over a conflicting
current file. The command's own stdout/stderr logs help distinguish build failures from source
conflicts. A failure to write the final journal is explicitly reported alongside rollback status.

The local harness `Scripts/verify-fix-verification.py` compiles a public `.magic` extension
fixture and verifies success, actual build failure, timeout, SIGINT/SIGTERM, conflict and
restore failure against a staged/unstaged Git worktree. It does not use private application code.
