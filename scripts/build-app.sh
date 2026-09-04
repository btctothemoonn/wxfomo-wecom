#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/wxFomo.app"
contents_dir="$app_dir/Contents"
binary_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

cd "$project_dir"
swift build -c release --product wxfomo-gui

mkdir -p "$binary_dir"
mkdir -p "$resources_dir"
cp "$project_dir/.build/release/wxfomo-gui" "$binary_dir/wxfomo-gui"
cp "$project_dir/Assets/AppIcon.icns" "$resources_dir/AppIcon.icns"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>wxFomo</string>
  <key>CFBundleExecutable</key>
  <string>wxfomo-gui</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.wxfomo</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>wxFomo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "com.local.wxfomo"' \
  "$app_dir"
echo "$app_dir"
