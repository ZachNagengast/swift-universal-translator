import SwiftUI

/// Root coordinator. Owns the three pipeline services and gates the UI on model loading:
/// while models are downloading or warming up, shows `ModelLoadingView`. Once ready,
/// hands off to `TranslatorView`.
struct ContentView: View {
    @State private var viewModel: TranslatorViewModel?
    @State private var speechService = SpeechRecognitionService()
    @State private var translationService = TranslationService()
    @State private var ttsService = TextToSpeechService()

    var body: some View {
        ZStack {
            AnimatedBackgroundView()

            if let viewModel, !viewModel.isLoading {
                TranslatorView(viewModel: viewModel)
            } else if let viewModel {
                ModelLoadingView(
                    status: viewModel.loadingStatus.isEmpty ? viewModel.loadingStatusText : viewModel.loadingStatus,
                    whisperProgress: speechService.loadingProgress,
                    ttsProgress: ttsService.loadingProgress
                )
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .task {
            let vm = TranslatorViewModel(
                speechService: speechService,
                translationService: translationService,
                ttsService: ttsService
            )
            viewModel = vm
            await vm.loadModels()
        }
    }
}
