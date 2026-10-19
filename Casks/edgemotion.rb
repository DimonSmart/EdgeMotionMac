cask "edgemotion" do
  version "0.1.0"
  sha256 "c9125fd373e64fe281f768a86189d67e71e1ea5a2a8846811413ba5ad0c91e7d"

  url "https://github.com/DimonSmart/EdgeMotionMac/releases/download/v#{version}/EdgeMotion-v#{version}-macos-universal.zip"
  name "EdgeMotion"
  desc "Keep the macOS pointer moving after reaching the trackpad edge"
  homepage "https://github.com/DimonSmart/EdgeMotionMac"

  depends_on macos: ">= :big_sur"

  app "EdgeMotion.app"

  caveats <<~EOS
    EdgeMotion is not Developer ID signed or notarized by Apple.
    macOS Gatekeeper may block the first launch. If you trust this download,
    use System Settings > Privacy & Security > Open Anyway.

    The app requires Accessibility permission to move the pointer.
    See https://github.com/DimonSmart/EdgeMotionMac/blob/main/docs/install-macos.sh
    for an optional Homebrew installer that removes quarantine from this app only.
  EOS
end
