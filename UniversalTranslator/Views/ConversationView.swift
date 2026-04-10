import SwiftUI

/// The conversation panel: language picker header, scrolling chat history,
/// and live transcription/translation bubbles. Wrapped in a recessed
/// skeuomorphic surface to match the device aesthetic.
struct ConversationView: View {
    let messages: [TranslationMessage]
    let liveTranscription: String
    let liveTranslation: String
    let pipelineState: PipelineState
    let activeSide: PanelSide?
    let onReplay: (TranslationMessage) -> Void
    let onClear: () -> Void

    @Binding var leftLanguage: Language
    @Binding var rightLanguage: Language
    let onSwap: () -> Void

    @State private var showLeftPicker = false
    @State private var showRightPicker = false

    var body: some View {
        VStack(spacing: 0) {
            languageHeader

            Divider()
                .background(.white.opacity(0.2))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubbleView(message: message) {
                                onReplay(message)
                            }
                            .id(message.id)
                        }

                        // Live transcription bubble (visible while the user is speaking).
                        if !liveTranscription.isEmpty {
                            liveTextBubble(
                                text: liveTranscription,
                                label: "Listening...",
                                side: activeSide ?? .left
                            )
                            .id("live-transcription")
                        }

                        // Live translation bubble. Aligned to the SAME side as the active speaker
                        // so it lands cleanly into the final bubble once the pipeline completes.
                        if !liveTranslation.isEmpty {
                            liveTextBubble(
                                text: liveTranslation,
                                label: "Translating...",
                                side: activeSide ?? .left
                            )
                            .id("live-translation")
                        }

                        if case .speaking = pipelineState {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                Text("Speaking...")
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .id("speaking")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: liveTranscription) { _, _ in
                    withAnimation {
                        proxy.scrollTo("live-transcription", anchor: .bottom)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.16, blue: 0.18),
                            Color(red: 0.10, green: 0.10, blue: 0.12),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .shadow(.inner(color: .black.opacity(0.6), radius: 4, x: 0, y: 2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.02),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .sheet(isPresented: $showLeftPicker) {
            LanguageSelectorView(selectedLanguage: $leftLanguage)
                #if os(iOS)
                .presentationDetents([.medium])
                #endif
        }
        .sheet(isPresented: $showRightPicker) {
            LanguageSelectorView(selectedLanguage: $rightLanguage)
                #if os(iOS)
                .presentationDetents([.medium])
                #endif
        }
    }

    /// Header row: red-tinted left language pill, swap/clear toolbar, blue-tinted right language pill.
    /// All buttons use Liquid Glass and live inside a `GlassEffectContainer` so their shapes can blend.
    private var languageHeader: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    showLeftPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .shadow(color: .red.opacity(0.6), radius: 4)
                        Text("\(leftLanguage.flag) \(leftLanguage.displayName)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(
                        .regular.tint(.red.opacity(0.18)).interactive(),
                        in: .capsule
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Button(action: onSwap) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)

                    if !messages.isEmpty {
                        Button(action: onClear) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }

                Spacer(minLength: 4)

                Button {
                    showRightPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text("\(rightLanguage.displayName) \(rightLanguage.flag)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                            .shadow(color: .blue.opacity(0.6), radius: 4)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(
                        .regular.tint(.blue.opacity(0.18)).interactive(),
                        in: .capsule
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private func liveTextBubble(text: String, label: String, side: PanelSide) -> some View {
        VStack(alignment: side == .left ? .leading : .trailing, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    (side == .left ? Color.red : Color.blue).opacity(0.1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            (side == .left ? Color.red : Color.blue).opacity(0.3),
                            lineWidth: 1
                        )
                )
        )
        .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
    }
}
