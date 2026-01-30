// LibraryViewModel.swift
// ViewModel for the Library view managing book collection
//
// Handles book importing, deletion, and library state

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
        let descriptor = FetchDescriptor<BookModel>(
            sortBy: [SortDescriptor(\.lastOpened, order: .reverse), SortDescriptor(\.dateAdded, order: .reverse)]
        )

        do {
            books = try modelContext.fetch(descriptor)
        } catch {
            errorMessage = "Failed to load books: \(error.localizedDescription)"
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

    // MARK: - Book Deletion
    func deleteBook(_ book: BookModel) {
        // Delete associated files
        if let sourcePath = book.sourceFilePath {
            let bookDir = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: bookDir)
        }

        // Delete from database
        modelContext.delete(book)

        do {
            try modelContext.save()
            loadBooks()
        } catch {
            errorMessage = "Failed to delete book: \(error.localizedDescription)"
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
                // Check if we've already imported this file
                let fileName = epubURL.lastPathComponent
                let alreadyImported = books.contains { book in
                    book.sourceFilePath?.contains(fileName) == true ||
                    book.title.lowercased() == fileName.replacingOccurrences(of: ".epub", with: "").lowercased()
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
