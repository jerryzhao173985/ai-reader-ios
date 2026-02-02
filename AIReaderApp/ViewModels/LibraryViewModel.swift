// LibraryViewModel.swift
// ViewModel for the Library view managing book collection
//
// Handles book importing, archiving, and library state

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryViewModel {
    // MARK: - Properties
    private let modelContext: ModelContext
    private let epubParser = EPUBParserService()

    var books: [BookModel] = []
    var archivedBooks: [BookModel] = []
    var isLoading = false
    var errorMessage: String?
    var showingError = false
    var showingFilePicker = false
    var importProgress: Double = 0

    // MARK: - Initialization
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadBooks()
    }

    // MARK: - Book Loading
    func loadBooks() {
        // Fetch only non-archived books for main library
        let descriptor = FetchDescriptor<BookModel>(
            predicate: #Predicate<BookModel> { $0.isArchived == false },
            sortBy: [SortDescriptor(\.lastOpened, order: .reverse), SortDescriptor(\.dateAdded, order: .reverse)]
        )

        do {
            books = try modelContext.fetch(descriptor)
        } catch {
            errorMessage = "Failed to load books: \(error.localizedDescription)"
            showingError = true
        }
    }

    /// Loads only archived books for the Archived Books view
    func loadArchivedBooks() {
        let descriptor = FetchDescriptor<BookModel>(
            predicate: #Predicate<BookModel> { $0.isArchived == true },
            sortBy: [SortDescriptor(\.lastOpened, order: .reverse), SortDescriptor(\.dateAdded, order: .reverse)]
        )

        do {
            archivedBooks = try modelContext.fetch(descriptor)
        } catch {
            errorMessage = "Failed to load archived books: \(error.localizedDescription)"
            showingError = true
        }
    }

    // MARK: - Book Import
    func importBook(from url: URL) async {
        isLoading = true
        importProgress = 0.1
        errorMessage = nil

        do {
            importProgress = 0.3

            // Parse the EPUB
            let book = try await epubParser.parseEPUB(at: url)

            importProgress = 0.7

            // Insert book and all related objects into database
            // SwiftData requires explicit insertion of each object, unlike Core Data
            modelContext.insert(book)

            // Insert all chapters (required for SwiftData relationships)
            for chapter in book.chapters {
                modelContext.insert(chapter)
            }

            // Insert all TOC entries
            for tocEntry in book.tableOfContents {
                modelContext.insert(tocEntry)
            }

            importProgress = 0.9

            // Save changes
            try modelContext.save()

            print("[LibraryVM] Imported book: \(book.title) with \(book.chapters.count) chapters")

            importProgress = 1.0

            // Reload books list
            // Note: With @MainActor on class, we're already on MainActor after await
            loadBooks()
            isLoading = false
        } catch {
            // Note: With @MainActor on class, we're already on MainActor after await
            errorMessage = "Failed to import book: \(error.localizedDescription)"
            showingError = true
            isLoading = false
        }
    }

    // MARK: - Book Archive
    /// Archives a book (hides from library, preserves all data including highlights and analyses)
    func archiveBook(_ book: BookModel) {
        book.isArchived = true

        do {
            try modelContext.save()
            loadBooks()
        } catch {
            // Revert the change since save failed
            book.isArchived = false
            errorMessage = "Failed to archive book: \(error.localizedDescription)"
            showingError = true
        }
    }

    /// Restores an archived book to the main library
    func unarchiveBook(_ book: BookModel) {
        book.isArchived = false

        do {
            try modelContext.save()
            loadArchivedBooks()
            loadBooks()
        } catch {
            // Revert the change since save failed
            book.isArchived = true
            errorMessage = "Failed to restore book: \(error.localizedDescription)"
            showingError = true
        }
    }

    /// Permanently deletes a book and all associated data (highlights, analyses, chapters)
    /// This is irreversible - only available for archived books
    func permanentlyDeleteBook(_ book: BookModel) {
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

            loadArchivedBooks()
        } catch {
            // Discard the pending deletion (restores book to clean state in context)
            // Without rollback, book.isDeleted remains true and could be committed by a later save
            modelContext.rollback()
            loadArchivedBooks()
            errorMessage = "Failed to delete book"
            showingError = true
        }
    }

    // MARK: - Book Access
    func markBookAsOpened(_ book: BookModel) {
        book.lastOpened = Date()
        try? modelContext.save()
    }

    func getProgress(for book: BookModel) -> Double {
        book.readingProgress?.progressPercentage ?? 0
    }

    // MARK: - Documents Folder Scanning
    /// Copies bundled sample books from app bundle to Documents folder
    private func copyBundledBooksToDocuments() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        // List of bundled EPUB files to copy
        let bundledBooks = ["SampleBook"]

        for bookName in bundledBooks {
            // Check if the EPUB exists in the app bundle
            if let bundleURL = Bundle.main.url(forResource: bookName, withExtension: "epub") {
                let destinationURL = documentsURL.appendingPathComponent("\(bookName).epub")

                // Only copy if it doesn't already exist in Documents
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    do {
                        try fileManager.copyItem(at: bundleURL, to: destinationURL)
                        print("Copied bundled book \(bookName).epub to Documents")
                    } catch {
                        print("Failed to copy bundled book \(bookName): \(error)")
                    }
                }
            }
        }
    }

    /// Scans the Documents folder for EPUB files and imports any new ones
    func scanDocumentsFolder() async {
        // First, copy any bundled books to Documents
        copyBundledBooksToDocuments()

        // Load archived books to check against (avoid re-importing archived books)
        loadArchivedBooks()

        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )

            let epubFiles = contents.filter { $0.pathExtension.lowercased() == "epub" }

            for epubURL in epubFiles {
                // Check if we've already imported this file (including archived books)
                // Use exact filename matching to avoid false positives
                let fileName = epubURL.lastPathComponent
                let allBooks = books + archivedBooks
                let alreadyImported = allBooks.contains { book in
                    // Extract filename from stored sourceFilePath for exact comparison
                    if let sourcePath = book.sourceFilePath {
                        let storedFileName = URL(fileURLWithPath: sourcePath).lastPathComponent
                        if storedFileName == fileName {
                            return true
                        }
                    }
                    // Fallback: match by title (for books imported before path tracking)
                    return book.title.lowercased() == fileName.replacingOccurrences(of: ".epub", with: "").lowercased()
                }

                if !alreadyImported {
                    print("Found new EPUB in Documents: \(fileName)")
                    await importBook(from: epubURL)
                }
            }
        } catch {
            print("Error scanning Documents folder: \(error)")
        }
    }
}

// MARK: - EPUB Document Type
extension UTType {
    static let epub = UTType(filenameExtension: "epub")!
}
