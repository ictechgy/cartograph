# Observation window corpus

A process that ignores SIGTERM and does not voluntarily exit must still produce a sealed, usable
observation interval. That interval does not establish application or scenario success.

`Scripts/verify-runtime-window.py --cartograph <binary>` checks the CLI and artifact reader with a
real compiler index. Early exit and truncated runtime names remain incomplete. Its independent
native wire probe keeps running after the seal, verifies that late events cannot cross the boundary,
and checks nonce/PID rejection. The probe comes from the Simulator limitation that simctl success
and forced GUI termination cannot prove a scenario completed.
