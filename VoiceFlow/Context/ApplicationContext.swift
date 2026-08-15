import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Which app the text is about to land in.
///
/// Captured the moment the hotkey goes down — before any VoiceFlow UI appears —
/// so the target is the app the user was actually typing into.
struct ApplicationContext: Equatable, Sendable {
    let bundleIdentifier: String?
    let applicationName: String?
    let processIdentifier: pid_t?

    init(bundleIdentifier: String?, applicationName: String?, processIdentifier: pid_t? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.processIdentifier = processIdentifier
    }

    static let unknown = ApplicationContext(bundleIdentifier: nil, applicationName: nil)

    var kind: ApplicationKind {
        ApplicationKind(bundleIdentifier: bundleIdentifier)
    }
}

/// Coarse buckets used to nudge formatting. Deliberately small — this is a
/// formatting hint, not an app-specific rules engine.
enum ApplicationKind: String, Equatable, Sendable {
    case chat
    case email
    case browser
    case terminal
    case codeEditor
    case notes
    case generic

    init(bundleIdentifier: String?) {
        guard let id = bundleIdentifier?.lowercased() else {
            self = .generic
            return
        }

        switch id {
        case "com.tinyspeck.slackmacgap":
            self = .chat
        case "com.hnc.discord", "com.apple.messages", "ru.keepcoder.telegram",
             "net.whatsapp.whatsapp", "com.microsoft.teams", "com.microsoft.teams2":
            self = .chat

        case "com.apple.mail", "com.readdle.smailncmac", "com.superhuman.electron",
             "com.microsoft.outlook":
            self = .email

        case "com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
             "com.microsoft.edgemac", "company.thebrowser.browser", "com.brave.browser":
            self = .browser

        case "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
             "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper":
            self = .terminal

        case "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", // Cursor
             "com.apple.dt.xcode", "com.jetbrains.intellij", "dev.zed.zed",
             "com.sublimetext.4":
            self = .codeEditor

        case "com.apple.notes", "md.obsidian", "notion.id", "com.agiletortoise.drafts-osx":
            self = .notes

        default:
            self = .generic
        }
    }

    /// Appended to the system prompt. One or two sentences at most — a long hint
    /// starts to compete with the mode rules.
    var formattingHint: String? {
        switch self {
        case .chat:
            return "The text is going into a chat message. Keep it short and conversational. "
                 + "Do not add a greeting or sign-off that the speaker did not say."
        case .email:
            return "The text is going into an email. Use paragraph breaks where the speaker "
                 + "changes subject, and keep any greeting on its own line."
        case .terminal:
            return "The text is going into a terminal. Preserve command names, flags, paths, "
                 + "and punctuation exactly as spoken. Do not add trailing punctuation."
        case .codeEditor:
            return "The text is going into a code editor. Preserve identifiers, symbols, and "
                 + "casing exactly as spoken. Do not reformat code-like fragments into prose."
        case .notes:
            return "The text is going into a notes app. Preserve list structure if the speaker "
                 + "enumerated items."
        case .browser, .generic:
            return nil
        }
    }

    /// Terminals and editors get forced down to near-verbatim regardless of the
    /// selected mode: a "polished" shell command is a broken shell command.
    var effectiveModeOverride: DictationMode? {
        switch self {
        case .terminal, .codeEditor:
            return .exact
        default:
            return nil
        }
    }
}

/// Supplies the frontmost application. Abstracted so tests don't need a window server.
protocol FrontmostApplicationProviding: Sendable {
    func currentContext() -> ApplicationContext
}

#if canImport(AppKit)
/// Reads the frontmost app from `NSWorkspace`.
///
/// VoiceFlow itself is an accessory app whose panels never take key focus, so the
/// frontmost app stays correct while the recording indicator is on screen. VoiceFlow
/// is filtered out anyway, in case the settings window happens to be open.
final class WorkspaceApplicationProvider: FrontmostApplicationProviding, @unchecked Sendable {

    private let ownBundleIdentifier: String?

    init(ownBundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    func currentContext() -> ApplicationContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }
        if let own = ownBundleIdentifier, app.bundleIdentifier == own {
            return .unknown
        }
        return ApplicationContext(
            bundleIdentifier: app.bundleIdentifier,
            applicationName: app.localizedName,
            processIdentifier: app.processIdentifier
        )
    }
}
#endif
