# EdgeMotion release setup

## One-time configuration

A paid Apple Developer account, a **Developer ID Application** certificate exported as a password-protected PKCS#12 (.p12), and an App Store Connect API key authorized for notarization are required. In **Settings → Secrets and variables → Actions**, configure:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64-encoded contents of the Developer ID Application .p12 |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password for that .p12 |
| `APPLE_DEVELOPER_ID_IDENTITY` | Exact identity shown by `security find-identity -v -p codesigning`, e.g. Developer ID Application: ... |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer ID |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded contents of the AuthKey_*.p8 private key |

To encode a key or certificate on macOS without line breaks: `base64 < file.p12 | tr -d '\n'` (substitute the key file as appropriate). Keep private keys and certificate passwords out of Git.

Ensure GitHub Actions is enabled and workflow `GITHUB_TOKEN` can write repository contents. A protected `main` branch must allow GitHub Actions to commit `Casks/edgemotion.rb`, or the final Cask update will fail even if the Release was uploaded. The release job must run on a macOS runner with Xcode, codesign, and notarytool.

## Publish

1. Merge the desired code to `main` and confirm CI passes.
2. On your Mac, run `pwsh ./publish-next-version.ps1` in the clean repository.
3. Verify the **Release** GitHub Actions run finishes successfully.
4. Check the new GitHub Release contains `EdgeMotion-vX.Y.Z-macos-universal.zip` and `SHA256SUMS.txt`.
5. Confirm `Casks/edgemotion.rb` was committed to `main` with the new version and digest.
6. On a supported Mac, install through Homebrew and grant **Accessibility** to the bundled app. Qualify raw touch behavior separately on each supported hardware/OS combination.

The packaging script can be exercised by CI without secrets, but official GitHub releases require real Developer ID signing and notarization. The workflow never publishes an unsigned archive.

The initial Homebrew Cask is intentionally generated only after a successful release, so it never contains a placeholder checksum. The repository itself is used as a Homebrew tap with an explicit URL:

```bash
brew tap dimonsmart/edgemotion https://github.com/DimonSmart/EdgeMotionMac.git
brew install --cask dimonsmart/edgemotion/edgemotion
```

This explicit URL is essential: by default Homebrew expects `dimonsmart/homebrew-edgemotion`, whereas the actual repository is `DimonSmart/EdgeMotionMac`.

The package targets macOS 11+ and includes x86_64 and arm64 binaries. Successful compilation and notarization do **not** establish compatibility of the private MultitouchSupport ABI. The functionality must be validated on real devices before a public release.
