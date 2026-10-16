import Foundation
import CoreGraphics
import EdgeMotionDiagnosticCore
import EdgeMotionDiagnosticBridge

private struct Options {
    let seconds: TimeInterval
    init(arguments: [String]) {
        var parsedSeconds: TimeInterval = 12
        for argument in arguments.dropFirst() {
            if argument.hasPrefix("--seconds="), let seconds = TimeInterval(argument.dropFirst("--seconds=".count)), seconds > 0, seconds <= 60 {
                parsedSeconds = seconds
            }
        }
        seconds = parsedSeconds
    }
}

private struct ProbeSummary {
    var callbacks = 0
    var nonemptyFrames = 0
    var emptyFrames = 0
    var samePathFrames = 0
    var sameFingerFrames = 0
    var identifiersDisappeared = 0
    var invalidFrames = 0
    var fingerUpFrames = 0
}

// Deliberately a short-lived feasibility harness, not the menu-bar product.
final class DiagnosticRunner: @unchecked Sendable {
    private let session = DiagnosticSession()
    private let lifecycle = DiagnosticLifecycle()
    private let processingQueue = DispatchQueue(label: "EdgeMotionHardwareDiagnostic.processing")
    private let lock = NSLock()
    private let mainRunLoop = CFRunLoopGetMain()
    private let accessibilityTrusted: Bool
    private var pendingFrame = false
    private var summary = ProbeSummary()
    private var previousPathIDs = Set<Int>()
    private var previousFingerIDs = Set<Int>()
    private var didPostQuartzProof = false

    init(accessibilityTrusted: Bool) {
        self.accessibilityTrusted = accessibilityTrusted
    }

    func prepareForCallbackDelivery() { session.startIfReady(true) }

    func receive(_ raw: EMDecodedFrame) {
        let shouldEnqueue = lock.withLock { () -> Bool in
            summary.callbacks += 1
            if raw.contactCount == 0 {
                summary.emptyFrames += 1
                identifiersDisappeared(&summary, currentPathIDs: [], currentFingerIDs: [])
                return false
            }
            guard lifecycle.outcome == nil, !pendingFrame else { return false }
            pendingFrame = true
            return true
        }
        guard shouldEnqueue else { return }
        guard let frame = ContactFrame.fromBridge(raw) else {
            lock.withLock { summary.invalidFrames += 1; pendingFrame = false }
            finish(reason: "bridge produced no valid contacts", outcome: .disabled)
            return
        }
        processingQueue.async { [self] in
            defer { lock.withLock { pendingFrame = false } }
            guard lifecycle.outcome == nil else { return }
            let result = session.accept(frame) { valid in
                record(valid)
                emitOneQuartzProofIfAllowed()
            }
            if case .disabled(let reason) = result {
                lock.withLock { summary.invalidFrames += 1 }
                finish(reason: reason, outcome: .disabled)
            }
        }
    }

    func finish(reason: String, outcome: DiagnosticTerminalOutcome) {
        guard lifecycle.complete(outcome) else { return }
        processingQueue.async { [self] in
            if outcome == .disabled { session.disable(reason) } else { session.stop() }
            EMBridgeStop()
            print(outcome == .disabled ? "SAFE DISABLED: \(reason)" : "Diagnostic stopped: \(reason)")
            printSummary()
            CFRunLoopStop(mainRunLoop)
        }
    }

    func finishNoFrameTimeout() {
        if lifecycle.completeNoFrameTimeout() {
            processingQueue.async { [self] in
                session.disable("no valid callback frames before deadline")
                EMBridgeStop()
                print("SAFE DISABLED: no valid callback frames before deadline")
                printSummary()
                CFRunLoopStop(mainRunLoop)
            }
        } else {
            finish(reason: "probe interval completed", outcome: .stopped)
        }
    }

    private func record(_ frame: ContactFrame) {
        lock.withLock {
            _ = lifecycle.recordValidFrame()
            summary.nonemptyFrames += 1
            let paths = Set(frame.contacts.map(\.pathIndex))
            let fingers = Set(frame.contacts.map(\.fingerID))
            if !previousPathIDs.isDisjoint(with: paths) { summary.samePathFrames += 1 }
            if !previousFingerIDs.isDisjoint(with: fingers) { summary.sameFingerFrames += 1 }
            identifiersDisappeared(&summary, currentPathIDs: paths, currentFingerIDs: fingers)
            previousPathIDs = paths
            previousFingerIDs = fingers
            if frame.contacts.contains(where: { $0.phase == .ended }) { summary.fingerUpFrames += 1 }
        }
    }

    private func identifiersDisappeared(_ summary: inout ProbeSummary, currentPathIDs: Set<Int>, currentFingerIDs: Set<Int>) {
        if !previousPathIDs.subtracting(currentPathIDs).isEmpty || !previousFingerIDs.subtracting(currentFingerIDs).isEmpty {
            summary.identifiersDisappeared += 1
        }
    }

    private func emitOneQuartzProofIfAllowed() {
        guard accessibilityTrusted else { return }
        let shouldPost = lock.withLock { () -> Bool in
            guard !didPostQuartzProof else { return false }
            didPostQuartzProof = true
            return true
        }
        guard shouldPost else { return }
        let current = CGEvent(source: nil)?.location ?? .zero
        guard QuartzOutput.postMouseMove(to: CGPoint(x: current.x + 1, y: current.y)) else {
            finish(reason: "Accessibility trust was lost before Quartz output", outcome: .disabled)
            return
        }
        print("Quartz proof: posted one public mouse-move event")
    }

    private func printSummary() {
        let snapshot = lock.withLock { summary }
        print("summary callbacks=\(snapshot.callbacks) nonempty_frames=\(snapshot.nonemptyFrames) empty_frames=\(snapshot.emptyFrames) same_path_frames=\(snapshot.samePathFrames) same_finger_frames=\(snapshot.sameFingerFrames) ids_disappeared=\(snapshot.identifiersDisappeared) finger_up_frames=\(snapshot.fingerUpFrames) invalid_frames=\(snapshot.invalidFrames)")
    }
}

private let options = Options(arguments: CommandLine.arguments)
private let accessibilityTrusted = QuartzOutput.isAccessibilityTrusted
print("Accessibility trust: \(accessibilityTrusted ? "granted; one Quartz proof will be sent" : "not granted; raw-touch probe continues without Quartz output")")
guard EMBridgePrepare() == EMBridgeReady else {
    print("SAFE DISABLED: \(String(cString: EMBridgeFailureReason()))")
    exit(0)
}

let runner = DiagnosticRunner(accessibilityTrusted: accessibilityTrusted)
let callback: @convention(c) (EMDecodedFrame, UnsafeMutableRawPointer?) -> Void = { frame, _ in runner.receive(frame) }
runner.prepareForCallbackDelivery()
guard EMBridgeStartBuiltIn(callback, nil) else {
    print("SAFE DISABLED: \(String(cString: EMBridgeFailureReason()))")
    exit(0)
}

print("Diagnostic running for \(Int(options.seconds)) seconds. Touch, move, and lift on the built-in trackpad.")
let deadline = ProcessInfo.processInfo.systemUptime + options.seconds
while runner.lifecycleOutcome == nil && ProcessInfo.processInfo.systemUptime < deadline {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
if runner.lifecycleOutcome == nil { runner.finishNoFrameTimeout() }
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

private extension DiagnosticRunner {
    var lifecycleOutcome: DiagnosticTerminalOutcome? { lifecycle.outcome }
}
