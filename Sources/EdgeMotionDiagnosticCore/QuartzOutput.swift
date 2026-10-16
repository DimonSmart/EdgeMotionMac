import Foundation
import CoreGraphics
import ApplicationServices

/// Public-only output boundary. It deliberately has no dependency on the
/// private input bridge and can only be reached by the runtime after a valid
/// stable frame has been processed.
public enum QuartzOutput {
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func mouseEventType(isLeftButtonPressed: Bool) -> CGEventType {
        isLeftButtonPressed ? .leftMouseDragged : .mouseMoved
    }

    /// Public Quartz output used solely after a validated hardware frame.
    @discardableResult public static func postMouseMove(to point: CGPoint) -> Bool {
        guard isAccessibilityTrusted,
              let event = CGEvent(
                  mouseEventSource: nil,
                  mouseType: mouseEventType(isLeftButtonPressed: CGEventSource.buttonState(.combinedSessionState, button: .left)),
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else { return false }
        event.flags = CGEventSource.flagsState(.combinedSessionState)
        event.post(tap: .cghidEventTap)
        return true
    }
}
