import SwiftUI

/// Splash screen shown while WhisperKit and Kokoro models download / load.
/// Two parallel progress bars reflect the concurrent loading happening in the view-model.
struct ModelLoadingView: View {
    let status: String
    let whisperProgress: Double
    let ttsProgress: Double

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "globe")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)

                Text("Universal Translator")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }

            VStack(spacing: 20) {
                ProgressRow(
                    label: "Speech Recognition",
                    icon: "waveform",
                    progress: whisperProgress
                )
                ProgressRow(
                    label: "Text to Speech",
                    icon: "speaker.wave.2",
                    progress: ttsProgress
                )
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 32)

            Text(status)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))

            Spacer()
        }
    }
}

private struct ProgressRow: View {
    let label: String
    let icon: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if progress >= 1.0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            ProgressView(value: progress)
                .tint(.white.opacity(0.8))
        }
    }
}
