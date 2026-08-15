import SwiftUI

/// Backing store for the floating indicator. Updated only from the main thread.
@MainActor
final class IndicatorViewModel: ObservableObject {
    @Published var state: DictationState = .idle
    /// 0...1 microphone peak, drives the level bars while recording.
    @Published var level: Float = 0
}

/// The small pill that appears near the bottom of the screen during a dictation.
///
/// Intentionally tiny and non-interactive — it reports state and gets out of the way.
struct RecordingIndicator: View {

    @ObservedObject var model: IndicatorViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.state.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: isPulsing)

            Text(model.state.indicatorLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if case .recording = model.state {
                LevelMeter(level: model.level)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .fixedSize()
    }

    private var isPulsing: Bool {
        model.state.isBusy
    }

    private var tint: Color {
        switch model.state {
        case .recording: return .red
        case .processing: return .accentColor
        case .done: return .green
        case .failed: return .orange
        case .idle: return .secondary
        }
    }
}

/// Five bars that rise with the microphone level, so the user can see at a glance
/// that audio is actually being picked up.
private struct LevelMeter: View {
    let level: Float

    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.red.opacity(opacity(for: index)))
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: level)
    }

    /// Bars fill left to right as the level rises, with a floor so the meter never
    /// looks dead during a quiet passage.
    private func threshold(for index: Int) -> Float {
        Float(index + 1) / Float(barCount) * 0.6
    }

    private func height(for index: Int) -> CGFloat {
        let active = level >= threshold(for: index)
        return active ? CGFloat(6 + index * 2) : 3
    }

    private func opacity(for index: Int) -> Double {
        level >= threshold(for: index) ? 1.0 : 0.25
    }
}
