// ContentView.swift
// Main content view with navigation between Library and Reader
//
// Root view for the app navigation structure

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(SettingsManager.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var selectedBook: BookModel?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            if let book = selectedBook {
                ReaderView(book: book, onDismiss: {
                    selectedBook = nil
                })
                .environment(settings)
            } else {
                LibraryView(onBookSelected: { book in
                    selectedBook = book
                })
                .environment(libraryViewModel)
                .environment(settings)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environment(settings)
        }
        .task {
            // Scan Documents folder for EPUB files on launch
            await libraryViewModel.scanDocumentsFolder()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            BookModel.self,
            ChapterModel.self,
            TOCEntryModel.self,
            HighlightModel.self,
            AIAnalysisModel.self,
            AnalysisThreadModel.self,
            AnalysisTurnModel.self,
            ReadingProgressModel.self
        ])
}
