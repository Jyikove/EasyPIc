#!/bin/zsh
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
sdk_path="$(xcrun --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
# A standalone harness works with Command Line Tools, without requiring Xcode/XCTest.
swift run --sdk "$sdk_path" EasyPicChecks
