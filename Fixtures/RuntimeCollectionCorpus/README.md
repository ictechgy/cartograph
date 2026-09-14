# Runtime collection corpus

This executable is the real Foundation/Objective-C runtime fixture for `cartograph runtime collect`.
It originated from the macOS interposition prototype used to validate automatic runtime evidence.

The fixture covers successful and failed class/protocol lookup, selector token creation, the zero/one/two argument
`performSelector` variants, class receiver invocation, and selector-based `NotificationCenter` registration. It also
launches itself as a child process; the child's unique lookup must not be attributed to the parent trace.

The verification script compares application stdout and stderr with and without collection. This catches hooks that
observe the right event but change application behaviour.
