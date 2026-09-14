#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p work
swiftc -O -target "$(uname -m)-apple-macos13.0" -D STANDALONE_MODEL_CHECKS Sources/CGLauncherCore/*.swift Sources/CGLauncher/LauncherUI.swift scripts/ModelChecks.swift -o work/ModelChecks
work/ModelChecks
