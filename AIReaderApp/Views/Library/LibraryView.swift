// LibraryView.swift
// Grid view displaying all books in the library
//
// Features: book grid, import, delete, progress display

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(SettingsManager.self) private var settings

    let onBookSelected: (BookModel) -> Void

    @State private var showingFilePicker = false
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    var filteredBooks: [BookModel] {
        if searchText.isEmpty {
            return viewModel.books
        }
        return viewModel.books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.authorDisplay.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            settings.theme.backgroundColor
                .ignoresSafeArea()

            if viewModel.books.isEmpty {
                emptyLibraryView
            } else {
                bookGridView
            }

            if viewModel.isLoading {
                loadingOverlay
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search books")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingFilePicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.epub],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Error", isPresented: Bindable(viewModel).showingError) {
            Button("OK") { }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred")
        }
    }

    // MARK: - Subviews

    private var emptyLibraryView: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical")
                .font(.system(size: 80))
                .foregroundStyle(settings.theme.textColor.opacity(0.3))

            Text("Your Library is Empty")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(settings.theme.textColor)

            Text("Tap + to add an EPUB book")
                .font(.body)
                .foregroundStyle(settings.theme.textColor.opacity(0.6))

            Button {
                showingFilePicker = true
            } label: {
                Label("Import Book", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(settings.theme.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private var bookGridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(filteredBooks) { book in
                    BookCardView(book: book) {
                        viewModel.markBookAsOpened(book)
                        onBookSelected(book)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteBook(book)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)

                Text("Importing book...")
                    .font(.headline)
                    .foregroundStyle(.white)

                if viewModel.importProgress > 0 {
                    ProgressView(value: viewModel.importProgress)
                        .tint(.white)
                        .frame(width: 200)
                }
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                await viewModel.importBook(from: url)
            }
        case .failure(let error):
            viewModel.errorMessage = "Failed to select file: \(error.localizedDescription)"
            viewModel.showingError = true
        }
    }
}

// MARK: - Book Card View
struct BookCardView: View {
    let book: BookModel
    let onTap: () -> Void

    @Environment(SettingsManager.self) private var settings

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Cover Image
                coverImage
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

                // Title
                Text(book.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(settings.theme.textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // Author
                Text(book.authorDisplay)
                    .font(.caption)
                    .foregroundStyle(settings.theme.textColor.opacity(0.6))
                    .lineLimit(1)

                // Progress Bar
                if let progress = book.readingProgress {
                    ProgressView(value: progress.progressPercentage / 100)
                        .tint(settings.theme.accentColor)
                }

                // Chapter count
                Text("\(book.chapterCount) chapters")
                    .font(.caption2)
                    .foregroundStyle(settings.theme.textColor.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let imageData = book.coverImageData,
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Placeholder cover with gradient
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: Double(book.title.hashValue % 360) / 360, saturation: 0.5, brightness: 0.7),
                        Color(hue: Double(book.title.hashValue % 360) / 360, saturation: 0.6, brightness: 0.5)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack {
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.8))

                    Text(book.title.prefix(1).uppercased())
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView { _ in }
    }
    .modelContainer(for: BookModel.self)
}
