#!/bin/zsh
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
signing_identity="$("$project_dir/scripts/signing-identity.sh")"
# Use the installed 26.x SDK when available, while targeting macOS 26.0.
sdk_path="$(xcrun --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build -c release --sdk "$sdk_path"
binary_dir="$(swift build -c release --sdk "$sdk_path" --show-bin-path)"
app_dir="$project_dir/build/EasyPic.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/EasyPic" "$app_dir/Contents/MacOS/EasyPic"
cp "$project_dir/scripts/Info.plist" "$app_dir/Contents/Info.plist"
cp -R "$project_dir/Assets/Localization/"*.lproj "$app_dir/Contents/Resources/"
swift -sdk "$sdk_path" "$project_dir/scripts/make-assets.swift" "$project_dir"
iconutil -c icns "$project_dir/build/EasyPic.iconset" -o "$app_dir/Contents/Resources/EasyPicIcon.icns"
rm -f "$app_dir/Contents/Resources/EasyPic.icns"
codesign --force --deep --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
touch "$app_dir"
echo "已生成 $app_dir"
