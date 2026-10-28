import AppKit
import CoreGraphics
import EdgeMotionCore
import EdgeMotionInputBridge
import EdgeMotionInputCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum StatusAppearance: Equatable { case disabled, permissionRequired, enabled, active }
    private enum AppInfo {
        static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
        static let repositoryURL = URL(string: "https://github.com/DimonSmart/EdgeMotionMac")!
    }

    private let engine = EdgeMotionEngine()
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var toggleItem: NSMenuItem!
    private var accessibilityStatusItem: NSMenuItem!
    private var requestAccessibilityItem: NSMenuItem!
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var timer: Timer?
    private var lastSequence: Int64?
    private var inputClockOffset: TimeInterval?
    private var lastCursorSample: (location: CGPoint, timestamp: TimeInterval)?
    private var enabled = false
    private var displayedAppearance: StatusAppearance?
    private var aboutController: AboutWindowController?
    private var restartingAfterUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "Enable EdgeMotion", action: #selector(toggle), keyEquivalent: "e")
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(.separator())
        accessibilityStatusItem = menu.addItem(withTitle: "Accessibility: Checking…", action: nil, keyEquivalent: "")
        accessibilityStatusItem.isEnabled = false
        requestAccessibilityItem = menu.addItem(withTitle: "Request Accessibility Permission…", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
        requestAccessibilityItem.target = self
        let settingsItem = menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(.separator())
        let aboutItem = menu.addItem(withTitle: "About EdgeMotion " + AppInfo.version, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        let repositoryItem = menu.addItem(withTitle: "Open Repository", action: #selector(openRepository), keyEquivalent: "")
        repositoryItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit EdgeMotion", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusMenu = menu
        menu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        installToggleShortcut()
        updateStatusAppearance()
        updateAccessibilityMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshPermissionsOnActivation(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        aboutController?.blocksApplicationTermination == true ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggle()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        } else {
            toggle()
        }
    }

    private func installToggleShortcut() {
        let handle: (NSEvent) -> Bool = { [weak self] event in
            guard event.type == .keyDown,
                  !event.isARepeat,
                  event.charactersIgnoringModifiers?.lowercased() == "e",
                  event.modifierFlags.contains([.option, .command]),
                  !event.modifierFlags.contains([.control, .shift]) else { return false }
            self?.toggle()
            return true
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = handle(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    @objc private func toggle() {
        guard !restartingAfterUpdate else { return }
        enabled ? disable() : enable()
    }

    private func enable() {
        guard QuartzOutput.isAccessibilityTrusted else {
            _ = QuartzOutput.requestAccessibilityAccess()
            updateAccessibilityMenu()
            updateStatusAppearance()
            return
        }
        guard EMBridgeStartBuiltIn(multitouchCallback, Unmanaged.passUnretained(self).toOpaque()) else { showBridgeError(); return }
        enabled = true
        toggleItem.title = "Disable EdgeMotion"
        updateStatusAppearance()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.moveCursor() }
    }

    private func disable() {
        enabled = false
        stopInputSession()
        updateStatusAppearance()
        toggleItem.title = "Enable EdgeMotion"
    }

    private func stopInputSession() {
        engine.stop(); lastSequence = nil; inputClockOffset = nil; lastCursorSample = nil
        timer?.invalidate(); timer = nil
        EMBridgeStop()
    }

    fileprivate func accept(_ frame: ContactFrame?) {
        guard enabled else { return }
        guard let frame else {
            engine.stop()
            lastCursorSample = nil
            if EMBridgeCurrentState() == EMBridgeDisabled {
                disable()
                showBridgeError()
                return
            }
            updateStatusAppearance()
            return
        }
        guard case .success = FrameValidator.validate(frame, previousSequence: lastSequence) else {
            // A private-framework startup callback may contain a transient
            // malformed frame. Keep the user's enabled choice, but discard
            // the frame and keep all cursor output stopped until a valid
            // sequence arrives. Once a valid sequence has begun, a malformed
            // frame is a safety failure and disables the session.
            if lastSequence == nil {
                engine.stop()
                updateStatusAppearance()
            } else {
                // Stop only the failed input session. The user's enabled
                // choice remains intact and can be explicitly turned off or
                // retried after the bridge returns to its ready state.
                stopInputSession()
                updateStatusAppearance()
            }
            return
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
        guard enabled else { return }
        guard QuartzOutput.isAccessibilityTrusted else {
            disable()
            updateAccessibilityMenu()
            return
        }
        guard EMBridgeCurrentState() == EMBridgeRunning,
              let inputClockOffset else { return }
        let delta = engine.tick(at: ProcessInfo.processInfo.systemUptime - inputClockOffset)
        updateStatusAppearance()
        guard let delta,
              let current = CGEvent(source: nil)?.location else { return }
        _ = QuartzOutput.postMouseMove(to: CGPoint(x: current.x + delta.x, y: current.y + delta.y))
    }

    private func updateStatusAppearance() {
        let appearance: StatusAppearance = enabled
            ? (engine.state == .active ? .active : .enabled)
            : (QuartzOutput.isAccessibilityTrusted ? .disabled : .permissionRequired)
        guard appearance != displayedAppearance else { return }
        displayedAppearance = appearance
        let symbolName: String
        let toolTip: String
        switch appearance {
        case .disabled:
            symbolName = "arrow.up.right.circle"
            toolTip = "EdgeMotion — disabled"
        case .permissionRequired:
            symbolName = "exclamationmark.triangle"
            toolTip = "EdgeMotion — Accessibility permission required"
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

    private func updateAccessibilityMenu() {
        let trusted = QuartzOutput.isAccessibilityTrusted
        accessibilityStatusItem.title = trusted ? "Accessibility: Allowed" : "Accessibility: Permission required"
        requestAccessibilityItem.isEnabled = !trusted
    }

    @objc private func requestAccessibilityPermission() {
        guard !QuartzOutput.isAccessibilityTrusted else { return }
        _ = QuartzOutput.requestAccessibilityAccess()
        updateAccessibilityMenu()
        updateStatusAppearance()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshPermissionsOnActivation(_ notification: Notification) {
        if enabled && !QuartzOutput.isAccessibilityTrusted {
            disable()
        }
        updateAccessibilityMenu()
        updateStatusAppearance()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if enabled && !QuartzOutput.isAccessibilityTrusted {
            disable()
        }
        updateAccessibilityMenu()
        updateStatusAppearance()
    }

    private func showBridgeError() {
        let status = EMBridgeLastOSStatus()
        let detail = String(cString: EMBridgeFailureReason())
        let statusDetail = status == 0 ? "" : " (OSStatus \(status))"
        let alert = NSAlert(); alert.messageText = "EdgeMotion stayed disabled"; alert.informativeText = detail + statusDetail; alert.runModal()
    }
    @MainActor @objc private func showAbout() {
        if aboutController == nil {
            aboutController = AboutWindowController(
                currentVersion: AppInfo.version,
                prepareForRestart: { [weak self] in
                    self?.restartingAfterUpdate = true
                    self?.disable()
                },
                restartFailed: { [weak self] in
                    self?.restartingAfterUpdate = false
                },
                restartSucceeded: {
                    NSApp.terminate(nil)
                }
            )
        }
        aboutController?.present()
    }
    @objc private func openRepository() { NSWorkspace.shared.open(AppInfo.repositoryURL) }
    @MainActor @objc private func quit() {
        guard aboutController?.blocksApplicationTermination != true else { return }
        disable()
        NSApp.terminate(nil)
    }
}

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

EdgeMotionMain.main()
