#!/bin/zsh
# Runs the test suite. The Command Line Tools ship Swift Testing outside the default search
# paths, so point the compiler and linker at it (not needed with full Xcode).
set -euo pipefail
cd "${0:A:h}/.."

flags=()
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d $CLT/Frameworks/Testing.framework ]]; then
  flags=(-Xswiftc -F$CLT/Frameworks -Xlinker -F$CLT/Frameworks
         -Xlinker -rpath -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/usr/lib)
fi
swift test "${flags[@]}" "$@"
