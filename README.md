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
| Translation | Apple `FoundationModels` (iOS 26+) | Built-in on-device LLM | Apple Neural Engine |
| TTS | [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) | `Kokoro-82M-bf16` | Metal GPU via MLX |
| UI | SwiftUI + Liquid Glass (iOS 26) | — | — |

The two heavy models (WhisperKit and Kokoro) load **in parallel** during the loading screen because they target different hardware (ANE vs GPU) and don't compete for resources.

## Features

- **8 supported languages**: English, Japanese, Chinese, Spanish, French, Italian, Portuguese, Hindi
- **Press-and-hold to talk** on the colored mic buttons (red = your language, blue = theirs)
- **Tap a chat bubble** to replay its translation as TTS
- **Long-press a chat bubble** to inspect the full LLM prompt and output for that translation
- **Tap the speaker grille** while it's speaking to interrupt playback
- **Few-shot prompting** of the on-device LLM with three reference translations per language pair (greeting, factual question, opinion question) so the model translates questions instead of answering them
- **Skeuomorphic UI** modeled after a physical pocket translator device, using SwiftUI inner shadows and Liquid Glass

## Requirements

- iOS 26+ (Apple Intelligence required for FoundationModels)
- iPhone with Apple Neural Engine (iPhone 15 Pro or newer recommended for the small Whisper model)
- Xcode 26+

## Building

1. Open `UniversalTranslator.xcodeproj` in Xcode 26.
2. Set your development team in Signing & Capabilities (the project ships with no team set).
3. Build and run on a physical device. The simulator works for layout iteration but **MLX and FoundationModels won't run there** — you need real hardware.
4. First launch will download the Whisper model (~216 MB), the Kokoro model (~165 MB), and a handful of small G2P lexicons. Subsequent launches load from disk and are nearly instant.

## Architecture

The code is organized into clean MVVM layers:

```text
Models/      Plain data types — Language enum, TranslationMessage, TranslationOutput
Services/    One service per AI stage:
               - SpeechRecognitionService  (WhisperKit)
               - TranslationService        (FoundationModels)
               - TextToSpeechService       (Kokoro / MLX)
ViewModels/  TranslatorViewModel — owns the pipeline state machine
Views/       SwiftUI views including the skeuomorphic speaker grille and Liquid Glass mic buttons
```

A few implementation notes worth knowing:

- **`TextToSpeechService` installs the Kokoro multilingual phonemizer explicitly.** Kokoro routes input text through a `TextProcessor` to convert it to phonemes (English uses Misaki / CMUdict; other languages use IPA lexicons or a small ByT5 neural G2P model). We hold a strong reference to the processor so we can pre-warm language resources at launch.
- **`MLX.Memory.cacheLimit` is capped and `clearCache()` is called after every inference.** Without this, the GPU buffer pool grows unbounded across many inferences and the app eventually OOMs on iPhone.
- **TTS lexicons are pre-downloaded for every supported language at launch.** This avoids `lexiconNotFound` on the first call to a new language.
- **Plain text generation, not `@Generable`.** For short translations the on-device LLM is more reliable when generating plain text than when constrained by a `@Generable` JSON schema.
- **Few-shot prompt structure**: the text to translate is placed *before* the reference examples and wrapped in `===== TEXT TO TRANSLATE =====` delimiters, so the model treats it as data instead of a chat message to respond to.
- **Whisper hallucinations are filtered** (`Thanks for watching`, `Subscribe`, `Bye`, etc.) before they ever reach the LLM, since Whisper tends to insert these on silence.

## License

MIT.
