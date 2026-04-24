import XCTest
@testable import HumdrumCore

/// Tier 2 behavior tests for the paste cascade. Uses a fake backend that
/// records every call in order and lets each stage be dialed to succeed
/// or fail independently.
///
/// The cascade is deliberately simple: after the short-circuit cases
/// (empty text, no Accessibility, password field refusal), every paste
/// goes through the same keystroke → clipboard flow. These tests cover
/// the three short-circuit paths, the two-stage execute() flow (happy
/// path, fallthrough to clipboard, total failure), and a small set of
/// integration cases showing that decide() + execute() compose correctly.
final class PasteCascadeTests: XCTestCase {

    // MARK: - Fake backend

    /// Records call ordering and returns whatever `Bool`s we dial in.
    /// Each `returnX` default matches the "happy path" — keystrokes work,
    /// we never need to fall through. Tests that want to exercise
    /// fallthrough flip the relevant flag to `false`.
    final class FakePasteBackend: PasteBackend {
        enum Call: Equatable {
            case keystroke(String)
            case clipboard(String)
        }

        var calls: [Call] = []

        var returnKeystroke: Bool = true
        var returnClipboard: Bool = true

        func insertViaKeystrokes(_ text: String) -> Bool {
            calls.append(.keystroke(text))
            return returnKeystroke
        }

        func insertViaClipboard(_ text: String) -> Bool {
            calls.append(.clipboard(text))
            return returnClipboard
        }
    }

    // MARK: - decide(): short-circuit cases

    func testEmptyTextShortCircuits() {
        let decision = PasteCascade.decide(
            text: "",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea"
        )
        XCTAssertEqual(decision, .empty)
    }

