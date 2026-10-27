import AVFoundation
import CoreGraphics

/// What the user is doing right now, so habit reminders can pick a good moment.
struct UserContext {
    /// Seconds since the last keyboard, mouse or trackpad input.
    var idleSeconds: TimeInterval = 0
    /// Another app is using the camera or microphone, i.e. probably a call.
    var inCall = false
    var screenLocked = false

    static let active = UserContext()

    static func current() -> UserContext {
        UserContext(idleSeconds: idleSeconds(), inCall: captureDeviceInUse(), screenLocked: isScreenLocked())
    }

    private static func idleSeconds() -> TimeInterval {
        // ~0 is "any input event"; this needs no special permission.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private static func captureDeviceInUse() -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .builtInWideAngleCamera, .external],
            mediaType: nil, position: .unspecified).devices
        // Excludes our own dictation: only other apps count.
        return devices.contains { $0.isInUseByAnotherApplication }
    }

    private static func isScreenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
