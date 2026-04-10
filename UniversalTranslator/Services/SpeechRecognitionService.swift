import Foundation
@preconcurrency import WhisperKit

/// Speech-to-text service backed by WhisperKit running on the Apple Neural Engine.
///
/// This service is the first stage of the translation pipeline. It:
///   1. Downloads a Whisper CoreML model on first launch (or loads from cache).
///   2. Pre-warms the AVAudioEngine so the first mic press is instant.
///   3. Streams transcription as the user speaks via `AudioStreamTranscriber`.
///   4. Filters out known Whisper hallucinations (e.g. "Thanks for watching") that
///      appear when the model is fed silence or low-energy audio.
///
/// We use the quantized "small" variant (`openai_whisper-small_216MB`) for a good
/// balance of quality and on-device speed.
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
    private var audioEngineWarmed = false

    /// WhisperKit's placeholder text emitted before any speech is detected.
    /// We strip this so it doesn't accidentally get sent through the translation pipeline.
    private static let whisperKitPlaceholder = "Waiting for speech..."

    /// Common Whisper hallucinations on silence or noise. The training data
    /// included a lot of YouTube transcripts, so it loves to insert these on quiet input.
    private static let hallucinationPatterns: [String] = [
        "thank you",
        "thanks for watching",
        "subscribe",
        "like and subscribe",
        "please subscribe",
        "the end",
        "you",
        "bye",
        "...",
        "♪",
        "music",
    ]

    /// WhisperKit model variant. The `_216MB` suffix is a quantized small model
    /// that runs in ~150ms per chunk on iPhone 15 Pro / Apple Silicon Macs.
    private static let modelVariant = "openai_whisper-small_216MB"
    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// Loads the Whisper CoreML model, preferring an on-disk cache if available.
    /// Also pre-warms the audio engine so the first recording press has zero startup latency.
    func loadModel() async throws {
        let config = WhisperKitConfig(
            verbose: true,
            logLevel: .error,
            load: false,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        guard let whisperKit else { return }

        // Skip the network round-trip if the model is already on disk.
        // WhisperKit's HubApi caches under Documents/huggingface/models/<repo>/<variant>.
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

        await warmAudioEngine()

        isLoaded = true
        loadingProgress = 1.0
        print("[ASR] WhisperKit model loaded and audio engine pre-warmed")
    }

    /// Briefly start and stop the audio engine after model load.
    /// Without this the first user-initiated recording incurs a multi-hundred-ms cold start.
    private func warmAudioEngine() async {
        guard let whisperKit, !audioEngineWarmed else { return }
        print("[ASR] Pre-warming audio engine...")
        do {
            try whisperKit.audioProcessor.startRecordingLive { _ in }
            try? await Task.sleep(for: .milliseconds(500))
            whisperKit.audioProcessor.stopRecording()
            audioEngineWarmed = true
            print("[ASR] Audio engine pre-warmed")
        } catch {
            print("[ASR] Audio engine pre-warm failed: \(error.localizedDescription)")
        }
    }

    /// Begin streaming microphone audio and transcribing it in real time.
    ///
    /// Pass the source language explicitly so Whisper doesn't have to detect it
    /// (forcing the language is faster and more accurate when we already know it).
    func startRecording(language: Language) async throws {
        guard let whisperKit, !isRecording else { return }

        currentTranscription = ""
        confirmedText = ""

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

        guard let tokenizer = whisperKit.tokenizer else {
            throw SpeechRecognitionError.tokenizerNotLoaded
        }

        print("[ASR] Starting recording in \(language.displayName)")

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
                    guard let self else { return }
                    let confirmed = newState.confirmedSegments.map(\.text).joined(separator: " ")
                    let current = newState.currentText
                    let combined = (confirmed + " " + current).trimmingCharacters(in: .whitespaces)

                    // Don't surface the placeholder or known hallucinations to the UI.
                    if combined == Self.whisperKitPlaceholder { return }
                    if !self.isHallucination(combined) {
                        self.confirmedText = confirmed
                        self.currentTranscription = combined
                    }
                }
            }
        )

        isRecording = true

        Task {
            do {
                try await streamTranscriber?.startStreamTranscription()
            } catch {
                print("[ASR] Stream transcription error: \(error.localizedDescription)")
            }
        }
    }

    /// Stops recording and returns the cleaned final transcription.
    /// Returns an empty string if the result was filtered as a hallucination or placeholder.
    func stopRecording() async -> String {
        await streamTranscriber?.stopStreamTranscription()
        isRecording = false

        let finalText = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[ASR] Recording stopped. Final text: '\(finalText)'")

        currentTranscription = ""
        confirmedText = ""
        streamTranscriber = nil

        if finalText == Self.whisperKitPlaceholder || isHallucination(finalText) || finalText.count < 2 {
            print("[ASR] Filtered: '\(finalText)'")
            return ""
        }
        return finalText
    }

    private func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if lower.isEmpty { return true }
        for pattern in Self.hallucinationPatterns {
            if lower == pattern || lower.hasPrefix(pattern) {
                return true
            }
        }
        return false
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