    func testMissingAccessibilityShortCircuits() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: false,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea"
        )
        XCTAssertEqual(decision, .noAccessibility)
    }

    // MARK: - decide(): password refusal

    func testPasswordFieldRefusesOnNativeApp() {
        let decision = PasteCascade.decide(
            text: "hunter2",
            hasAccessibility: true,
            bundleID: "com.apple.Safari",
            focusedRole: "AXSecureTextField"
        )
        XCTAssertEqual(decision, .refused)
    }

    func testPasswordFieldRefusesOnSkipListedApp() {
        // Even in a browser / Electron app, a password field is refused
        // rather than keystroke-typed. This prevents accidentally
        // dictating a password into a web login form.
        let decision = PasteCascade.decide(
            text: "hunter2",
            hasAccessibility: true,
            bundleID: "com.google.Chrome",
            focusedRole: "AXSecureTextField"
        )
        XCTAssertEqual(decision, .refused)
    }

    func testExecuteRefusedCallsNothingAndFails() {
        let backend = FakePasteBackend()
        let result = PasteCascade.execute(
            text: "hunter2",
            decision: .refused,
            backend: backend
        )
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    // MARK: - decide(): non-refused cases all route the same way

    func testNativeAppRoutesToKeystrokeFirst() {
        // Under the two-stage cascade, even a native app + editable
        // role goes to keystrokes. There is no AX-first branch.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea"
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testChromeRoutesToKeystrokeFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.google.Chrome",
            focusedRole: "AXTextField"
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testSlackRoutesToKeystrokeFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.tinyspeck.slackmacgap",
            focusedRole: "AXTextArea"
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testOfficeRoutesToKeystrokeFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.microsoft.Word",
            focusedRole: "AXTextField"
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testNonEditableRoleRoutesToKeystrokeFirst() {
        // Web areas, canvases, buttons, etc. — keystrokes handle the
        // "is this actually editable?" question at the OS input layer.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXWebArea"
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testNilFocusedRoleRoutesToKeystrokeFirst() {
        // Couldn't read role (app blocks AX reads, nothing focused, …)
        // → keystrokes are the safe default.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: nil
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testNilBundleIDRoutesToKeystrokeFirst() {
        // Can't read bundle ID (rare — sandboxed helper process?). Still
        // routes to keystrokes; bundle ID is reserved only for logging.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: nil,
            focusedRole: "AXTextField"
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testNilBundleIDWithNilRoleRoutesToKeystrokeFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: nil,
            focusedRole: nil
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    func testUnknownRoleRoutesToKeystrokeFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXFoobar"
        )
        XCTAssertEqual(decision, .keystrokeFirst)
    }

    // MARK: - execute(): short-circuit cases

    func testExecuteEmptyCallsNothingAndFails() {
        let backend = FakePasteBackend()
        let result = PasteCascade.execute(text: "", decision: .empty, backend: backend)
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testExecuteNoAccessibilityCallsNothingAndFails() {
        let backend = FakePasteBackend()
        let result = PasteCascade.execute(
            text: "hello",
            decision: .noAccessibility,
            backend: backend
        )
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    // MARK: - execute(): .keystrokeFirst cascade

    func testKeystrokeFirstSucceedsOnFirstTry() {
        let backend = FakePasteBackend()
        backend.returnKeystroke = true

        let result = PasteCascade.execute(
            text: "hello",
            decision: .keystrokeFirst,
            backend: backend
        )

        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(backend.calls, [.keystroke("hello")])
    }

    func testKeystrokeFirstFallsThroughToClipboard() {
        // Keystroke stage can only fail when the CGEvent source can't
        // be constructed — extremely rare, but the cascade still has
        // to fall through to clipboard+⌘V so the paste isn't silently
        // dropped.
        let backend = FakePasteBackend()
        backend.returnKeystroke = false
        backend.returnClipboard = true

        let result = PasteCascade.execute(
            text: "hello",
            decision: .keystrokeFirst,
            backend: backend
        )

        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(
            backend.calls,
            [.keystroke("hello"), .clipboard("hello")]
        )
    }

    func testKeystrokeFirstReturnsFailedWhenAllStagesFail() {
        let backend = FakePasteBackend()
        backend.returnKeystroke = false
        backend.returnClipboard = false

        let result = PasteCascade.execute(
            text: "hello",
            decision: .keystrokeFirst,
            backend: backend
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(
            backend.calls,
            [.keystroke("hello"), .clipboard("hello")]
        )
    }

    // MARK: - Text payload preservation

    func testTextIsPassedThroughVerbatimToBackend() {
        // Tricky characters — em dash, emoji, quotes — should reach
        // the backend stage without mutation.
        let tricky = "She said \"hello\" — with 🎉 and =SUM(A1:A10)"
        let backend = FakePasteBackend()
        backend.returnKeystroke = false   // force fallthrough to clipboard
        backend.returnClipboard = true

        _ = PasteCascade.execute(
            text: tricky,
            decision: .keystrokeFirst,
            backend: backend
        )

        XCTAssertEqual(
            backend.calls,
            [.keystroke(tricky), .clipboard(tricky)]
        )
    }

    // MARK: - End-to-end decide + execute integration

    func testIntegrationNativeAppHappyPath() {
        // TextEdit + AXTextArea → keystrokes, exactly one backend call.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea"
        )
        let backend = FakePasteBackend()
        let result = PasteCascade.execute(
            text: "hello",
            decision: decision,
            backend: backend
        )
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(backend.calls, [.keystroke("hello")])
    }

    func testIntegrationChromeHappyPath() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.google.Chrome",
            focusedRole: "AXTextField"
        )
        let backend = FakePasteBackend()
        let result = PasteCascade.execute(
            text: "hello",
            decision: decision,
            backend: backend
        )
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(backend.calls, [.keystroke("hello")])
    }

    func testIntegrationElectronHappyPath() {
        // Electron apps (Slack here) go through the same keystroke path
        // as everything else — that's the whole point of removing AX.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.tinyspeck.slackmacgap",
            focusedRole: "AXTextArea"
        )
        let backend = FakePasteBackend()
        let result = PasteCascade.execute(
            text: "hello",
            decision: decision,
            backend: backend
        )
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(backend.calls, [.keystroke("hello")])
    }
}
