![EdgeMotion — miniature skateboarder on a MacBook trackpad](assets/social-preview.jpg)

# EdgeMotion

**Out of trackpad? Not out of screen.** Keep your Mac cursor moving beyond the edge.

EdgeMotion is a lightweight macOS menu-bar utility that continues pointer motion when you reach the edge of a built-in MacBook trackpad. It uses macOS Accessibility permission for synthetic cursor movement and accesses Apple's private MultitouchSupport framework for touch input.

## Install with Homebrew

After the first signed and notarized [GitHub Release](https://github.com/DimonSmart/EdgeMotionMac/releases) has been published:

\`\`\`bash
brew tap dimonsmart/edgemotion https://github.com/DimonSmart/EdgeMotionMac.git
brew install --cask dimonsmart/edgemotion/edgemotion
\`\`\`

Launch **EdgeMotion** from Applications. The utility runs in the menu bar rather than the Dock. Grant it **Accessibility** access under **System Settings → Privacy & Security → Accessibility**, then enable EdgeMotion from its menu-bar control. Left-click the menu-bar icon to toggle; right-click for the menu.

To update or remove it:

\`\`\`bash
brew update
brew upgrade --cask dimonsmart/edgemotion/edgemotion
brew uninstall --cask dimonsmart/edgemotion/edgemotion
\`\`\`

Release archives also support manual installation: download the universal .zip, extract, and move EdgeMotion.app to Applications. A successful build does not guarantee compatibility with every hardware/OS combination; the private input API is undocumented and fails safely when unavailable.

## Developer build

Requires macOS and Xcode command-line tools.

\`\`\`bash
swift test --configuration release
swift run EdgeMotion
\`\`\`

Build an unsigned universal app bundle for inspection:

\`\`\`bash
bash scripts/package-macos-app.sh 0.1.0 /tmp/edgemotion-package
\`\`\`

Running directly from Terminal and running EdgeMotion.app use different Accessibility permission identities.

## Hardware feasibility diagnostic

\`EdgeMotionHardwareDiagnostic\` is a separate, non-sandboxed harness and is not a substitute for device qualification.

\`\`\`bash
swift run EdgeMotionHardwareDiagnostic --seconds=12 --sample
\`\`\`

Run from an interactive login session on a physical MacBook. Keep another application in the foreground while testing touch/movement. The diagnostic reports frame counts and validity; it does not save raw touch streams. On unsupported inputs, **SAFE DISABLED** is expected and no synthetic output is sent. No root, SIP changes, driver replacement, or kernel extension is needed.

## Release process

CI builds/tests Swift sources and checks that the packaged app contains arm64 and x86_64. Releases require **Developer ID signing, Hardened Runtime, Apple notarization, and stapling**. The tag workflow publishes the universal app and its checksum, then commits an updated Homebrew Cask to \`main\`. It deliberately fails without Apple credentials and does not publish an unsigned fallback.

On a Mac with Git and PowerShell installed:

\`\`\`powershell
pwsh ./publish-next-version.ps1
\`\`\`

The script increments the patch version by default, or use \`-Bump Minor\` / \`-Bump Major\`. It requires a clean tree, fast-forwards \`main\`, creates an annotated \`vMAJOR.MINOR.PATCH\` tag, and pushes that tag to trigger the release pipeline. The first tag defaults to \`v0.1.0\`.

Repository maintainers must add the six GitHub Actions secrets described in [Release setup](docs/releasing.md) before pushing a release tag. **No release has been published by this configuration alone.**

## Limitations and privacy

EdgeMotion uses an undocumented Apple framework, so future macOS updates may disable raw touch input. The app does not transmit touch coordinates, record key presses, or run a network service. The GitHub source and the [IDD product specifications](.idd/intent/INDEX.md) describe the remaining limitations and safety requirements.
