cask "edgemotion" do
  version "0.1.1"
  sha256 "f78a63c4fdec15aba1ceac1c232c08eaec74b2a26d92a0f791adb9cd3566f7da"

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
