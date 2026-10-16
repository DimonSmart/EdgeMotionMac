import Foundation
import CoreGraphics
import ApplicationServices

public enum QuartzDiagnosticOutput {
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Public Quartz output used solely after a validated hardware frame.
    @discardableResult public static func postMouseMove(to point: CGPoint) -> Bool {
        guard isAccessibilityTrusted,
              let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
}
