# Universal Translator

A fully on-device universal translator built with Swift and SwiftUI. Speech recognition, translation, and speech synthesis all run locally on Apple silicon — no network calls after the initial model downloads.

## Pipeline

```text
🎙  Microphone
    │
    ▼
[ WhisperKit (ANE) ]              speech → text
    │
    ▼
[ FoundationModels (Apple LLM) ]  text → translated text
    │
    ▼
[ Kokoro TTS (Metal/MLX) ]        text → audio
    │
    ▼
🔊  Speaker
```

| Stage | Framework | Model | Where it runs |
| --- | --- | --- | --- |
| ASR | [WhisperKit](https://github.com/argmaxinc/WhisperKit) | `openai_whisper-small_216MB` (quantized) | Apple Neural Engine |
| Translation | Apple [`FoundationModels`](https://developer.apple.com/documentation/foundationmodels) (iOS 26+) | Built-in on-device LLM via [`@Generable`](https://developer.apple.com/documentation/foundationmodels/generable) | Apple Neural Engine |
| TTS | [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) | `Kokoro-82M-bf16` | Metal GPU via MLX |
| UI | SwiftUI + Liquid Glass (iOS 26) | — | — |

The two heavy models (WhisperKit and Kokoro) load **in parallel** during the loading screen because they target different hardware (ANE vs GPU) and don't compete for resources.

## Features

- **8 supported languages**: English, Japanese, Chinese, Spanish, French, Italian, Portuguese, Hindi
- **Press-and-hold to talk** on the colored mic buttons (red = your language, blue = theirs)
- **Tap a chat bubble** to replay its translation as TTS
- **Long-press a chat bubble** to inspect the full LLM transcript, prompt, corrections, and output
- **Tap the speaker grille** while it's speaking to interrupt playback
- **Structured output via [`@Generable`](https://developer.apple.com/documentation/foundationmodels/generable)** with a `corrections` reasoning field and `translatedText` output field — the model corrects ASR errors before translating
- **Transcript-based few-shot prompting** using the native [`Transcript`](https://developer.apple.com/documentation/foundationmodels/transcript) API with three example prompt→response pairs per language pair, so the model sees the translation pattern in its conversation history
- **Permissive content fallback** — if guardrails block a translation, the app retries with [`permissiveContentTransformations`](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output#Use-permissive-guardrail-mode-for-sensitive-content) since translation is a content transformation, not generation
- **Skeuomorphic UI** modeled after a physical pocket translator device, using SwiftUI inner shadows and [Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- **Language persistence** — selected languages are remembered across launches via UserDefaults

## Requirements

- iOS 26+ (Apple Intelligence required for FoundationModels)
- iPhone with Apple Neural Engine (iPhone 15 Pro or newer recommended for the small Whisper model)
- Xcode 26+
- Swift 6 language mode

## Building

1. Open `UniversalTranslator.xcodeproj` in Xcode 26.
2. Set your development team in Signing & Capabilities (the project ships with no team set).
3. Build and run on a physical device. The simulator works for layout iteration but **MLX and FoundationModels won't run there** — you need real hardware.
4. First launch will download the Whisper model (~216 MB), the Kokoro model (~345 MB), and G2P lexicons for all supported languages. Subsequent launches load from disk.

## Architecture

```text
Models/      Language enum, TranslationMessage, TranslationOutput (@Generable)
Services/    One service per AI stage:
               - SpeechRecognitionService  (WhisperKit)
               - TranslationService        (FoundationModels)
               - TextToSpeechService       (Kokoro / MLX)
ViewModels/  TranslatorViewModel — owns the pipeline state machine
Views/       SwiftUI views including the skeuomorphic speaker grille and Liquid Glass mic buttons
```

### Translation with `@Generable`

The translation service uses FoundationModels structured output via `@Generable`:

```swift
@Generable(description: "A translation of spoken text between two languages")
struct TranslationOutput {
    @Guide(description: "If a word was misheard, write 'X → Y'. Otherwise leave empty.")
    var corrections: String

    @Guide(description: "The translated text in the target language")
    var translatedText: String
}
```

Key design decisions:

- **`corrections` field declared first.** `@Generable` [generates properties in declaration order](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation), and Apple recommends placing a [reasoning field first](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model#Handle-on-device-reasoning) so the model can reason before answering. Without a dedicated field, the model may insert unexpected reasoning text into the answer property.
- **No `maximumResponseTokens`.** Apple's docs [warn](https://developer.apple.com/documentation/foundationmodels/generationoptions) that enforcing a token limit *"can lead to the model producing malformed results."* With `@Generable`, constrained sampling terminates naturally when the JSON schema is complete, so a token limit is unnecessary.
- **Transcript-based few-shot.** Example translations are injected as prior prompt→response turns in a [`Transcript`](https://developer.apple.com/documentation/foundationmodels/transcript), using `Transcript.StructuredSegment` with `TranslationOutput.generatedContent`. This is the native FoundationModels approach to [few-shot prompting with structured output](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model#Provide-simple-input-output-examples).

### Safety handling

- **Guardrail violations** trigger an automatic fallback to [`SystemLanguageModel(guardrails: .permissiveContentTransformations)`](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output#Use-permissive-guardrail-mode-for-sensitive-content) with plain-text generation — Apple's recommended mode for content transformation tasks like translation.
- **Refusals** are caught via [`GenerationError.refusal`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/refusal(_:_:)) and the model's explanation is surfaced to the user.

### MLX memory management

- `MLX.Memory.cacheLimit` is capped at 256 MB.
- `Memory.clearCache()` is called after every TTS inference to prevent unbounded GPU buffer growth.

### TTS phonemization

- `TextToSpeechService` explicitly installs a `KokoroMultilingualProcessor` on the model after loading.
- G2P lexicons for all supported languages are pre-downloaded at launch to avoid `lexiconNotFound` errors on first use.

## License

MIT.
