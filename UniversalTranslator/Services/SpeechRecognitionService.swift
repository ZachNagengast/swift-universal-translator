import Foundation
@preconcurrency import WhisperKit

/// Speech-to-text service backed by WhisperKit running on the Apple Neural Engine.
///
/// The transcription pipeline runs continuously after model loading with input
/// suppressed (silence injected). When the user presses a mic button, input is
/// unsuppressed and live transcription begins immediately with zero cold-start.
/// On release, input is suppressed again and the accumulated text is returned.
@Observable
@MainActor
final class SpeechRecognitionService {
    private(set) var isLoaded = false
    private(set) var isRecording = false
    private(set) var loadingProgress: Double = 0
    private(set) var currentTranscription = ""
    private(set) var confirmedText = ""

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    /// The language currently configured for the running transcriber.
    private var activeLanguage: Language?

    private static let modelVariant = "openai_whisper-small_216MB"
    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// Loads the Whisper CoreML model, requests mic permission, and starts the
    /// transcription pipeline in suppressed mode so it's ready for instant use.
    func loadModel() async throws {
        let config = WhisperKitConfig(
            verbose: true,
            logLevel: .error,
            load: false,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        guard let whisperKit else { return }

        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let cachedModelDir = documentsURL
            .appending(path: "huggingface/models/\(Self.modelRepo)/\(Self.modelVariant)")

        let folder: URL
        if FileManager.default.fileExists(atPath: cachedModelDir.path) {
            print("[ASR] Using cached WhisperKit model at: \(cachedModelDir.path)")
            folder = cachedModelDir
            loadingProgress = 1.0
        } else {
            print("[ASR] Downloading WhisperKit model: \(Self.modelVariant)")
            folder = try await WhisperKit.download(
                variant: Self.modelVariant,
                from: Self.modelRepo
            ) { @Sendable [weak self] progress in
                Task { @MainActor in
                    self?.loadingProgress = progress.fractionCompleted
                }
            }
            print("[ASR] Downloaded to: \(folder.path)")
        }

        whisperKit.modelFolder = folder
        try await whisperKit.prewarmModels()
        try await whisperKit.loadModels()

        let granted = await AudioProcessor.requestRecordPermission()
        print("[ASR] Microphone permission: \(granted ? "granted" : "denied")")

        // Start the pipeline immediately in suppressed mode. The audio engine
        // stays warm and the first mic press unsuppresses with zero latency.
        await startPipeline(language: .english)
        (whisperKit.audioProcessor as? AudioProcessor)?.setInputSuppressed(true)

        isLoaded = true
        loadingProgress = 1.0
        print("[ASR] WhisperKit model loaded, pipeline running (suppressed)")
    }

    /// Start a fresh recording session. Recreates the AudioStreamTranscriber
    /// so accumulated segments from previous recordings don't carry over.
    /// The audioProcessor (and its AVAudioEngine) stays alive — only the
    /// transcriber is recreated, which is cheap.
    func startRecording(language: Language) async throws {
        guard let whisperKit else { return }

        // Tear down old transcriber to clear accumulated segments
        await stopPipeline()

        currentTranscription = ""
        confirmedText = ""

        // Create fresh transcriber with clean state
        await startPipeline(language: language)

        // Unsuppress — real audio starts flowing
        (whisperKit.audioProcessor as? AudioProcessor)?.setInputSuppressed(false)
        isRecording = true
        print("[ASR] Recording started in \(language.displayName)")
    }

    /// Suppress audio input and return the final transcription.
    func stopRecording() async -> String {
        guard let whisperKit else { return "" }

        // Suppress — silence injected, pipeline keeps running
        (whisperKit.audioProcessor as? AudioProcessor)?.setInputSuppressed(true)
        isRecording = false

        let finalText = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[ASR] Recording stopped. Final text: '\(finalText)'")

        currentTranscription = ""
        confirmedText = ""

        return finalText
    }

    // MARK: - Pipeline lifecycle

    /// Start the AudioStreamTranscriber for the given language.
    private func startPipeline(language: Language) async {
        guard let whisperKit, streamTranscriber == nil else { return }
        guard let tokenizer = whisperKit.tokenizer else {
            print("[ASR] ERROR: tokenizer not loaded")
            return
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.whisperCode,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            noSpeechThreshold: 0.5
        )

        streamTranscriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            silenceThreshold: 0.3,
            stateChangeCallback: { @Sendable [weak self] _, newState in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }

                    let confirmed = newState.confirmedSegments.map(\.text).joined()
                    let unconfirmed = newState.unconfirmedSegments.map(\.text).joined()
                    let fullText = (confirmed + unconfirmed).trimmingCharacters(in: .whitespaces)

                    self.confirmedText = confirmed.trimmingCharacters(in: .whitespaces)
                    self.currentTranscription = fullText

                    print("[ASR] confirmed(\(newState.confirmedSegments.count)): '\(self.confirmedText)'")
                    print("[ASR] unconfirmed(\(newState.unconfirmedSegments.count)): '\(unconfirmed.trimmingCharacters(in: .whitespaces))'")
                }
            }
        )

        activeLanguage = language

        Task {
            do {
                try await streamTranscriber?.startStreamTranscription()
            } catch {
                print("[ASR] Stream transcription error: \(error.localizedDescription)")
            }
        }

        print("[ASR] Pipeline started for \(language.displayName)")
    }

    /// Stop and tear down the current AudioStreamTranscriber.
    private func stopPipeline() async {
        await streamTranscriber?.stopStreamTranscription()
        streamTranscriber = nil
        activeLanguage = nil
        print("[ASR] Pipeline stopped")
    }
}

enum SpeechRecognitionError: LocalizedError {
    case tokenizerNotLoaded

    var errorDescription: String? {
        switch self {
        case .tokenizerNotLoaded: "WhisperKit tokenizer not loaded"
        }
    }
}
