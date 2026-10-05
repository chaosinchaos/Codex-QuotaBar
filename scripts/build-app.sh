#!/bin/zsh
set -euo pipefail

quota_root="${0:A:h:h}"
output="$quota_root/dist/CodexQuotaBar.app"
binary="$quota_root/.build/release/CodexQuotaBar"
module_cache="$quota_root/.build/module-cache"
if [[ -x /Library/Developer/CommandLineTools/usr/bin/swift ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"

cd "$quota_root"
SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$module_cache" SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" swift build --disable-sandbox --cache-path "$quota_root/.build/cache" --config-path "$quota_root/.build/config" --security-path "$quota_root/.build/security" -c release

if [[ -d "$output" ]]; then
  mv "$output" "$quota_root/dist/CodexQuotaBar-backup-$(date +%Y%m%d%H%M%S).app"
fi
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$binary" "$output/Contents/MacOS/CodexQuotaBar"
cp "$quota_root/Xcode/CodexQuotaBar/CodexQuotaBar-Info.plist" "$output/Contents/Info.plist"
cp "$quota_root/Xcode/CodexQuotaBar/AppIcon.icns" "$output/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion en' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable CodexQuotaBar' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.codex.CodexQuotaBarIconV3' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName CodexQuotaBar' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundlePackageType APPL' "$output/Contents/Info.plist"

xattr -cr "$output"
codesign --force --sign - "$output"
xattr -cr "$output"
echo "Built: $output"
