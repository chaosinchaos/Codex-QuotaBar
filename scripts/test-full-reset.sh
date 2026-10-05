#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
test_directory="$(mktemp -d /private/tmp/quotabar-tests.XXXXXX)"
swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target arm64-apple-macosx14.0 -module-cache-path "$test_directory/modules" \
  "$quota_root/Xcode/CodexQuotaBar/FullResetSupport.swift" \
  "$quota_root/Tests/FullResetSupportTests.swift" -o "$test_directory/tests"
"$test_directory/tests" "$@"
