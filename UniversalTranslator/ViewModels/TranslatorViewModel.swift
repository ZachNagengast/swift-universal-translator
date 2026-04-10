import Foundation
import FoundationModels

/// State machine for the translation pipeline.
///
/// Transitions:
///   `.idle` → `.listening` → `.translating` → `.speaking` → `.idle`
/// Errors transition to `.error` and auto-recover back to `.idle` after 2 seconds
/// so the user is never stuck.
enum PipelineState: Equatable {
    case idle
    case listening(PanelSide)
    case translating
    case speaking
    case error(String)

    static func == (lhs: PipelineState, rhs: PipelineState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.translating, .translating), (.speaking, .speaking): true
        case (.listening(let a), .listening(let b)): a == b
        case (.error(let a), .error(let b)): a == b
        default: false
        }
    }
}

/// Orchestrates the full ASR → Translation → TTS pipeline.
///
/// Loads the WhisperKit and Kokoro models in parallel on startup (they target the
/// Neural Engine and GPU respectively, so loading them concurrently is faster than
/// sequential). Owns the conversation history, current language pair, and pipeline state.
@Observable
@MainActor
final class TranslatorViewModel {
    // MARK: - User-facing state

    var leftLanguage: Language = .english {
        didSet { UserDefaults.standard.set(leftLanguage.rawValue, forKey: "leftLanguage") }
    }
    var rightLanguage: Language = .japanese {
        didSet { UserDefaults.standard.set(rightLanguage.rawValue, forKey: "rightLanguage") }
    }
    var messages: [TranslationMessage] = []
    var pipelineState: PipelineState = .idle
    /// During recording, reads directly from the speech service's observable property.
    /// After recording stops, shows the frozen final text until the bubble is created.
    var liveTranscription: String {
        if case .listening = pipelineState {
            return speechService.currentTranscription
        }
        return frozenTranscription
    }
    private var frozenTranscription = ""
    var liveTranslation = ""
    /// Which side is currently active in the pipeline (drives chat-bubble alignment).
    var activeSide: PanelSide?

    // MARK: - Services

    let speechService: SpeechRecognitionService
    let translationService: TranslationService
    let ttsService: TextToSpeechService

    // MARK: - Loading state

    var isLoading = true
    var whisperProgress: Double = 0
    var ttsProgress: Double = 0
    var loadingStatus = ""

    init(
        speechService: SpeechRecognitionService,
        translationService: TranslationService,
        ttsService: TextToSpeechService
    ) {
        self.speechService = speechService
        self.translationService = translationService
        self.ttsService = ttsService

        if let raw = UserDefaults.standard.string(forKey: "leftLanguage"),
           let lang = Language(rawValue: raw) {
            self.leftLanguage = lang
        }
        if let raw = UserDefaults.standard.string(forKey: "rightLanguage"),
           let lang = Language(rawValue: raw) {
            self.rightLanguage = lang
        }
    }

    // MARK: - Model loading

    /// Loads WhisperKit and Kokoro in parallel — they don't compete for hardware
    /// (WhisperKit runs on the ANE, Kokoro on the GPU/Metal) so concurrent loading
    /// roughly halves total startup time on first launch.
    /// Computed status derived from service loading progress.
    var loadingStatusText: String {
        if speechService.loadingProgress >= 1.0 && ttsService.loadingProgress >= 1.0 {
            return "Loading models..."
        }
        return "Downloading models..."
    }

    func loadModels() async {
        print("[Pipeline] Loading WhisperKit (ANE) and Kokoro (GPU) in parallel")

        async let asrLoad: Void = {
            do {
                try await self.speechService.loadModel()
                print("[Pipeline] WhisperKit loaded")
            } catch {
                print("[Pipeline] WhisperKit load failed: \(error.localizedDescription)")
                await MainActor.run { self.loadingStatus = "ASR error: \(error.localizedDescription)" }
            }
        }()
        async let ttsLoad: Void = {
            do {
                try await self.ttsService.loadModel()
                print("[Pipeline] Kokoro TTS loaded")
            } catch {
                print("[Pipeline] TTS load failed: \(error.localizedDescription)")
                await MainActor.run { self.loadingStatus = "TTS error: \(error.localizedDescription)" }
            }
        }()
        _ = await (asrLoad, ttsLoad)

        translationService.checkAvailability()
        print("[Pipeline] FoundationModels available: \(translationService.isAvailable)")
        loadingStatus = "Ready"
        isLoading = false
    }

    // MARK: - User actions

    /// Called when the user presses and holds a mic button.
    /// Auto-recovers from any lingering error state so a press always feels responsive.
    func startListeningPublic(side: PanelSide) async {
        if case .error = pipelineState {
            print("[Pipeline] Auto-recovering from error state on mic press")
            pipelineState = .idle
            activeSide = nil
        }
        guard pipelineState == .idle else {
            print("[Pipeline] Cannot start listening — pipeline busy: \(String(describing: pipelineState))")
            return
        }
        print("[Pipeline] Press started on \(side == .left ? "left" : "right")")
        await startListening(side: side)
    }

    /// Called when the user releases the mic button.
    func stopListeningPublic() async {
        guard case .listening = pipelineState else { return }
        print("[Pipeline] Press released — stopping recording")
        await stopListening()
    }

