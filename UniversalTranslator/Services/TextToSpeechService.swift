import Foundation
import MLXAudioTTS
import MLXAudioCore
import MLX
import NaturalLanguage

/// Text-to-speech service backed by Kokoro TTS running on Metal via MLX.
///
/// Pipeline highlights:
/// - **Kokoro 82M (bf16)** — multilingual TTS in 9 languages with 50+ built-in voices.
///   Language is auto-detected from the voice prefix (`af_*` = American English, `jf_*` = Japanese, etc.).
/// - **Lexicon pre-download.** All non-English G2P lexicons are fetched at app launch
///   so first-use of any language doesn't fail with `lexiconNotFound`.
/// - **MLX memory management.** We cap the buffer cache at 256MB and call `clearCache()`
///   after every inference. Without this, memory grows unbounded across many translations
///   and the app eventually OOMs on iPhone.
/// - **Streaming playback.** Audio chunks are scheduled into an `AVAudioEngine` as they
///   come out of the model, so playback starts well before generation finishes.
/// - **Interruptible.** Tap the speaker grille while speaking → `stop()` flips a flag
///   that the streaming loop checks, then drains the player.
@Observable
@MainActor
final class TextToSpeechService {
    private(set) var isLoaded = false
    private(set) var isSpeaking = false
    private(set) var loadingProgress: Double = 0

    private var ttsModel: (any SpeechGenerationModel)?
    private var kokoroModel: KokoroModel?

    /// Direct reference to the multilingual processor we inject.
    /// Held strongly so we can call language-specific `prepare(for:)` without runtime casts.
    private var multilingualProcessor: KokoroMultilingualProcessor?

    private var audioPlayer: AudioPlayer?

    /// Set by `stop()`; checked inside the streaming loop and the playback wait loop
    /// so the user can interrupt long-running TTS at any point.
    private var stopRequested = false

    init() {
        // Cap MLX cache at 256 MB so it can't grow unbounded across many inferences.
        // Kokoro 82M's working set is well under this; the cap just prevents the
        // recycled-buffer pool from holding onto memory indefinitely.
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }

    /// Load the Kokoro model and pre-download G2P lexicons for all supported languages.
    func loadModel() async throws {
        print("[TTS] Loading Kokoro TTS model...")
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")
        ttsModel = model
        audioPlayer = AudioPlayer()
        loadingProgress = 0.3

        if let kokoro = model as? KokoroModel {
            kokoroModel = kokoro
            print("[TTS] KokoroModel loaded. Initial textProcessor: \(kokoro.textProcessor.map { String(describing: type(of: $0)) } ?? "nil")")

            // Explicitly install the multilingual phonemizer. Kokoro routes text through
            // a `TextProcessor` to convert words to phonemes (English uses Misaki/CMUdict;
            // other languages use IPA lexicons or a small ByT5 neural G2P model).
            // We hold a strong reference so we can pre-warm language-specific resources below.
            let processor = KokoroMultilingualProcessor()
            kokoro.setTextProcessor(processor)
            multilingualProcessor = processor
            print("[TTS] Installed KokoroMultilingualProcessor")
        }

        // Pre-download G2P lexicons for every non-English language.
        // English uses Misaki (built-in, no download). Other languages use either an IPA
        // lexicon TSV (Spanish, French, etc.) or a small ByT5 neural G2P model (JA, ZH, HI).
        // Without this step the first call for each language hits a `lexiconNotFound` error.
        if let processor = multilingualProcessor {
            print("[TTS] Pre-downloading lexicons for all supported languages...")
            let languageCodes = ["es", "fr", "it", "pt", "ja", "cmn", "hi"]
            for (index, code) in languageCodes.enumerated() {
                do {
                    try await processor.prepare(for: code)
                    print("[TTS] Prepared lexicon: \(code)")
                } catch {
                    print("[TTS] Failed to prepare \(code): \(error)")
                }
                loadingProgress = 0.3 + (0.6 * Double(index + 1) / Double(languageCodes.count))
            }
        }

        isLoaded = true
        loadingProgress = 1.0
        print("[TTS] Kokoro TTS fully ready")
    }

    /// Kokoro's hard limit is 510 phoneme tokens (KokoroModel.maxTokenCount).
    /// We target slightly below to leave room for start/end tokens the model prepends.
    private static let maxPhonemeTokens = 500

