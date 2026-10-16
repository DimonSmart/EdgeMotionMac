#!/usr/bin/env bash
set -euo pipefail

# Build a universal SwiftPM executable and wrap it in a background macOS .app.
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 MAJOR.MINOR.PATCH OUTPUT_DIRECTORY" >&2
  exit 2
fi

version="$1"
output_dir="$2"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version: $version" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app="$output_dir/EdgeMotion.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

build_root="$output_dir/swift-build"
for arch in arm64 x86_64; do
  scratch="$build_root/$arch"
  swift build --configuration release --product EdgeMotion --arch "$arch" --scratch-path "$scratch"
  bin_dir="$(swift build --configuration release --arch "$arch" --scratch-path "$scratch" --show-bin-path)"
  binary="$bin_dir/EdgeMotion"
  if [[ ! -f "$binary" ]]; then
    echo "Missing EdgeMotion executable for $arch: $binary" >&2
    exit 1
  fi
  actual_archs="$(/usr/bin/lipo -archs "$binary")"
  if [[ "$actual_archs" != "$arch" ]]; then
    echo "Expected $arch executable, got: $actual_archs" >&2
    exit 1
  fi
  if [[ "$arch" == arm64 ]]; then arm_binary="$binary"; else intel_binary="$binary"; fi
done

/usr/bin/lipo -create "$arm_binary" "$intel_binary" -output "$app/Contents/MacOS/EdgeMotion"
chmod 755 "$app/Contents/MacOS/EdgeMotion"
/usr/bin/lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/EdgeMotion"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>EdgeMotion</string>
  <key>CFBundleIdentifier</key><string>io.github.dimonsmart.EdgeMotion</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>EdgeMotion</string>
  <key>CFBundleDisplayName</key><string>EdgeMotion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$app/Contents/Info.plist"
echo "Built universal app: $app"
