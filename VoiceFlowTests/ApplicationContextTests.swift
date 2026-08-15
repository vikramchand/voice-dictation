import XCTest
@testable import VoiceFlow

/// Bundle-identifier classification and the formatting behaviour it drives.
final class ApplicationContextTests: XCTestCase {

    func testKnownApplicationsClassify() {
        let cases: [(String, ApplicationKind)] = [
            ("com.tinyspeck.slackmacgap", .chat),
            ("com.apple.MobileSMS", .generic),      // not in the table
            ("com.apple.mail", .email),
            ("com.google.Chrome", .browser),
            ("com.apple.Safari", .browser),
            ("com.apple.Terminal", .terminal),
            ("com.googlecode.iterm2", .terminal),
            ("com.microsoft.VSCode", .codeEditor),
            ("com.todesktop.230313mzl4w4u92", .codeEditor),
            ("com.apple.Notes", .notes),
            ("md.obsidian", .notes),
            ("com.example.SomethingElse", .generic)
        ]

        for (bundleID, expected) in cases {
            XCTAssertEqual(
                ApplicationKind(bundleIdentifier: bundleID),
                expected,
                "wrong classification for \(bundleID)"
            )
        }
    }

    /// Bundle identifiers vary in case between what apps register and what the
    /// workspace reports, so matching is case-insensitive.
    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(ApplicationKind(bundleIdentifier: "COM.APPLE.TERMINAL"), .terminal)
        XCTAssertEqual(ApplicationKind(bundleIdentifier: "com.apple.terminal"), .terminal)
    }

    func testNilBundleIdentifierIsGeneric() {
        XCTAssertEqual(ApplicationKind(bundleIdentifier: nil), .generic)
        XCTAssertEqual(ApplicationContext.unknown.kind, .generic)
    }

    func testContextExposesItsKind() {
        let context = ApplicationContext(
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            applicationName: "Slack"
        )
        XCTAssertEqual(context.kind, .chat)
    }

    // MARK: - Behaviour driven by kind

    func testOnlyTerminalAndEditorOverrideTheMode() {
        XCTAssertEqual(ApplicationKind.terminal.effectiveModeOverride, .exact)
        XCTAssertEqual(ApplicationKind.codeEditor.effectiveModeOverride, .exact)

        for kind in [ApplicationKind.chat, .email, .browser, .notes, .generic] {
            XCTAssertNil(kind.effectiveModeOverride, "\(kind) should not override the mode")
        }
    }

    func testKindsWithHintsProvideThem() {
        XCTAssertNotNil(ApplicationKind.chat.formattingHint)
        XCTAssertNotNil(ApplicationKind.email.formattingHint)
        XCTAssertNotNil(ApplicationKind.terminal.formattingHint)
        XCTAssertNotNil(ApplicationKind.codeEditor.formattingHint)
        XCTAssertNotNil(ApplicationKind.notes.formattingHint)

        // A browser could be anything, so it gets no hint.
        XCTAssertNil(ApplicationKind.browser.formattingHint)
        XCTAssertNil(ApplicationKind.generic.formattingHint)
    }

    func testChatHintForbidsInventingAGreeting() throws {
        let hint = try XCTUnwrap(ApplicationKind.chat.formattingHint)
        XCTAssertTrue(hint.contains("Do not add a greeting"))
    }

    // MARK: - Provider stub

    func testMockProviderReturnsItsContext() {
        let expected = ApplicationContext(bundleIdentifier: "com.apple.Notes", applicationName: "Notes")
        let provider = MockApplicationProvider(context: expected)
        XCTAssertEqual(provider.currentContext(), expected)
    }
}
