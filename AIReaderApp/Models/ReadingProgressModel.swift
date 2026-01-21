// ReadingProgressModel.swift
// SwiftData model for tracking reading progress
//
// Stores exact reading position (chapter + scroll offset) for each book

import Foundation
import SwiftData

@Model
final class ReadingProgressModel {
    // MARK: - Identifiers
    @Attribute(.unique) var id: UUID
    var book: BookModel?

    // MARK: - Progress Data
    var chapterIndex: Int
    var scrollPosition: Double  // 0.0 to 1.0 (percentage through chapter)
    var scrollOffset: CGFloat   // Absolute pixel offset for precise restoration

    // MARK: - Timestamps
    var lastUpdated: Date

    // MARK: - Computed Properties
    var progressPercentage: Double {
        guard let book = book, book.chapterCount > 0 else { return 0 }
        let chapterProgress = Double(chapterIndex) / Double(book.chapterCount)
        let withinChapterProgress = scrollPosition / Double(book.chapterCount)
        return (chapterProgress + withinChapterProgress) * 100
    }

    init(
        id: UUID = UUID(),
        chapterIndex: Int = 0,
        scrollPosition: Double = 0.0,
        scrollOffset: CGFloat = 0
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.scrollPosition = scrollPosition
        self.scrollOffset = scrollOffset
        self.lastUpdated = Date()
    }

    func update(chapterIndex: Int, scrollPosition: Double, scrollOffset: CGFloat) {
        self.chapterIndex = chapterIndex
        self.scrollPosition = scrollPosition
        self.scrollOffset = scrollOffset
        self.lastUpdated = Date()
    }
}
