import SwiftUI

/// Compact "what is VoiceFlow doing right now" banner.
///
/// Shown at the top of the settings window; the same state drives the menu bar icon
/// and the floating indicator, so all three can never disagree.
struct StatusView: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: coordinator.state.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.state.statusLine)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Whisper \(settings.whisperModelDisplayName)  \u{00B7}  \(settings.llmModel)  "
                     + "\u{00B7}  \(settings.mode.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch coordinator.state {
        case .idle: return .secondary
        case .recording: return .red
        case .processing: return .accentColor
        case .done: return .green
        case .failed: return .orange
        }
    }
}
