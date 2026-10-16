import AppKit
import CoreGraphics
import EdgeMotionCore
import EdgeMotionDiagnosticBridge
import EdgeMotionDiagnosticCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum StatusAppearance: Equatable { case disabled, enabled, active }

    private let engine = EdgeMotionEngine()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var timer: Timer?
    private var lastSequence: Int64?
    private var inputClockOffset: TimeInterval?
    private var lastCursorSample: (location: CGPoint, timestamp: TimeInterval)?
    private var enabled = false
    private var displayedAppearance: StatusAppearance?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "Enable EdgeMotion", action: #selector(toggle), keyEquivalent: "e")
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit EdgeMotion", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusItem.menu = menu
        updateStatusAppearance()
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func toggle() {
        enabled ? disable() : enable()
    }

    private func enable() {
        guard QuartzOutput.isAccessibilityTrusted else {
            let alert = NSAlert(); alert.messageText = "Accessibility permission is required"; alert.informativeText = "Allow EdgeMotion in System Settings before enabling cursor motion."; alert.runModal()
            return
        }
        guard EMBridgePrepare() == EMBridgeReady else { showBridgeError(); return }
        guard EMBridgeStartBuiltIn(multitouchCallback, Unmanaged.passUnretained(self).toOpaque()) else { showBridgeError(); return }
        enabled = true
        toggleItem.title = "Disable EdgeMotion"
        updateStatusAppearance()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.moveCursor() }
    }

    private func disable() {
        enabled = false; engine.stop(); lastSequence = nil; inputClockOffset = nil; lastCursorSample = nil
        timer?.invalidate(); timer = nil
        EMBridgeStop()
        updateStatusAppearance()
        toggleItem.title = "Enable EdgeMotion"
    }

    fileprivate func accept(_ frame: ContactFrame?) {
        guard enabled else { return }
        guard let frame else {
            engine.stop()
            lastCursorSample = nil
            updateStatusAppearance()
            return
        }
        guard case .success = FrameValidator.validate(frame, previousSequence: lastSequence) else {
            disable(); return
        }
        lastSequence = frame.sequence
        // Both hold and motion ticks use the input timestamp domain. Calibrate
        // it once against uptime solely to let the active timer advance it.
        if inputClockOffset == nil { inputClockOffset = ProcessInfo.processInfo.systemUptime - frame.timestamp }
        let cursorVelocity = engine.state == .active || engine.state == .armed ? nil : observeCursorVelocity(at: frame.timestamp)
        engine.accept(frame, cursorVelocity: cursorVelocity)
        updateStatusAppearance()
    }

    private func observeCursorVelocity(at timestamp: TimeInterval) -> CursorDelta? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        defer { lastCursorSample = (location, timestamp) }
        guard let previous = lastCursorSample else { return nil }
        let deltaTime = timestamp - previous.timestamp
        guard deltaTime > 0 else { return nil }
        return CursorDelta(x: (location.x - previous.location.x) / deltaTime, y: (location.y - previous.location.y) / deltaTime)
    }

    private func moveCursor() {
        guard enabled, EMBridgeCurrentState() == EMBridgeRunning,
              let inputClockOffset else { return }
        let delta = engine.tick(at: ProcessInfo.processInfo.systemUptime - inputClockOffset)
        updateStatusAppearance()
        guard let delta,
              let current = CGEvent(source: nil)?.location else { return }
        _ = QuartzOutput.postMouseMove(to: CGPoint(x: current.x + delta.x, y: current.y + delta.y))
    }

    private func updateStatusAppearance() {
        let appearance: StatusAppearance = enabled ? (engine.state == .active ? .active : .enabled) : .disabled
        guard appearance != displayedAppearance else { return }
        displayedAppearance = appearance
        let symbolName: String
        let toolTip: String
        switch appearance {
        case .disabled:
            symbolName = "arrow.up.right.circle"
            toolTip = "EdgeMotion — disabled"
        case .enabled:
            symbolName = "arrow.up.right.circle.fill"
            toolTip = "EdgeMotion — enabled"
        case .active:
            symbolName = "arrow.up.right.circle.fill"
            toolTip = "EdgeMotion — active"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "EdgeMotion")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = toolTip
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

private let multitouchCallback: @convention(c) (EMDecodedFrame, UnsafeMutableRawPointer?) -> Void = { raw, context in
    // Copy before returning from the private callback, then process on the app
    // thread. No UI or Quartz calls occur on the framework callback thread.
    guard let context else { return }
    let copied = raw.contactCount == 0 ? nil : ContactFrame.fromBridge(raw)
    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.accept(copied)
    }
}
