import AppKit
import EdgeMotionUpdateCore

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private let currentVersion: String
    private let checker: GitHubReleaseChecker
    private let installer: HomebrewUpdateInstaller
    private let prepareForRestart: () -> Void
    private let restartFailed: () -> Void
    private let restartSucceeded: () -> Void
    private let window: NSWindow
    private let statusLabel = NSTextField(wrappingLabelWithString: "Checking for updates...")
    private let spinner = NSProgressIndicator()
    private let updateButton = NSButton(title: "Update now", target: nil, action: nil)
    private let releaseButton = NSButton(title: "Open release page", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var releaseURL: URL?
    private var pendingVersion: ReleaseVersion?
    private var checkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var canCancelUpdate = true
    private var updating = false
    private var restarting = false

    var blocksApplicationTermination: Bool { updating || restarting }

    init(currentVersion: String,
         checker: GitHubReleaseChecker = GitHubReleaseChecker(),
         installer: HomebrewUpdateInstaller = HomebrewUpdateInstaller(),
         prepareForRestart: @escaping () -> Void,
         restartFailed: @escaping () -> Void,
         restartSucceeded: @escaping () -> Void) {
        self.currentVersion = currentVersion
        self.checker = checker
        self.installer = installer
        self.prepareForRestart = prepareForRestart
        self.restartFailed = restartFailed
        self.restartSucceeded = restartSucceeded
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "About EdgeMotion"
        window.isReleasedWhenClosed = false
        window.delegate = self
        configureContent()
    }

    private func configureContent() {
        let title = NSTextField(labelWithString: "EdgeMotion")
        title.font = NSFont.boldSystemFont(ofSize: 22)
        let version = NSTextField(labelWithString: "Version \(currentVersion)")
        version.textColor = .secondaryLabelColor

        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        updateButton.target = self
        updateButton.action = #selector(performUpdate)
        updateButton.isHidden = true
        updateButton.keyEquivalent = "\r"
        releaseButton.target = self
        releaseButton.action = #selector(openRelease)
        releaseButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeAbout)
        closeButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [releaseButton, updateButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fill

        let spacer = NSView()
        let content = NSStackView(views: [title, version, statusRow, spacer, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        guard let root = window.contentView else { return }
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 6)
        ])
    }

    func present() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if checkTask == nil && !updating { beginCheck() }
    }

    private func beginCheck() {
        pendingVersion = nil
        releaseURL = nil
        releaseButton.isHidden = true
        updateButton.isHidden = true
        statusLabel.stringValue = "Checking for updates..."
        spinner.startAnimation(nil)
        spinner.isHidden = false
        checkTask = Task { [weak self] in
            guard let self = self else { return }
            let result = await self.checker.check(currentVersion: self.currentVersion)
            guard !Task.isCancelled else { self.checkTask = nil; return }
            switch result {
            case .upToDate:
                self.statusLabel.stringValue = "You're up to date."
            case .unavailable:
                self.statusLabel.stringValue = "Unable to check for updates."
            case let .available(version, url):
                self.pendingVersion = version
                self.releaseURL = url
                self.releaseButton.isHidden = false
                self.statusLabel.stringValue = "Version \(version) is available. Checking installation..."
                let availability = await self.installer.availability()
                guard !Task.isCancelled else { self.checkTask = nil; return }
                switch availability {
                case .available:
                    self.statusLabel.stringValue = "Version \(version) is available via Homebrew."
                    self.updateButton.isHidden = false
                case .unavailable(let reason):
                    self.statusLabel.stringValue = "Version \(version) is available. \(reason)"
                }
            }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.checkTask = nil
        }
    }

    @objc private func openRelease() {
        guard let url = releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func performUpdate() {
        guard !updating, let version = pendingVersion else { return }
        updating = true
        canCancelUpdate = true
        updateButton.isHidden = true
        releaseButton.isEnabled = false
        closeButton.title = "Cancel"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        updateTask = Task { [weak self] in
            guard let self = self else { return }
            let result = await self.installer.install(expected: version) { [weak self] phase in
                Task { @MainActor [weak self] in
                    guard let self = self, self.updating else { return }
                    self.statusLabel.stringValue = phase.message
                    self.canCancelUpdate = phase.allowsCancellation
                    self.closeButton.isEnabled = phase.allowsCancellation
                }
            }
            self.updateTask = nil
            self.updating = false
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.closeButton.isEnabled = true
            self.closeButton.title = "Close"
            self.releaseButton.isEnabled = true
            switch result {
            case .cancelled:
                self.statusLabel.stringValue = "Update cancelled."
                self.updateButton.isHidden = false
            case .packageNotPublished:
                self.statusLabel.stringValue = "GitHub release is available, but its Homebrew package is not published yet. Try again shortly."
                self.updateButton.isHidden = false
            case .failed(let message):
                self.statusLabel.stringValue = message
                self.updateButton.isHidden = false
            case .installed(let installed):
                self.restarting = true
                self.statusLabel.stringValue = "Restarting EdgeMotion \(installed)..."
                self.prepareForRestart()
                let result = await LocalUpdateCommandRunner().run("/usr/bin/open",
                    ["-n", HomebrewUpdateInstaller.appPath], cancellable: false)
                if result.exitCode == 0 {
                    self.restarting = false
                    self.restartSucceeded()
                } else {
                    self.restarting = false
                    self.restartFailed()
                    self.statusLabel.stringValue = "Updated to \(installed), but restart failed. Start EdgeMotion again from Applications."
                }
            }
        }
    }

    @objc private func closeAbout() {
        if updating {
            if canCancelUpdate {
                closeButton.isEnabled = false
                updateTask?.cancel()
                statusLabel.stringValue = "Cancelling update..."
            }
            return
        }
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if updating {
            closeAbout()
            return false
        }
        checkTask?.cancel()
        checkTask = nil
        return true
    }
}
