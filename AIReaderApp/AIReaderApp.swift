// AIReaderApp.swift
// Main entry point for AI Reader iOS App
//
// Architecture: SwiftUI + SwiftData + MVVM
// Features: EPUB reading, AI-powered text analysis, highlights, progress tracking

import SwiftUI
import SwiftData

@main
struct AIReaderApp: App {
    let modelContainer: ModelContainer

    @State private var libraryViewModel: LibraryViewModel
    @State private var settingsManager = SettingsManager()

    init() {
        // Initialize SwiftData model container
        do {
            let schema = Schema([
                BookModel.self,
                ChapterModel.self,
                TOCEntryModel.self,
                HighlightModel.self,
                AIAnalysisModel.self,
                AnalysisThreadModel.self,
                AnalysisTurnModel.self,
                ReadingProgressModel.self
            ])

            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )

            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )

            // Initialize library view model with model context
            let context = modelContainer.mainContext
            _libraryViewModel = State(initialValue: LibraryViewModel(modelContext: context))

        } catch {
            fatalError("Failed to initialize model container: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryViewModel)
                .environment(settingsManager)
                .modelContainer(modelContainer)
        }
    }
}
