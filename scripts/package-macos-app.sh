#!/usr/bin/env bash
set -euo pipefail

# Build a universal SwiftPM executable and wrap it in a background macOS .app.
development_signing=false
if [[ "${1:-}" == --development ]]; then
  development_signing=true
  shift
fi
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 [--development] MAJOR.MINOR.PATCH OUTPUT_DIRECTORY" >&2
  exit 2
fi

version="$1"
output_dir="$2"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version: $version" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
signing_identity=''
if [[ "$development_signing" == true ]]; then
  signing_config="$PWD/LocalSigning.xcconfig"
  if [[ ! -f "$signing_config" ]]; then
    echo 'Debug signing is not configured. Run scripts/setup-dev-signing.sh once first.' >&2
    exit 1
  fi
  identity_count="$(awk '/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=/ { count++ } END { print count+0 }' "$signing_config")"
  if [[ "$identity_count" != 1 ]]; then
    echo 'LocalSigning.xcconfig must contain exactly one CODE_SIGN_IDENTITY fingerprint.' >&2
    exit 1
  fi
  signing_identity="$(awk -F= '/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=/ { value=substr($0, index($0, "=")+1); sub(/[[:space:]]*#.*/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' "$signing_config")"
  if [[ ! "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo 'CODE_SIGN_IDENTITY must be a 40-character certificate SHA-1 fingerprint.' >&2
    exit 1
  fi
  available_identities="$(security find-identity -p codesigning)"
  if ! awk -v identity="$signing_identity" '$2 == identity { found=1 } END { exit !found }' <<<"$available_identities"; then
    echo "Configured signing identity $signing_identity is unavailable in the Keychain. Run scripts/setup-dev-signing.sh after checking the local config." >&2
    exit 1
  fi
fi

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
merged_archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/EdgeMotion")"
if [[ "$merged_archs" != "arm64 x86_64" && "$merged_archs" != "x86_64 arm64" ]]; then
  echo "Expected universal arm64/x86_64 executable, got: $merged_archs" >&2
  exit 1
fi

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
if [[ "$development_signing" == true ]]; then
  /usr/bin/codesign --force --sign "$signing_identity" --identifier io.github.dimonsmart.EdgeMotion --timestamp=none "$app"
  /usr/bin/codesign --verify --deep --strict "$app"
  signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
  if [[ "$signature" == *'Signature=adhoc'* || "$signature" != *'Authority='* ]]; then
    echo 'Debug app did not use the configured persistent signing identity.' >&2
    exit 1
  fi
  echo "Built persistently signed universal developer app: $app"
else
  echo "Built unsigned universal app: $app"
fi
