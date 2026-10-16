# EdgeMotion release setup

EdgeMotion is published as an **unsigned and unnotarized** macOS app via GitHub Releases, as CSharpFar is. No Apple Developer account, certificate, App Store Connect API key, or signing-related GitHub secrets are required.

## Repository configuration

- Enable GitHub Actions.
- The release workflow uses the built-in GitHub token with `contents: write` to publish a Release and update `Casks/edgemotion.rb` on `main`. Ensure repository Actions settings permit this, and allow the bot's Cask commit if `main` has branch protection.
- The workflow runs on a macOS runner. It builds and tests the package, assembles a universal arm64/x86_64 `EdgeMotion.app`, archives it with `ditto`, and publishes a SHA-256 checksum. It does not sign, notarize, or staple the app.

## Publishing the next version

1. Merge changes into `main`; verify CI is green.
2. Run `pwsh ./publish-next-version.ps1` from a clean local checkout, using PowerShell 7 and Git.
3. The script fast-forwards `main`, creates and pushes a tag like `v0.1.0` (or the next patch version), which starts the Release workflow. You may use `-Bump Minor` or `-Bump Major`.
4. Check the [Release workflow](https://github.com/DimonSmart/EdgeMotionMac/actions/workflows/release.yml) and the [Release page](https://github.com/DimonSmart/EdgeMotionMac/releases) for `EdgeMotion-vX.Y.Z-macos-universal.zip` and `SHA256SUMS.txt`.
5. Verify `Casks/edgemotion.rb` on `main` was updated with that version and checksum, then test the package on a physical MacBook.

The Cask is created only after the first successful Release, so it does not reference a nonexistent download. If updating the Cask fails after publishing, re-run the Release workflow; it will replace existing Release assets and try the Cask update again.

## Homebrew installation

Use this repository as its own tap (the explicit URL is necessary because this repository is not named `homebrew-edgemotion`):

```bash
brew tap dimonsmart/edgemotion https://github.com/DimonSmart/EdgeMotionMac.git
brew install --cask dimonsmart/edgemotion/edgemotion
```

To upgrade: `brew update && brew upgrade --cask dimonsmart/edgemotion/edgemotion`.

## Gatekeeper: first launch of an unsigned app

**Homebrew cannot give an unsigned app Apple's Developer ID trust.** After a normal installation, macOS may block the initial launch. If you trust the app, attempt to open it, then choose **System Settings → Privacy & Security → Open Anyway**. Grant Accessibility permission to the installed app separately.

The [optional macOS installer](install-macos.sh) installs or upgrades through Homebrew, then removes `com.apple.quarantine` **only from /Applications/EdgeMotion.app**. This bypasses macOS's download assessment for that app; review the script and trust the release before running it. If macOS labels the app damaged despite a verified download, a trusted manual installation may need:

```bash
xattr -dr com.apple.quarantine /Applications/EdgeMotion.app
```

Never disable Gatekeeper or SIP globally. EdgeMotion does not require root privileges or drivers. Notarization would not prove compatibility with the undocumented private MultitouchSupport input API; on unsupported devices, the app must remain safely disabled.
