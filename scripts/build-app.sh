#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
output="$root/dist/CodexQuotaBar.app"
binary="$root/.build/release/CodexQuotaBar"
module_cache="$root/.build/module-cache"
sdk="$(xcrun --sdk macosx --show-sdk-path)"

# Some macOS beta Command Line Tools installations pair the current Swift compiler
# with the previous stable SDK. Prefer it when it is available so local builds work.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi

cd "$root"
SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$module_cache" SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" swift build --disable-sandbox -c release

rm -rf "$output"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$binary" "$output/Contents/MacOS/CodexQuotaBar"
cp "$root/Resources/Info.plist" "$output/Contents/Info.plist"

xattr -cr "$output"
codesign --force --sign - "$output"
xattr -cr "$output"
echo "Built: $output"
