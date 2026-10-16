![EdgeMotion — miniature skateboarder on a MacBook trackpad](assets/social-preview.jpg)

# EdgeMotion

**Out of trackpad? Not out of screen.** Keep your Mac cursor moving beyond the edge.

EdgeMotion is a lightweight macOS menu-bar utility that continues pointer motion when you reach the edge of a built-in MacBook trackpad. It uses macOS Accessibility permission for synthetic cursor movement and accesses Apple's private MultitouchSupport framework for touch input.

## Install with Homebrew

After the first [GitHub Release](https://github.com/DimonSmart/EdgeMotionMac/releases) has been published:

```bash
brew tap dimonsmart/edgemotion https://github.com/DimonSmart/EdgeMotionMac.git
brew install --cask dimonsmart/edgemotion/edgemotion
```

**Unsigned download:** macOS may block the first launch. If you trust the release, use **System Settings → Privacy & Security → Open Anyway** after trying to open it. The [optional macOS installation script](docs/install-macos.sh), modeled on CSharpFar, uses Homebrew and removes quarantine **only from `/Applications/EdgeMotion.app`**; review the script before running it.

Launch **EdgeMotion** from Applications. The utility runs in the menu bar rather than the Dock. Grant it **Accessibility** access under **System Settings → Privacy & Security → Accessibility**, then enable EdgeMotion from its menu-bar control. Left-click the menu-bar icon to toggle; right-click for the menu.

To update or remove it:

```bash
brew update
brew upgrade --cask dimonsmart/edgemotion/edgemotion
brew uninstall --cask dimonsmart/edgemotion/edgemotion
```

Release archives also support manual installation: download the universal .zip, extract, and move EdgeMotion.app to Applications. The same Gatekeeper warning may apply. A successful build does not guarantee compatibility with every hardware/OS combination; the private input API is undocumented and fails safely when unavailable.

## Developer build

Requires macOS and Xcode command-line tools.

```bash
swift test --configuration release
swift run EdgeMotion
```

Build an unsigned universal app bundle for inspection:

```bash
bash scripts/package-macos-app.sh 0.1.0 /tmp/edgemotion-package
```

Running directly from Terminal and running EdgeMotion.app use different Accessibility permission identities.

## Hardware feasibility diagnostic

`EdgeMotionHardwareDiagnostic` is a separate, non-sandboxed harness and is not a substitute for device qualification.

```bash
swift run EdgeMotionHardwareDiagnostic --seconds=12 --sample
```

Run from an interactive login session on a physical MacBook. Keep another application in the foreground while testing touch/movement. The diagnostic reports frame counts and validity; it does not save raw touch streams. On unsupported inputs, **SAFE DISABLED** is expected and no synthetic output is sent. No root, SIP changes, driver replacement, or kernel extension is needed.

## Release process

CI builds/tests Swift sources and checks that the packaged app contains arm64 and x86_64. Releases are **unsigned and unnotarized**, like CSharpFar, and require no Apple Developer certificate or Apple-specific GitHub secrets. The tag workflow publishes the universal `.app` and SHA-256 checksum on GitHub Releases, then commits an updated Homebrew Cask to `main`.

On a Mac with Git and PowerShell installed:

```powershell
pwsh ./publish-next-version.ps1
```

The script increments the patch version by default, or use `-Bump Minor` / `-Bump Major`. It requires a clean tree, fast-forwards `main`, creates an annotated `vMAJOR.MINOR.PATCH` tag, and pushes that tag to trigger the release pipeline. The first tag defaults to `v0.1.0`.

See [Release setup](docs/releasing.md) for required GitHub workflow permissions and unsigned-app installation notes. **No release has been published by this configuration alone.**

## Update from About

Open the EdgeMotion menu-bar menu (right-click its icon) and choose **About EdgeMotion**.
The About window checks the latest stable GitHub Release when opened.
For a standard Homebrew-managed /Applications/EdgeMotion.app installation, a newer release offers **Update now**. EdgeMotion runs a targeted Homebrew Cask update, verifies the installed app, removes quarantine from that unsigned app only, and restarts. Manual ZIP installations and developer builds can open the release page instead; they are never silently replaced.

An offline GitHub check or an unavailable Homebrew package does not stop cursor operation. The updater does not require an Apple Developer certificate. Because EdgeMotion is unsigned, you may need to re-enable **Accessibility** after a version change.

## Limitations and privacy

EdgeMotion uses an undocumented Apple framework, so future macOS updates may disable raw touch input. The app does not transmit touch coordinates, record key presses, or run a network service. The GitHub source and the [IDD product specifications](.idd/intent/INDEX.md) describe the remaining limitations and safety requirements.
