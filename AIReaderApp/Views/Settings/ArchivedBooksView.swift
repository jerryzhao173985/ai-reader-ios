// ArchivedBooksView.swift
// View for managing archived books with restore and permanent delete options
//
// Features: archived books list, restore action, permanent delete with confirmation

import SwiftUI
import SwiftData

struct ArchivedBooksView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var archivedBooks: [BookModel] = []
    @State private var showingDeleteConfirmation = false
    @State private var bookToDelete: BookModel?
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        ZStack {
            // Full-screen theme background - covers entire view including safe areas
            settings.theme.backgroundColor
                .ignoresSafeArea(.all)

            if archivedBooks.isEmpty {
                emptyState
            } else {
                booksList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.theme.backgroundColor)
        .navigationTitle("Archived Books")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(settings.theme.backgroundColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(settings.theme == .dark ? .dark : .light, for: .navigationBar)
        // Ensure back button and title use theme-appropriate colors
        .tint(settings.theme.textColor)
        .onAppear {
            loadArchivedBooks()
        }
        .confirmationDialog(
            "Delete Permanently?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let book = bookToDelete {
                    permanentlyDeleteBook(book)
                }
            }
            Button("Cancel", role: .cancel) {
                bookToDelete = nil
            }
        } message: {
            if let book = bookToDelete {
                Text("This will permanently delete \"\(book.title)\" and all its highlights, notes, and analyses. This cannot be undone.")
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "archivebox")
                .font(.system(size: 50))
                .foregroundStyle(settings.theme.textColor.opacity(0.3))

            Text("No Archived Books")
                .font(.headline)
                .foregroundStyle(settings.theme.textColor.opacity(0.5))

            Text("Books you archive will appear here.\nYou can restore them at any time.")
                .font(.subheadline)
                .foregroundStyle(settings.theme.textColor.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Books List
    private var booksList: some View {
        List {
            ForEach(archivedBooks) { book in
                ArchivedBookRow(book: book, settings: settings)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Permanent delete (requires confirmation)
                        Button(role: .destructive) {
                            bookToDelete = book
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        // Restore (swipe right, full swipe allowed)
                        Button {
                            restoreBook(book)
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.green)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(settings.theme.backgroundColor)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(settings.theme.backgroundColor)
        .contentMargins(.vertical, 8, for: .scrollContent)
    }

    // MARK: - Data Operations
    private func loadArchivedBooks() {
        let descriptor = FetchDescriptor<BookModel>(
            predicate: #Predicate<BookModel> { $0.isArchived == true },
            sortBy: [SortDescriptor(\.lastOpened, order: .reverse), SortDescriptor(\.dateAdded, order: .reverse)]
        )

        do {
            archivedBooks = try modelContext.fetch(descriptor)
        } catch {
            errorMessage = "Failed to load archived books"
            showingError = true
        }
    }

    private func restoreBook(_ book: BookModel) {
        book.isArchived = false

        do {
            try modelContext.save()
            // Remove from local list with animation
            withAnimation {
                archivedBooks.removeAll { $0.id == book.id }
            }
        } catch {
            // Revert the change since save failed
            book.isArchived = true
            errorMessage = "Failed to restore book"
            showingError = true
        }
    }

    private func permanentlyDeleteBook(_ book: BookModel) {
        // Capture ID before delete (defensive: avoids accessing deleted object properties)
        let bookId = book.id

        // Delete from database FIRST (cascades to highlights, analyses, chapters, etc.)
        // This ensures if save fails, we haven't deleted files yet
        modelContext.delete(book)

        do {
            try modelContext.save()

            // Only delete files AFTER successful database commit
            // Book files are stored at Documents/Books/{book.id}/ (NOT sourceFilePath!)
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let bookDirectory = documentsPath
                .appendingPathComponent("Books")
                .appendingPathComponent(bookId.uuidString)

            if FileManager.default.fileExists(atPath: bookDirectory.path) {
                try? FileManager.default.removeItem(at: bookDirectory)
            }

            withAnimation {
                archivedBooks.removeAll { $0.id == bookId }
            }
        } catch {
            // Discard the pending deletion (restores book to clean state in context)
            // Without rollback, book.isDeleted remains true and could be committed by a later save
            modelContext.rollback()
            loadArchivedBooks()
            errorMessage = "Failed to delete book"
            showingError = true
        }

        bookToDelete = nil
    }
}

// MARK: - Archived Book Row
struct ArchivedBookRow: View {
    let book: BookModel
    let settings: SettingsManager

    var body: some View {
        HStack(spacing: 12) {
            // Cover thumbnail
            coverThumbnail
                .frame(width: 50, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Book info
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(settings.theme.textColor)
                    .lineLimit(2)

                Text(book.authorDisplay)
                    .font(.caption)
                    .foregroundStyle(settings.theme.textColor.opacity(0.6))
                    .lineLimit(1)

                // Metadata: highlights count, chapters
                HStack(spacing: 8) {
                    if book.highlights.count > 0 {
                        Label("\(book.highlights.count)", systemImage: "highlighter")
                            .font(.caption2)
                            .foregroundStyle(settings.theme.textColor.opacity(0.5))
                    }

                    Label("\(book.chapterCount)", systemImage: "book.pages")
                        .font(.caption2)
                        .foregroundStyle(settings.theme.textColor.opacity(0.5))
                }
            }

            Spacer()

            // Swipe hint
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(settings.theme.textColor.opacity(0.3))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(settings.theme.secondaryBackgroundColor.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(settings.theme.textColor.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let imageData = book.coverImageData,
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Placeholder with gradient based on title
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: Double(abs(book.title.hashValue) % 360) / 360, saturation: 0.5, brightness: 0.7),
                        Color(hue: Double(abs(book.title.hashValue) % 360) / 360, saturation: 0.6, brightness: 0.5)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: "book.closed")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

#Preview {
    NavigationStack {
        ArchivedBooksView()
            .environment(SettingsManager())
            .modelContainer(for: BookModel.self)
    }
}
