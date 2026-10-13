# Prospective interpreter binding for the existing single installation

This isolated draft changes only the existing native measurement installer. The original source is
retained as installer-original.py; installer-successor.py is the proposed replacement. It runs the
same pip command once, with the same private target/report and unchanged provenance projection.

Immediately before that command, it captures the selected interpreter spelling, resolved regular
file, SHA256/size and device/inode/mode/size/mtime/ctime identity. Reading is bounded to 256 MiB,
nonblocking and no-follow after explicit resolution; pre/post fstat, path identity and selected
alias resolution must agree. Failed/interrupt captures retain a typed outcome and cost without a
partial content digest. No loader closure or atomic/adversarial filesystem snapshot is claimed.

A normally completed installation, including exit 9, receives a terminal identity capture. Changed
or unavailable identity prevents subsequent test/machine/calibration phases. An incomplete command
keeps terminal identity unavailable and preserves its original phase exit; reserved 125 stays
incomplete. The new setup/install-interpreter.json is duplicated in results.json so integration can
require exact agreement. Both individual capture costs are nested in existing diagnostic wall and
outside the command-only installation interval. Final result serialization remains covered by the
existing outer process measurement in the eventual integration.

This is prospective evidence only. Earlier native rounds lack install-time interpreter identities;
their retained artifacts are not changed or retroactively upgraded. Official wheel-to-installed-tree
matching and complete Python/OS dynamic-loader closure remain separate limitations.

Validation: 13 new controls pass, including actual current interpreter reading, FIFO refusal,
read mutation/alias retargeting, missing inputs, capture interruption, one-install success,
completed/incomplete failures and no-next-phase guards. All 21 existing installer/publication
contracts pass against the successor in a copied source layout. No new installation or native
macOS run was performed. Existing failed attempts are retained locally.
