# Compiler help privacy regression corpus

Complete help output captured from the installed official Swift 6.4 Debian 12 toolchain, without
rewriting output bytes. The manifest pins each compiler and help file hash, command and version;
only the installed directory in version metadata is replaced by `$TOOLCHAIN`. The directory-local
Git whitespace attribute preserves original trailing spaces in the Clang stdout fixture; its full
byte hash is checked by the privacy test. No source-code whitespace rule is relaxed.

This is a Linux normalization regression corpus, not macOS execution or comparative evidence.
Two macOS CI failures have matching fingerprints for fixed lexical help tokens: Clang's
`/showIncludes` option, and Swift's `<directory>/default.profraw` example. Auditing both complete
help outputs also finds the `C/C++/Objective-C` language spelling. Exact artifact/description contexts
are tested; suffix paths, adjacent private paths and credentials still block publication.
Other compiler versions or text remain fail-closed. The complete macOS help corpus is not available
from the blocked prior bundles, so a successful local smoke does not certify every native help line.