    /// Stream-synthesize `text` in `language` and play it through the speaker.
    /// For long text, phonemizes first, then chunks at sentence boundaries to stay
    /// within Kokoro's 510 phoneme-token limit. Cancellable via `stop()`.
    func speak(text: String, language: Language) async throws {
        guard let model = ttsModel, let player = audioPlayer else {
            print("[TTS] ERROR: model or player not loaded")
            return
        }

        // Phonemize the full text so we can measure actual token counts for chunking.
        // Kokoro's tokenizer maps each IPA character to one token, so
        // phoneme string length == token count.
        let lang = KokoroMultilingualProcessor.languageForVoice(language.kokoroVoice)
        let chunks: [String]
        if let processor = kokoroModel?.textProcessor {
            do {
                let phonemized = try processor.process(text: text, language: lang)
                if phonemized.count <= Self.maxPhonemeTokens {
                    // Fits in one shot — pass original text (model will re-phonemize internally)
                    chunks = [text]
                } else {
                    // Too long — split original text at sentence boundaries and
                    // verify each chunk's phoneme count fits
                    chunks = try chunkBySentence(text: text, language: lang, processor: processor)
                }
            } catch {
                print("[TTS] Phonemization failed, falling back to character chunking: \(error)")
                chunks = chunkByCharCount(text)
            }
        } else {
            chunks = chunkByCharCount(text)
        }

        print("[TTS] Speaking \(chunks.count) chunk(s) in \(language.displayName) voice=\(language.kokoroVoice)")

        isSpeaking = true
        stopRequested = false

        player.startStreaming(sampleRate: Double(model.sampleRate))

        var totalSamples = 0
        do {
            for (i, chunk) in chunks.enumerated() {
                if stopRequested { break }

                print("[TTS] Chunk \(i + 1)/\(chunks.count): '\(chunk.prefix(60))...' (\(chunk.count) chars)")

                let stream = model.generateStream(
                    text: chunk,
                    voice: language.kokoroVoice,
                    refAudio: nil,
                    refText: nil,
                    language: nil,
                    generationParameters: model.defaultGenerationParameters
                )

                for try await event in stream {
                    if stopRequested { break }
                    if case .audio(let samples) = event {
                        let floatSamples = samples.asArray(Float.self)
                        player.scheduleAudioChunk(floatSamples, withCrossfade: true)
                        totalSamples += floatSamples.count
                    }
                }
            }

            if stopRequested {
                player.stopStreaming()
            } else {
                player.finishStreamingInput()
                let durationSec = Double(totalSamples) / Double(model.sampleRate)
                print("[TTS] Done: \(totalSamples) samples, \(String(format: "%.2f", durationSec))s audio")

                while player.isSpeaking {
                    if stopRequested {
                        print("[TTS] Stop requested during playback")
                        player.stopStreaming()
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                print("[TTS] Playback finished")
            }
        } catch {
            print("[TTS] ERROR: \(error)")
            player.stopStreaming()
            isSpeaking = false
            stopRequested = false
            MLX.Memory.clearCache()
            throw error
        }

        isSpeaking = false
        stopRequested = false

        // Free GPU buffers from this inference so memory stays flat across many runs.
        MLX.Memory.clearCache()
        let snap = MLX.Memory.snapshot()
        print("[TTS] Memory after clear: active=\(snap.activeMemory / 1024 / 1024)MB cache=\(snap.cacheMemory / 1024 / 1024)MB")
    }

    /// Split text at sentence boundaries, greedily merging sentences until
    /// the phonemized token count would exceed `maxPhonemeTokens`.
    private func chunkBySentence(text: String, language: String?, processor: TextProcessor) throws -> [String] {
        let sentences = splitSentences(text)
        var chunks: [String] = []
        var currentChunk = ""

        for sentence in sentences {
            let candidate = currentChunk.isEmpty ? sentence : currentChunk + " " + sentence
            let phonemeCount = (try? processor.process(text: candidate, language: language))?.count ?? candidate.count

            if phonemeCount > Self.maxPhonemeTokens && !currentChunk.isEmpty {
                // Adding this sentence exceeds the limit — flush the current chunk
                chunks.append(currentChunk)
                currentChunk = sentence
            } else {
                currentChunk = candidate
            }
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }

        print("[TTS] Chunked \(sentences.count) sentences into \(chunks.count) chunk(s)")
        return chunks
    }

    /// Fallback chunker when phonemization isn't available.
    /// Uses a conservative character estimate (1 token ~ 2 chars for IPA).
    private func chunkByCharCount(_ text: String) -> [String] {
        let maxChars = Self.maxPhonemeTokens * 2
        if text.count <= maxChars { return [text] }

        let sentences = splitSentences(text)
        var chunks: [String] = []
        var chunk = ""
        for sentence in sentences {
            if chunk.count + sentence.count + 1 > maxChars && !chunk.isEmpty {
                chunks.append(chunk)
                chunk = sentence
            } else {
                chunk += (chunk.isEmpty ? "" : " ") + sentence
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    /// Split text into sentences using Apple's NLTokenizer, which handles
    /// sentence boundaries correctly across all supported languages (including
    /// Japanese, Chinese, etc. where punctuation rules differ from English).
    private func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        // If the tokenizer returned nothing (shouldn't happen), treat the whole text as one sentence
        return sentences.isEmpty ? [text] : sentences
    }

    /// Interrupt any in-progress generation or playback.
    func stop() {
        print("[TTS] stop() called")
        stopRequested = true
        audioPlayer?.stopStreaming()
        isSpeaking = false
    }
}
