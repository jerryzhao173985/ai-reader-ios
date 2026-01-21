// BookModel.swift
// SwiftData model for books in the library
//
// Mirrors the Python Book dataclass with metadata, chapters, TOC, and images

import Foundation
import SwiftData

@Model
final class BookModel {
    // MARK: - Identifiers
    @Attribute(.unique) var id: UUID
    var sourceFilePath: String?

    // MARK: - Metadata (Dublin Core)
    var title: String
    var authors: [String]
    var language: String?
    var bookDescription: String?
    var publisher: String?
    var publishDate: String?
    var subjects: [String]
    var identifiers: [String: String]

    // MARK: - Cover Image
    var coverImageData: Data?
    var coverImagePath: String?

    // MARK: - Content Structure
    @Relationship(deleteRule: .cascade, inverse: \ChapterModel.book) var chapters: [ChapterModel]
    @Relationship(deleteRule: .cascade, inverse: \TOCEntryModel.book) var tableOfContents: [TOCEntryModel]

    // MARK: - User Data
    @Relationship(deleteRule: .cascade, inverse: \HighlightModel.book) var highlights: [HighlightModel]
    @Relationship(deleteRule: .cascade, inverse: \ReadingProgressModel.book) var readingProgress: ReadingProgressModel?

    // MARK: - Timestamps
    var dateAdded: Date
    var lastOpened: Date?

    // MARK: - Computed Properties
    var authorDisplay: String {
        authors.isEmpty ? "Unknown Author" : authors.joined(separator: ", ")
    }

    var chapterCount: Int {
        chapters.count
    }

    // MARK: - Initialization
    init(
        id: UUID = UUID(),
        title: String,
        authors: [String] = [],
        language: String? = nil,
        bookDescription: String? = nil,
        publisher: String? = nil,
        publishDate: String? = nil,
        subjects: [String] = [],
        identifiers: [String: String] = [:],
        coverImageData: Data? = nil,
        coverImagePath: String? = nil,
        sourceFilePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.language = language
        self.bookDescription = bookDescription
        self.publisher = publisher
        self.publishDate = publishDate
        self.subjects = subjects
        self.identifiers = identifiers
        self.coverImageData = coverImageData
        self.coverImagePath = coverImagePath
        self.sourceFilePath = sourceFilePath
        self.chapters = []
        self.tableOfContents = []
        self.highlights = []
        self.dateAdded = Date()
    }
}

// MARK: - Chapter Model
@Model
final class ChapterModel {
    @Attribute(.unique) var id: UUID
    var chapterId: String  // Original EPUB item ID
    var href: String       // File path for linking
    var title: String
    var htmlContent: String
    var plainText: String
    var order: Int

    // Parent book (inverse relationship)
    var book: BookModel?

    // Image mappings for this chapter
    var imagePathMap: [String: String]

    init(
        id: UUID = UUID(),
        chapterId: String,
        href: String,
        title: String,
        htmlContent: String,
        plainText: String,
        order: Int,
        imagePathMap: [String: String] = [:]
    ) {
        self.id = id
        self.chapterId = chapterId
        self.href = href
        self.title = title
        self.htmlContent = htmlContent
        self.plainText = plainText
        self.order = order
        self.imagePathMap = imagePathMap
    }
}

// MARK: - Table of Contents Entry
@Model
final class TOCEntryModel {
    @Attribute(.unique) var id: UUID
    var title: String
    var href: String
    var order: Int

    // Nested TOC structure
    @Relationship(deleteRule: .cascade) var children: [TOCEntryModel]
    var parent: TOCEntryModel?
    var book: BookModel?

    init(
        id: UUID = UUID(),
        title: String,
        href: String,
        order: Int = 0,
        children: [TOCEntryModel] = []
    ) {
        self.id = id
        self.title = title
        self.href = href
        self.order = order
        self.children = children
    }
}
