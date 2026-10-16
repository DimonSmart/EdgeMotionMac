import AppKit
import CoreGraphics
import EdgeMotionCore
import EdgeMotionDiagnosticBridge
import EdgeMotionDiagnosticCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = EdgeMotionEngine()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var timer: Timer?
    private var lastSequence: Int64?
    private var latestInputTimestamp: TimeInterval?
    private var enabled = false
    private var diagnosticItem: NSMenuItem!
    private var receivedFrames = 0
    private var postedMoves = 0
    private var lastState: EdgeMotionState = .idle
    private let logger = Logger(subsystem: "com.edgemotion.app", category: "runtime")

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDelegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.up.right.circle", accessibilityDescription: "EdgeMotion")
        statusItem.button?.toolTip = "EdgeMotion — disabled"
        statusItem.isVisible = true
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "Enable EdgeMotion", action: #selector(toggle), keyEquivalent: "e")
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = [.option, .command]
        diagnosticItem = menu.addItem(withTitle: "Diagnostics: disabled", action: nil, keyEquivalent: "")
        diagnosticItem.isEnabled = false
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit EdgeMotion", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusItem.menu = menu
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func toggle() {
        enabled ? disable() : enable()
    }

    private func enable() {
        guard QuartzDiagnosticOutput.isAccessibilityTrusted else {
            let alert = NSAlert(); alert.messageText = "Accessibility permission is required"; alert.informativeText = "Allow EdgeMotion in System Settings before enabling cursor motion."; alert.runModal()
            return
        }
        guard EMBridgePrepare() == EMBridgeReady else { showBridgeError(); return }
        guard EMBridgeStartBuiltIn(multitouchCallback, nil) else { showBridgeError(); return }
        enabled = true
        receivedFrames = 0; postedMoves = 0; lastState = .idle
        toggleItem.title = "Disable EdgeMotion"
        statusItem.button?.toolTip = "EdgeMotion — enabled"
        diagnosticItem.title = "Diagnostics: waiting for touch frames"
        logger.notice("enabled")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.moveCursor() }
    }

    private func disable() {
        enabled = false; engine.stop(); lastSequence = nil; latestInputTimestamp = nil
        timer?.invalidate(); timer = nil
        EMBridgeStop()
        toggleItem.title = "Enable EdgeMotion"
        statusItem.button?.toolTip = "EdgeMotion — disabled"
        diagnosticItem?.title = "Diagnostics: disabled (frames \(receivedFrames), moves \(postedMoves))"
        logger.notice("disabled frames=\(self.receivedFrames, privacy: .public) moves=\(self.postedMoves, privacy: .public)")
    }

    fileprivate func accept(_ frame: ContactFrame?) {
        guard let frame else { engine.stop(); noteState(); return }
        receivedFrames += 1
        guard case .success = FrameValidator.validate(frame, previousSequence: lastSequence) else {
            logger.error("frame validation failed")
            disable(); return
        }
        lastSequence = frame.sequence
        latestInputTimestamp = frame.timestamp
        engine.accept(frame)
        noteState()
    }

    private func moveCursor() {
        guard enabled, let latestInputTimestamp, let delta = engine.tick(at: latestInputTimestamp),
              let current = CGEvent(source: nil)?.location else { return }
        _ = QuartzDiagnosticOutput.postMouseMove(to: CGPoint(x: current.x + delta.x, y: current.y + delta.y))
        postedMoves += 1
        if postedMoves == 1 { logger.notice("first cursor move posted") }
    }

    private func noteState() {
        let state = engine.state
        guard state != lastState else {
            if receivedFrames % 120 == 0 { diagnosticItem.title = "Diagnostics: \(state), frames \(receivedFrames), moves \(postedMoves)" }
            return
        }
        lastState = state
        diagnosticItem.title = "Diagnostics: \(state), frames \(receivedFrames), moves \(postedMoves)"
        logger.notice("engine state=\(String(describing: state), privacy: .public) frames=\(self.receivedFrames, privacy: .public)")
    }

    private func showBridgeError() {
        let alert = NSAlert(); alert.messageText = "EdgeMotion stayed disabled"; alert.informativeText = String(cString: EMBridgeFailureReason()); alert.runModal()
    }
    @objc private func quit() { disable(); NSApp.terminate(nil) }
}

@main
struct EdgeMotionMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private var appDelegate: AppDelegate?
private let multitouchCallback: @convention(c) (EMDecodedFrame, UnsafeMutableRawPointer?) -> Void = { raw, _ in
    // Copy before returning from the private callback, then process on the app
    // thread. No UI or Quartz calls occur on the framework callback thread.
    guard raw.contactCount == 0 || ContactFrame.fromBridge(raw) != nil else { return }
    let copied = raw.contactCount == 0 ? nil : ContactFrame.fromBridge(raw)
    DispatchQueue.main.async {
        appDelegate?.accept(copied)
    }
}
