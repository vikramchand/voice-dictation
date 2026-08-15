import AppKit
import SwiftUI

/// Hosts `RecordingIndicator` in a borderless, non-activating panel.
///
/// The window must never take key focus: stealing focus would change the frontmost
/// app, which is exactly the app we are about to paste into. `.nonactivatingPanel`
/// plus `ignoresMouseEvents` keeps it purely decorative.
@MainActor
final class RecordingIndicatorController {

    private let model = IndicatorViewModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var levelTimer: Timer?

    /// Read for the level meter while recording.
    var levelSource: AudioBuffer?

    // MARK: - State

    func update(_ state: DictationState) {
        model.state = state

        if state.isVisible {
            show()
        }

        switch state {
        case .recording:
            startLevelUpdates()
        default:
            stopLevelUpdates()
        }

        // Terminal states linger just long enough to be read, then fade out.
        switch state {
        case .done:
            scheduleHide(after: .seconds(1))
        case .failed:
            scheduleHide(after: .seconds(5))
        case .idle:
            scheduleHide(after: .zero)
        case .recording, .processing:
            hideTask?.cancel()
            hideTask = nil
        }
    }

    // MARK: - Window

    private func show() {
        hideTask?.cancel()
        hideTask = nil

        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }

        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: RecordingIndicator(model: model))
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the SwiftUI view draws its own
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Belt and braces: a panel that can't become key or main can't steal focus.
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    /// Bottom-centre of whichever screen holds the mouse, above the Dock.
    private func position(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 44)
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Level meter

    private func startLevelUpdates() {
        guard levelTimer == nil, levelSource != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let source = self.levelSource else { return }
                // Perceptual boost: speech rarely approaches full scale, and a bar
                // that never leaves the first notch reads as broken.
                self.model.level = min(1, source.recentPeak() * 3.5)
            }
        }
        // Common modes so the meter keeps ticking during menu tracking.
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
        model.level = 0
    }
}
