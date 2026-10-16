#!/usr/bin/env bash
set -euo pipefail

# Optional unsigned-app installer, analogous to CSharpFar's install-macos.sh.
# Explicitly clears quarantine for /Applications/EdgeMotion.app only.

tap="dimonsmart/edgemotion"
cask="dimonsmart/edgemotion/edgemotion"
app="/Applications/EdgeMotion.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The installer requires macOS." >&2
  exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh/" >&2
  exit 1
fi

brew="$(command -v brew)"
if ! "$brew" tap | grep -Fxq "$tap"; then
  "$brew" tap "$tap" "https://github.com/DimonSmart/EdgeMotionMac.git"
fi
"$brew" update
if "$brew" list --cask --versions "$cask" >/dev/null 2>&1; then
  "$brew" upgrade --cask --appdir=/Applications "$cask"
else
  if [[ -e "$app" ]]; then
    echo "EdgeMotion.app exists but is not managed by Homebrew. Move it first." >&2
    exit 1
  fi
  "$brew" install --cask --appdir=/Applications "$cask"
fi

if [[ ! -x "$app/Contents/MacOS/EdgeMotion" ]]; then
  echo "Homebrew reported success but the EdgeMotion executable is missing." >&2
  exit 1
fi

# Only remove this app's quarantine; never change system Gatekeeper or SIP.
if /usr/bin/xattr -r -l "$app" 2>/dev/null | grep -Fq com.apple.quarantine; then
  echo "Removing quarantine from this unsigned, unnotarized EdgeMotion.app."
  /usr/bin/xattr -dr com.apple.quarantine "$app"
fi
if /usr/bin/xattr -r -l "$app" 2>/dev/null | grep -Fq com.apple.quarantine; then
  echo "Quarantine is still present; see README for first-launch instructions." >&2
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
echo "Installed EdgeMotion $version in /Applications."
echo "Launch the app and grant Accessibility permission in System Settings."
