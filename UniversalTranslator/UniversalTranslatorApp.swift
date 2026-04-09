import SwiftUI

/// On-device universal translator.
///
/// Pipeline: WhisperKit (ASR) → FoundationModels (translation) → Kokoro TTS,
/// all running locally on the Apple Neural Engine and Metal GPU.
@main
struct UniversalTranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