    func swapLanguages() {
        let temp = leftLanguage
        leftLanguage = rightLanguage
        rightLanguage = temp
        print("[Pipeline] Languages swapped: left=\(leftLanguage.displayName), right=\(rightLanguage.displayName)")
    }

    func clearConversation() {
        messages.removeAll()
        frozenTranscription = ""
        liveTranslation = ""
        if case .error = pipelineState {
            pipelineState = .idle
            activeSide = nil
        }
        print("[Pipeline] Conversation cleared")
    }

    /// Replay TTS for a previously translated message (tap the chat bubble).
    func replayTTS(for message: TranslationMessage) async {
        guard pipelineState == .idle else { return }
        pipelineState = .speaking
        do {
            try await ttsService.speak(text: message.translatedText, language: message.targetLanguage)
        } catch {
            print("[Pipeline] Replay TTS error: \(error.localizedDescription)")
        }
        pipelineState = .idle
    }

    /// Interrupt TTS playback — wired to a tap on the speaker grille while speaking.
    /// Useful when the LLM hallucinates a long, wrong translation.
    func stopSpeaking() {
        guard pipelineState == .speaking else { return }
        print("[Pipeline] User stopped TTS playback")
        ttsService.stop()
        pipelineState = .idle
        activeSide = nil
    }

    // MARK: - Pipeline implementation

    private func startListening(side: PanelSide) async {
        let sourceLanguage = side == .left ? leftLanguage : rightLanguage
        pipelineState = .listening(side)
        activeSide = side
        frozenTranscription = ""
        liveTranslation = ""

        print("[Pipeline] Starting ASR in \(sourceLanguage.displayName) for \(side == .left ? "left" : "right") side")

        do {
            try await speechService.startRecording(language: sourceLanguage)
        } catch {
            print("[Pipeline] Mic error: \(error.localizedDescription)")
            transitionToError("Mic error — try again")
        }
    }

    private func stopListening() async {
        guard case .listening(let side) = pipelineState else { return }

        let transcribedText = await speechService.stopRecording()
        print("[Pipeline] ASR result: '\(transcribedText)' (length: \(transcribedText.count))")

        guard !transcribedText.isEmpty else {
            print("[Pipeline] Empty transcription — returning to idle")
            pipelineState = .idle
            activeSide = nil
            frozenTranscription = ""
            return
        }

        frozenTranscription = transcribedText
        let source = side == .left ? leftLanguage : rightLanguage
        let target = side == .left ? rightLanguage : leftLanguage

        print("[Pipeline] Translate: \(source.displayName) → \(target.displayName)")
        await runTranslationPipeline(transcribedText: transcribedText, from: source, to: target, side: side)
    }

    private func runTranslationPipeline(
        transcribedText: String,
        from source: Language,
        to target: Language,
        side: PanelSide
    ) async {
        pipelineState = .translating
        liveTranslation = ""

        do {
            let result = try await translationService.translateStreaming(
                text: transcribedText,
                from: source,
                to: target
            ) { [weak self] partial in
                Task { @MainActor in
                    self?.liveTranslation = partial
                }
            }

            print("[Pipeline] Translation result: '\(result.translatedText)' | Corrections: '\(result.corrections)'")

            // Materialize the chat bubble immediately so the user sees the result
            // even if TTS later fails or gets interrupted.
            let message = TranslationMessage(
                originalText: transcribedText,
                translatedText: result.translatedText,
                sourceLanguage: source,
                targetLanguage: target,
                timestamp: Date(),
                side: side,
                corrections: result.corrections,
                llmPrompt: result.prompt
            )
            messages.append(message)
            frozenTranscription = ""
            liveTranslation = ""

            // Speak the translation in the target language.
            pipelineState = .speaking
            print("[Pipeline] TTS: speaking '\(result.translatedText)' in \(target.displayName) voice=\(target.kokoroVoice)")
            do {
                try await ttsService.speak(text: result.translatedText, language: target)
            } catch {
                // TTS errors are non-fatal — the bubble is already shown.
                print("[Pipeline] TTS error (non-fatal): \(error.localizedDescription)")
            }

            pipelineState = .idle
            activeSide = nil
        } catch let error as TranslationError {
            switch error {
            case .refused(let reason):
                print("[Pipeline] Model refused: \(reason)")
                transitionToError(reason)
            case .emptyResponse:
                print("[Pipeline] Empty translation")
                transitionToError("Translation returned empty — try again")
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                print("[Pipeline] Guardrail violation — content flagged as unsafe")
                transitionToError("Content flagged by safety filter")
            default:
                print("[Pipeline] LLM error: \(error.localizedDescription)")
                transitionToError("Translation failed — try again")
            }
        } catch {
            print("[Pipeline] Translation failed: \(error.localizedDescription)")
            transitionToError("Translation failed — try again")
        }
    }

    /// Briefly flash an error state, then auto-reset to idle so the user isn't stuck.
    /// Cancels any previous recovery timer so rapid errors don't stack up.
    private var errorRecoveryTask: Task<Void, Never>?

    private func transitionToError(_ message: String) {
        pipelineState = .error(message)
        activeSide = nil
        frozenTranscription = ""
        liveTranslation = ""

        errorRecoveryTask?.cancel()
        errorRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if case .error = self?.pipelineState {
                self?.pipelineState = .idle
            }
        }
    }

}
