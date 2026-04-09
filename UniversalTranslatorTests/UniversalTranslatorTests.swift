import Foundation
import Testing
import MLXAudioTTS
import MLXAudioCore
import MLX

/// Sanity tests for the Kokoro TTS pipeline.
///
/// These tests must run on a physical device or macOS — MLX requires a real Metal GPU
/// and will fail in the iOS Simulator.
@Suite("Kokoro TTS")
struct KokoroTTSTests {

    @Test("Model loads and is KokoroModel type")
    func modelLoads() async throws {
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")
        #expect(model is KokoroModel, "Expected KokoroModel but got \(type(of: model))")
        #expect(model.sampleRate == 24000, "Expected 24kHz sample rate")
    }

    @Test("TextProcessor is accessible and is KokoroMultilingualProcessor")
    func textProcessorAccessible() async throws {
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")
        let kokoro = try #require(model as? KokoroModel)
        let processor = try #require(kokoro.textProcessor, "textProcessor is nil")
        print("textProcessor type: \(type(of: processor))")
        #expect(processor is KokoroMultilingualProcessor, "Expected KokoroMultilingualProcessor but got \(type(of: processor))")
    }

    @Test("English G2P produces phonemes")
    func englishG2P() async throws {
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")
        let kokoro = try #require(model as? KokoroModel)
        let processor = try #require(kokoro.textProcessor)

        let phonemes = try processor.process(text: "Hello, this is a test.", language: "en-us")
        print("English phonemes: '\(phonemes)'")
        #expect(phonemes.count > 5, "English phonemes too short: \(phonemes.count) chars")
    }

    @Test("Japanese G2P produces phonemes")
    func japaneseG2P() async throws {
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")
        let kokoro = try #require(model as? KokoroModel)
        let processor = try #require(kokoro.textProcessor)

        // Prepare Japanese G2P (downloads ByT5 model if needed)
        if let multilingual = processor as? KokoroMultilingualProcessor {
            try await multilingual.prepare(for: "ja")
            print("Japanese G2P prepared via KokoroMultilingualProcessor")
        } else {
            try await processor.prepare()
            print("Japanese G2P prepared via base TextProcessor")
        }

        let phonemes = try processor.process(text: "こんにちは、これはテストです。", language: "ja")
        print("Japanese phonemes: '\(phonemes)' (\(phonemes.count) chars)")
        #expect(phonemes.count > 5, "Japanese phonemes too short: \(phonemes.count) chars — G2P likely failed")
    }

    @Test("English TTS generates reasonable audio")
    func englishTTSGeneration() async throws {
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")

        let audio = try await model.generate(
            text: "Hello, this is a test of English speech synthesis.",
            voice: "af_heart",
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: model.defaultGenerationParameters
        )

        let samples = audio.shape[0]
        let duration = Float(samples) / Float(model.sampleRate)
        print("English TTS: \(samples) samples, \(String(format: "%.2f", duration))s")
        #expect(duration > 1.0, "English audio too short: \(duration)s — expected >1s for this text")
        #expect(duration < 15.0, "English audio too long: \(duration)s — likely looping")
    }

    @Test("Japanese TTS generates reasonable audio")
    func japaneseTTSGeneration() async throws {
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")

        let audio = try await model.generate(
            text: "こんにちは、これはテストです。",
            voice: "jf_alpha",
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: model.defaultGenerationParameters
        )

        let samples = audio.shape[0]
        let duration = Float(samples) / Float(model.sampleRate)
        print("Japanese TTS: \(samples) samples, \(String(format: "%.2f", duration))s")
        #expect(duration > 1.0, "Japanese audio too short: \(duration)s — G2P likely not working")
        #expect(duration < 15.0, "Japanese audio too long: \(duration)s")
    }

    @Test("All supported language voices generate audio", arguments: [
        ("af_heart", "Hello, this is a test.", "English"),
        ("jf_alpha", "こんにちは、これはテストです。", "Japanese"),
        ("zf_xiaobei", "你好，这是一个测试。", "Chinese"),
        ("ef_dora", "Hola, esto es una prueba.", "Spanish"),
        ("ff_siwis", "Bonjour, ceci est un test.", "French"),
        ("if_sara", "Ciao, questo è un test.", "Italian"),
        ("pf_dora", "Olá, isto é um teste.", "Portuguese"),
        ("hf_alpha", "नमस्ते, यह एक परीक्षा है।", "Hindi"),
    ])
    func allLanguageTTS(voice: String, text: String, language: String) async throws {
        let model = try await TTS.loadModel(modelRepo: "mlx-community/Kokoro-82M-bf16")

        let audio = try await model.generate(
            text: text,
            voice: voice,
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: model.defaultGenerationParameters
        )

        let samples = audio.shape[0]
        let duration = Float(samples) / Float(model.sampleRate)
        print("\(language) TTS (\(voice)): \(samples) samples, \(String(format: "%.2f", duration))s")
        #expect(duration > 0.5, "\(language) audio too short: \(duration)s")
    }
}
