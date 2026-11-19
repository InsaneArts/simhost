#!/bin/sh
# Builds the probe app for the simulator: Probe/build/Probe.app.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
version=$(xcrun --sdk iphonesimulator --show-sdk-version)
app="$here/build/Probe.app"
rm -rf "$app" && mkdir -p "$app"
xcrun --sdk iphonesimulator swiftc -parse-as-library -O \
    -target "$(uname -m)-apple-ios$version-simulator" -sdk "$sdk" \
    -o "$app/Probe" "$here/Probe.swift"
cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.simhost.probe</string>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$version</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIRequiresFullScreen</key><true/>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
  </dict>
</dict></plist>
PLIST
codesign -s - "$app" >/dev/null 2>&1
echo "$app"
