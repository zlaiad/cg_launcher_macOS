#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p work
swiftc -O -D STANDALONE_CHECKS Sources/CGLauncherCore/*.swift Tests/CGLauncherCoreTests/ProtocolTests.swift -o work/ProtocolChecks
work/ProtocolChecks
