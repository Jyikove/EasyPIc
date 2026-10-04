#!/bin/zsh
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
sdk_path="$(xcrun --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    sdk_path=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build -c release --sdk "$sdk_path"
binary_dir="$(swift build -c release --sdk "$sdk_path" --show-bin-path)"
"$binary_dir/EasyPicChecks" --viewer-checks
mkdir -p build/ViewerChecks
live_fixture_dir="$(mktemp -d "$project_dir/build/ViewerChecks/LivePhotos.XXXXXX")"
"$binary_dir/EasyPicChecks" --live-fixtures "$live_fixture_dir"
# Compile the actual app model and views without launching an application window.
# Removing only the app entry annotation lets the model-check runner own main.
sed '/^@main$/d' Sources/EasyPic/EasyPicApp.swift > build/ViewerChecks/WindowSupport.swift
app_sources=(Sources/EasyPic/*.swift)
app_sources=(${app_sources:#Sources/EasyPic/EasyPicApp.swift})
if [[ -f "$binary_dir/EasyPicCore.o" ]]; then
    core_objects=("$binary_dir/EasyPicCore.o")
    module_dir="$binary_dir"
else
    core_objects=("$binary_dir"/EasyPicCore.build/*.o)
    module_dir="$binary_dir/Modules"
fi
target_arch="$(uname -m)"
swiftc -parse-as-library -O -target "${target_arch}-apple-macosx26.0" -sdk "$sdk_path" -I "$module_dir" \
    "${app_sources[@]}" build/ViewerChecks/WindowSupport.swift \
    Tests/EasyPicViewerChecks/*.swift "${core_objects[@]}" \
    -o build/ViewerChecks/EasyPicViewerChecks
build/ViewerChecks/EasyPicViewerChecks "$live_fixture_dir"
