import AppKit
import Combine

/// The menu bar item and its menu.
///
/// Built with AppKit rather than `MenuBarExtra` so the menu can be rebuilt on demand
/// from live state (`menuNeedsUpdate`) and so the icon can reflect recording status
/// without a SwiftUI scene in the way.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let settings: AppSettings
    private let coordinator: DictationCoordinator
    private let openSettings: @MainActor () -> Void

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: AppSettings,
        coordinator: DictationCoordinator,
        openSettings: @escaping @MainActor () -> Void
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.openSettings = openSettings
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "VoiceFlow"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        // Explicit: info rows stay greyed out, action rows stay live, regardless of
        // what AppKit would infer from target/action.
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        // Delivered on the main run loop, so assuming main-actor isolation in the
        // sink is sound and avoids an extra hop per state change.
        coordinator.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.updateIcon(for: state) }
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for state: DictationState) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: "VoiceFlow \u{2014} \(state.statusLine)"
        )
        button.image?.isTemplate = true
        button.toolTip = "VoiceFlow \u{2014} \(state.statusLine)"
    }

    // MARK: - NSMenuDelegate

    /// Rebuilt every time it opens: cheap, and it can't drift from actual state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header("VoiceFlow"))
        menu.addItem(infoItem("Status: \(coordinator.state.statusLine)"))
        menu.addItem(infoItem("Hold \(settings.hotkey.displayName) to dictate"))

        if let problem = coordinator.serviceStatus {
            menu.addItem(.separator())
            for line in problem.components(separatedBy: "\n\n") {
                menu.addItem(warningItem(line))
            }
            let recheck = NSMenuItem(
                title: "Check Again",
                action: #selector(recheckServices),
                keyEquivalent: ""
            )
            recheck.target = self
            menu.addItem(recheck)
        }

        menu.addItem(.separator())
        menu.addItem(modeMenuItem())
        menu.addItem(modelMenuItem())

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit VoiceFlow",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Submenus

    private func modeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for mode in DictationMode.allCases {
            let modeItem = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectMode(_:)),
                keyEquivalent: ""
            )
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = (mode == settings.mode) ? .on : .off
            modeItem.toolTip = mode.summary
            submenu.addItem(modeItem)
        }

        item.submenu = submenu
        return item
    }

    private func modelMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(infoItem("Whisper: \(settings.whisperModelDisplayName)"))
        submenu.addItem(infoItem("LLM: \(settings.llmModel)"))
        submenu.addItem(.separator())
        submenu.addItem(infoItem("All processing is local"))
        item.submenu = submenu
        return item
    }

    // MARK: - Item helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        item.isEnabled = false
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Wraps long guidance so a multi-line error stays readable in the menu.
    private func warningItem(_ message: String) -> NSMenuItem {
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.maximumLineHeight = 15

        item.attributedTitle = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: paragraph
            ]
        )
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DictationMode(rawValue: raw) else { return }
        settings.mode = mode
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func recheckServices() {
        Task { await coordinator.checkLocalServices() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
