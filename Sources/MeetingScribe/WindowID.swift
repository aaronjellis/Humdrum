import Foundation

/// Centralized window-scene identifiers so openWindow / dismissWindow calls
/// can't drift.
enum WindowID {
    static let main = "main"
    static let setup = "setup"
    static let recorder = "recorder"
}
