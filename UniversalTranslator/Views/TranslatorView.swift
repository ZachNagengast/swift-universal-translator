import SwiftUI

/// Main app screen. Layout (top → bottom):
///   1. Conversation panel — language pickers, message bubbles, live ASR text
///   2. Two press-and-hold mic buttons (red = left language, blue = right)
///   3. Skeuomorphic speaker grille that pulses while TTS plays (tap to stop)
struct TranslatorView: View {
    @Bindable var viewModel: TranslatorViewModel

    private var leftListening: Bool {
        if case .listening(.left) = viewModel.pipelineState { return true }
        return false
    }

    private var rightListening: Bool {
        if case .listening(.right) = viewModel.pipelineState { return true }
        return false
    }

    /// Mic buttons are disabled while the pipeline is mid-translation or speaking,
    /// to prevent overlapping inferences.
    private var micDisabled: Bool {
        switch viewModel.pipelineState {
        case .translating, .speaking: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationView(
                messages: viewModel.messages,
                liveTranscription: viewModel.liveTranscription,
                liveTranslation: viewModel.liveTranslation,
                pipelineState: viewModel.pipelineState,
                activeSide: viewModel.activeSide,
                onReplay: { message in
                    Task { await viewModel.replayTTS(for: message) }
                },
                onClear: { viewModel.clearConversation() },
                leftLanguage: $viewModel.leftLanguage,
                rightLanguage: $viewModel.rightLanguage,
                onSwap: { viewModel.swapLanguages() }
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer(minLength: 16)

            if case .error(let message) = viewModel.pipelineState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            // The two mic buttons live inside a GlassEffectContainer so their Liquid Glass
            // shapes can morph and react to each other when one becomes active.
            GlassEffectContainer(spacing: 60) {
                HStack(spacing: 48) {
                    MicrophoneButtonView(
                        color: .red,
                        label: viewModel.leftLanguage.displayName,
                        isListening: leftListening,
                        isDisabled: micDisabled || rightListening,
                        onPressStart: {
                            Task { await viewModel.startListeningPublic(side: .left) }
                        },
                        onPressEnd: {
                            Task { await viewModel.stopListeningPublic() }
                        }
                    )

                    MicrophoneButtonView(
                        color: .blue,
                        label: viewModel.rightLanguage.displayName,
                        isListening: rightListening,
                        isDisabled: micDisabled || leftListening,
                        onPressStart: {
                            Task { await viewModel.startListeningPublic(side: .right) }
                        },
                        onPressEnd: {
                            Task { await viewModel.stopListeningPublic() }
                        }
                    )
                }
            }
            .padding(.top, 8)

            SpeakerGrilleView(
                isSpeaking: viewModel.pipelineState == .speaking,
                onTapToStop: { viewModel.stopSpeaking() }
            )
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }
}
