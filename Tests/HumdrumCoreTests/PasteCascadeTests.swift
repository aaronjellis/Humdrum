import XCTest
@testable import HumdrumCore

/// Tier 2 behavior tests for the paste cascade. Uses a fake backend that
/// records every call in order and lets each stage be dialed to succeed
/// or fail independently.
///
/// The cascade is deliberately simple: after the short-circuit cases
/// (empty text, no Accessibility, password field refusal), every paste
/// goes through the same clipboard → keystroke flow. These tests cover
/// the three short-circuit paths, the two-stage execute() flow (happy
/// path, fallthrough to keystroke, total failure), and a small set of
/// integration cases showing that decide() + execute() compose correctly.
final class PasteCascadeTests: XCTestCase {

    // MARK: - Fake backend

    /// Records call ordering and returns whatever `Bool`s we dial in.
    /// Each `returnX` default matches the "happy path" — clipboard works,
    /// we never need to fall through. Tests that want to exercise
    /// fallthrough flip the relevant flag to `false`.
    final class FakePasteBackend: PasteBackend {
        enum Call: Equatable {
            case clipboard(String)
            case keystroke(String)
        }

        var calls: [Call] = []

        var returnClipboard: Bool = true
        var returnKeystroke: Bool = true

        func insertViaClipboard(_ text: String) -> Bool {
            calls.append(.clipboard(text))
            return returnClipboard
        }

        func insertViaKeystrokes(_ text: String) -> Bool {
            calls.append(.keystroke(text))
            return returnKeystroke
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

    func testPasswordFieldRefusesOnElectronApp() {
        // Even in an Electron/Chromium app, a password field is refused
        // rather than pasted into. This prevents accidentally dictating
        // a password into a web login form.
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

    func testNativeAppRoutesToClipboardFirst() {
        // Under the two-stage cascade, every non-refused app + role
        // combination goes through clipboard + ⌘V as the primary path.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea"
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testChromeRoutesToClipboardFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.google.Chrome",
            focusedRole: "AXTextField"
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testSlackRoutesToClipboardFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.tinyspeck.slackmacgap",
            focusedRole: "AXTextArea"
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testClaudeDesktopRoutesToClipboardFirst() {
        // The smoking-gun app that drove the flip from keystroke-first:
        // Claude desktop is Electron, keystroke synthesis is silently
        // filtered by the renderer, clipboard + ⌘V lands every time.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.anthropic.claudefordesktop",
            focusedRole: "AXTextArea"
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testOfficeRoutesToClipboardFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.microsoft.Word",
            focusedRole: "AXTextField"
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testNonEditableRoleRoutesToClipboardFirst() {
        // Web areas, canvases, buttons, etc. — ⌘V handles the "is this
        // actually editable?" question at the OS input layer.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXWebArea"
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testNilFocusedRoleRoutesToClipboardFirst() {
        // Couldn't read role (app blocks AX reads, nothing focused, …)
        // → clipboard + ⌘V is the safe default.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: nil
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testNilBundleIDRoutesToClipboardFirst() {
        // Can't read bundle ID (rare — sandboxed helper process?). Still
        // routes to clipboard; bundle ID is reserved only for future
        // overrides and logging.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: nil,
            focusedRole: "AXTextField"
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testNilBundleIDWithNilRoleRoutesToClipboardFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: nil,
            focusedRole: nil
        )
        XCTAssertEqual(decision, .clipboardFirst)
    }

    func testUnknownRoleRoutesToClipboardFirst() {
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXFoobar"
        )
        XCTAssertEqual(decision, .clipboardFirst)
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

    // MARK: - execute(): .clipboardFirst cascade

    func testClipboardFirstSucceedsOnFirstTry() {
        let backend = FakePasteBackend()
        backend.returnClipboard = true

        let result = PasteCascade.execute(
            text: "hello",
            decision: .clipboardFirst,
            backend: backend
        )

        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(backend.calls, [.clipboard("hello")])
    }

    func testClipboardFirstFallsThroughToKeystroke() {
        // Clipboard stage can only fail when the CGEvent source can't
        // be constructed — extremely rare, but the cascade still has
        // to fall through to keystroke synthesis so the paste isn't
        // silently dropped.
        let backend = FakePasteBackend()
        backend.returnClipboard = false
        backend.returnKeystroke = true

        let result = PasteCascade.execute(
            text: "hello",
            decision: .clipboardFirst,
            backend: backend
        )

        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(
            backend.calls,
            [.clipboard("hello"), .keystroke("hello")]
        )
    }

    func testClipboardFirstReturnsFailedWhenAllStagesFail() {
        let backend = FakePasteBackend()
        backend.returnClipboard = false
        backend.returnKeystroke = false

        let result = PasteCascade.execute(
            text: "hello",
            decision: .clipboardFirst,
            backend: backend
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(
            backend.calls,
            [.clipboard("hello"), .keystroke("hello")]
        )
    }

    // MARK: - Text payload preservation

    func testTextIsPassedThroughVerbatimToBackend() {
        // Tricky characters — em dash, emoji, quotes — should reach
        // the backend stage without mutation.
        let tricky = "She said \"hello\" — with 🎉 and =SUM(A1:A10)"
        let backend = FakePasteBackend()
        backend.returnClipboard = false   // force fallthrough to keystroke
        backend.returnKeystroke = true

        _ = PasteCascade.execute(
            text: tricky,
            decision: .clipboardFirst,
            backend: backend
        )

        XCTAssertEqual(
            backend.calls,
            [.clipboard(tricky), .keystroke(tricky)]
        )
    }

    // MARK: - End-to-end decide + execute integration

    func testIntegrationNativeAppHappyPath() {
        // TextEdit + AXTextArea → clipboard, exactly one backend call.
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
        XCTAssertEqual(backend.calls, [.clipboard("hello")])
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
        XCTAssertEqual(backend.calls, [.clipboard("hello")])
    }

    func testIntegrationElectronHappyPath() {
        // Electron apps (Slack here) go through clipboard + ⌘V — the
        // whole point of the cascade flip. Keystroke synthesis would
        // be silently filtered by the Electron renderer.
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
        XCTAssertEqual(backend.calls, [.clipboard("hello")])
    }

    func testIntegrationClaudeDesktopHappyPath() {
        // The flip's motivating case: Claude desktop (Electron) accepts
        // clipboard + ⌘V but silently drops synthetic unicode events.
        let decision = PasteCascade.decide(
            text: "hello",
            hasAccessibility: true,
            bundleID: "com.anthropic.claudefordesktop",
            focusedRole: "AXTextArea"
        )
        let backend = FakePasteBackend()
        let result = PasteCascade.execute(
            text: "hello",
            decision: decision,
            backend: backend
        )
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(backend.calls, [.clipboard("hello")])
    }
}
