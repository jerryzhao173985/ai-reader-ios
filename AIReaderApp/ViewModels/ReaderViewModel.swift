// ReaderViewModel.swift
// ViewModel for the Reader view managing book reading state
//
// Handles chapter navigation, highlights, AI analysis, and reading progress

import SwiftUI
import SwiftData

@Observable
final class ReaderViewModel {
    // MARK: - Properties
    private let modelContext: ModelContext

    // Book State
    let book: BookModel
    var currentChapterIndex: Int = 0
    var scrollOffset: CGFloat = 0

    // UI State
    var showingTOC = false  // Start with TOC hidden on iPhone for better UX
    var showingAnalysisPanel = false
    var selectedText: String = ""
    var selectionRange: NSRange?

    // Highlights
    var currentChapterHighlights: [HighlightModel] = []
    var selectedHighlight: HighlightModel?

    // AI Analysis
    let analysisJobManager = AnalysisJobManager()
    var currentAnalysisType: AnalysisType?
    var isAnalyzing = false
    var analysisResult: String?
    var customQuestion: String = ""

    // Context Menu
    var showingContextMenu = false
    var contextMenuPosition: CGPoint = .zero

    /// Pending marker update for JS injection (avoids full HTML reload)
    /// Set when analysis completes to update marker without page flicker
    /// Includes colorHex to update highlight background color when analysis completes
    var pendingMarkerUpdate: (highlightId: UUID, analysisCount: Int, colorHex: String)?

    /// Maps highlight ID to its active job ID for proper streaming display
    /// When user clicks a highlight, we show streaming from ITS job, not any random job
    private var highlightToJobMap: [UUID: UUID] = [:]

    /// Queue of pending marker updates to apply when no text selection is active
    /// This prevents marker refresh from disrupting user's text selection
    private var pendingMarkerUpdatesQueue: [(highlightId: UUID, analysisCount: Int, colorHex: String)] = []

    /// Flag to indicate there's an active text selection that shouldn't be interrupted
    var hasActiveTextSelection: Bool = false

    // MARK: - Cached Chapters (ensures SwiftData relationship is loaded)
    private var _cachedChapters: [ChapterModel]?

    private var cachedChapters: [ChapterModel] {
        if let cached = _cachedChapters {
            return cached
        }
        // Force SwiftData to load the relationship by accessing it
        let chapters = book.chapters.sorted(by: { $0.order < $1.order })
        _cachedChapters = chapters
        return chapters
    }

    // MARK: - Computed Properties
    var currentChapter: ChapterModel? {
        let chapters = cachedChapters
        guard currentChapterIndex >= 0 && currentChapterIndex < chapters.count else {
            return nil
        }
        return chapters[currentChapterIndex]
    }

    var chapterCount: Int {
        cachedChapters.count
    }

    var hasNextChapter: Bool {
        currentChapterIndex < chapterCount - 1
    }

    var hasPreviousChapter: Bool {
        currentChapterIndex > 0
    }

    var sortedChapters: [ChapterModel] {
        cachedChapters
    }

    // MARK: - Initialization
    init(book: BookModel, modelContext: ModelContext) {
        self.book = book
        self.modelContext = modelContext

        // Restore last reading position or find first content chapter
        if let progress = book.readingProgress {
            self.currentChapterIndex = progress.chapterIndex
            self.scrollOffset = progress.scrollOffset
        } else {
            // First time opening - skip front matter (cover, titlepage, etc.)
            // Find the first chapter with substantial content (>500 chars of plain text)
            self.currentChapterIndex = findFirstContentChapter()
        }

        loadHighlightsForCurrentChapter()
    }

    // MARK: - Content Detection
    /// Finds the first chapter with substantial content, skipping front matter
    private func findFirstContentChapter() -> Int {
        let chapters = cachedChapters

        // Look for first chapter with substantial content (>500 chars of plain text)
        // This skips cover pages, title pages, copyright pages, etc.
        for (index, chapter) in chapters.enumerated() {
            if chapter.plainText.count > 500 {
                return index
            }
        }

        // Fallback to first chapter if none found with substantial content
        return 0
    }

    // MARK: - Navigation
    func goToChapter(_ index: Int) {
        guard index >= 0 && index < chapterCount else { return }

        // Apply any deferred updates for current chapter before leaving
        // This ensures colorHex is saved even if user had active selection
        if !pendingMarkerUpdatesQueue.isEmpty {
            applyDeferredMarkerUpdates()
        }

        currentChapterIndex = index
        scrollOffset = 0
        _cachedChapters = nil  // Invalidate cache to refresh from SwiftData
        loadHighlightsForCurrentChapter()
        saveProgress()
    }

    func goToNextChapter() {
        if hasNextChapter {
            goToChapter(currentChapterIndex + 1)
        }
    }

    func goToPreviousChapter() {
        if hasPreviousChapter {
            goToChapter(currentChapterIndex - 1)
        }
    }

    func goToTOCEntry(_ entry: TOCEntryModel) {
        // Find chapter matching the TOC entry's href
        if let index = sortedChapters.firstIndex(where: { $0.href.contains(entry.href) || entry.href.contains($0.href) }) {
            goToChapter(index)
        }
    }

    // MARK: - Progress Tracking
    func saveProgress() {
        if book.readingProgress == nil {
            let progress = ReadingProgressModel(
                chapterIndex: currentChapterIndex,
                scrollPosition: Double(scrollOffset),
                scrollOffset: scrollOffset
            )
            progress.book = book
            book.readingProgress = progress
            modelContext.insert(progress)
        } else {
            book.readingProgress?.update(
                chapterIndex: currentChapterIndex,
                scrollPosition: Double(scrollOffset),
                scrollOffset: scrollOffset
            )
        }

        try? modelContext.save()
    }

    func updateScrollPosition(_ offset: CGFloat) {
        scrollOffset = offset
        // Debounce save - in production, use Combine debounce
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
            await MainActor.run {
                saveProgress()
            }
        }
    }

    // MARK: - Highlights
    func loadHighlightsForCurrentChapter() {
        let chapterIdx = currentChapterIndex
        let descriptor = FetchDescriptor<HighlightModel>(
            predicate: #Predicate { highlight in
                highlight.chapterIndex == chapterIdx
            },
            sortBy: [SortDescriptor(\.startOffset)]
        )

        do {
            currentChapterHighlights = try modelContext.fetch(descriptor)
                .filter { $0.book?.id == book.id }
        } catch {
            currentChapterHighlights = []
        }
    }

    func createHighlight(
        text: String,
        contextBefore: String,
        contextAfter: String,
        startOffset: Int,
        endOffset: Int
    ) -> HighlightModel {
        let highlight = HighlightModel(
            chapterIndex: currentChapterIndex,
            selectedText: text,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            startOffset: startOffset,
            endOffset: endOffset
        )

        highlight.book = book
        modelContext.insert(highlight)
        try? modelContext.save()

        loadHighlightsForCurrentChapter()
        return highlight
    }

    func deleteHighlight(_ highlight: HighlightModel) {
        let highlightId = highlight.id

        // Delete from database
        modelContext.delete(highlight)
        try? modelContext.save()
        loadHighlightsForCurrentChapter()

        // Clear selection if this highlight was selected
        if selectedHighlight?.id == highlightId {
            selectedHighlight = nil
            analysisResult = nil
            showingAnalysisPanel = false
        }
    }

    // MARK: - AI Analysis
    func performAnalysis(type: AnalysisType, text: String, context: String, question: String? = nil) {
        guard let highlight = selectedHighlight else { return }

        isAnalyzing = true
        currentAnalysisType = type
        analysisResult = nil

        let jobId = analysisJobManager.queueAnalysis(
            type: type,
            text: text,
            context: context,
            chapterContext: currentChapter?.plainText,
            question: question
        )

        // Track which job belongs to which highlight for proper streaming display
        let highlightId = highlight.id
        highlightToJobMap[highlightId] = jobId

        // Poll for streaming updates and completion
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05 second for smoother streaming

                guard let job = analysisJobManager.getJob(jobId) else { break }

                switch job.status {
                case .streaming:
                    await MainActor.run {
                        // Only update analysisResult if this is the CURRENTLY SELECTED highlight
                        // This prevents parallel analyses from overwriting each other's display
                        if !job.streamingResult.isEmpty,
                           selectedHighlight?.id == highlightId {
                            analysisResult = job.streamingResult
                        }
                    }
                case .completed:
                    await MainActor.run {
                        if let result = job.result {
                            // Only update display if this highlight is still selected
                            if selectedHighlight?.id == highlightId {
                                analysisResult = result
                                isAnalyzing = false
                            }
                            // Save analysis to SwiftData for this specific highlight
                            saveAnalysis(
                                to: highlight,
                                type: type,
                                prompt: question ?? text,
                                response: result
                            )
                        }
                        // Clean up job mapping
                        highlightToJobMap.removeValue(forKey: highlightId)
                    }
                    return
                case .error:
                    await MainActor.run {
                        if selectedHighlight?.id == highlightId {
                            analysisResult = "Error: \(job.error?.localizedDescription ?? "Unknown error")"
                            isAnalyzing = false
                        }
                        highlightToJobMap.removeValue(forKey: highlightId)
                    }
                    return
                case .queued, .running:
                    continue
                }
            }
        }
    }

    func saveAnalysis(to highlight: HighlightModel, type: AnalysisType, prompt: String, response: String) {
        let analysis = AIAnalysisModel(
            analysisType: type,
            prompt: prompt,
            response: response
        )

        analysis.highlight = highlight
        highlight.analyses.append(analysis)
        // NOTE: Don't update colorHex here yet - it would change the hash and trigger HTML reload
        // Color update is deferred along with marker update to preserve user's text selection

        modelContext.insert(analysis)
        try? modelContext.save()

        // Update marker via JS injection (no page reload, preserves scroll & selection)
        // The highlight.analyses array is already updated in memory (reference type)
        // Include colorHex so the highlight background updates to analysis type color
        let markerUpdate = (highlightId: highlight.id, analysisCount: highlight.analyses.count, colorHex: type.colorHex)

        // If user has active text selection, defer EVERYTHING to avoid disrupting selection
        // This includes not updating colorHex in SwiftData (which would change hash → reload)
        if hasActiveTextSelection {
            pendingMarkerUpdatesQueue.append(markerUpdate)
        } else {
            // Safe to update colorHex now - no active selection to disrupt
            highlight.colorHex = type.colorHex
            try? modelContext.save()
            pendingMarkerUpdate = markerUpdate
        }
    }

    /// Apply any deferred marker updates after text selection is cleared
    func applyDeferredMarkerUpdates() {
        guard !pendingMarkerUpdatesQueue.isEmpty else { return }

        // Apply the last update for each highlight (most recent analysis count and color)
        var lastUpdates: [UUID: (highlightId: UUID, analysisCount: Int, colorHex: String)] = [:]
        for update in pendingMarkerUpdatesQueue {
            lastUpdates[update.highlightId] = update
        }
        pendingMarkerUpdatesQueue.removeAll()

        // First, update colorHex in SwiftData for all deferred highlights
        // This was deferred to avoid changing the hash while user had active selection
        for update in lastUpdates.values {
            if let highlight = currentChapterHighlights.first(where: { $0.id == update.highlightId }) {
                highlight.colorHex = update.colorHex
            }
        }
        try? modelContext.save()

        // Now trigger the marker updates via JS injection
        // NOTE: Setting pendingMarkerUpdate multiple times in a loop only keeps the last one
        // This is acceptable because the HTML reload (triggered by colorHex change) will
        // render all highlights with correct markers anyway
        if let lastUpdate = lastUpdates.values.first {
            pendingMarkerUpdate = lastUpdate
        }
    }

    func askFollowUpQuestion(highlight: HighlightModel, question: String) {
        isAnalyzing = true
        currentAnalysisType = .customQuestion
        analysisResult = nil

        // Get existing custom question analysis (if any) for conversation history
        let existingAnalysis = highlight.analyses.last(where: { $0.analysisType == .customQuestion })

        // Get conversation history from existing thread
        var history: [(question: String, answer: String)] = []
        if let thread = existingAnalysis?.thread {
            history = thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex }).map {
                (question: $0.question, answer: $0.answer)
            }
        }

        let jobId = analysisJobManager.queueAnalysis(
            type: .customQuestion,
            text: highlight.selectedText,
            context: highlight.fullContext,
            chapterContext: currentChapter?.plainText,
            question: question,
            history: history
        )

        // Track which job belongs to which highlight for proper streaming display
        // This ensures parallel follow-ups don't interfere with each other
        let highlightId = highlight.id
        highlightToJobMap[highlightId] = jobId

        // Poll for streaming updates and completion
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05 second for smoother streaming

                guard let job = analysisJobManager.getJob(jobId) else { break }

                switch job.status {
                case .streaming:
                    // Update with streaming result for real-time display
                    // Only update if this is the CURRENTLY SELECTED highlight (parallel isolation)
                    await MainActor.run {
                        if !job.streamingResult.isEmpty,
                           selectedHighlight?.id == highlightId {
                            analysisResult = job.streamingResult
                        }
                    }
                case .completed:
                    await MainActor.run {
                        if let result = job.result {
                            // Only update display if this highlight is still selected
                            if selectedHighlight?.id == highlightId {
                                analysisResult = result
                                isAnalyzing = false
                            }

                            if let analysis = existingAnalysis {
                                // Add to existing thread
                                addTurnToThread(analysis: analysis, question: question, answer: result)
                            } else {
                                // Create new analysis with first Q&A
                                let analysis = AIAnalysisModel(
                                    analysisType: .customQuestion,
                                    prompt: question,
                                    response: result
                                )
                                analysis.highlight = highlight
                                highlight.analyses.append(analysis)
                                // NOTE: Don't update colorHex immediately - use deferral logic like saveAnalysis()
                                modelContext.insert(analysis)
                                try? modelContext.save()

                                // Use same deferral logic as saveAnalysis() for colorHex and marker updates
                                let markerUpdate = (highlightId: highlight.id, analysisCount: highlight.analyses.count, colorHex: AnalysisType.customQuestion.colorHex)
                                if hasActiveTextSelection {
                                    pendingMarkerUpdatesQueue.append(markerUpdate)
                                } else {
                                    highlight.colorHex = AnalysisType.customQuestion.colorHex
                                    try? modelContext.save()
                                    pendingMarkerUpdate = markerUpdate
                                }

                                // Add the first turn to thread
                                addTurnToThread(analysis: analysis, question: question, answer: result)
                            }
                        }
                        // Clean up job mapping
                        highlightToJobMap.removeValue(forKey: highlightId)
                    }
                    return
                case .error:
                    await MainActor.run {
                        if selectedHighlight?.id == highlightId {
                            analysisResult = "Error: \(job.error?.localizedDescription ?? "Unknown error")"
                            isAnalyzing = false
                        }
                        highlightToJobMap.removeValue(forKey: highlightId)
                    }
                    return
                case .queued, .running:
                    continue
                }
            }
        }
    }

    private func addTurnToThread(analysis: AIAnalysisModel, question: String, answer: String) {
        if analysis.thread == nil {
            let thread = AnalysisThreadModel()
            thread.analysis = analysis
            analysis.thread = thread
            modelContext.insert(thread)
        }

        let turnIndex = analysis.thread?.turns.count ?? 0
        let turn = AnalysisTurnModel(
            question: question,
            answer: answer,
            turnIndex: turnIndex
        )

        turn.thread = analysis.thread
        analysis.thread?.turns.append(turn)
        modelContext.insert(turn)

        try? modelContext.save()

        // Refresh highlights to ensure conversation data is loaded for marker taps
        loadHighlightsForCurrentChapter()
    }

    // MARK: - Highlight Selection
    /// Selects a highlight and loads its most recent analysis for display
    func selectHighlight(_ highlight: HighlightModel) {
        // Look up the highlight from currentChapterHighlights to get fresh data with analyses loaded
        // The passed highlight from WebView may have stale/unloaded relationships
        let targetId = highlight.id
        let freshHighlight = currentChapterHighlights.first(where: { $0.id == targetId }) ?? highlight

        selectedHighlight = freshHighlight
        selectedText = freshHighlight.selectedText

        // Check if this highlight has an ongoing analysis (streaming)
        if let activeJobId = highlightToJobMap[targetId],
           let job = analysisJobManager.getJob(activeJobId) {
            // Show streaming result for this highlight's active job
            isAnalyzing = (job.status == .streaming || job.status == .queued || job.status == .running)
            if !job.streamingResult.isEmpty {
                analysisResult = job.streamingResult
            } else if let result = job.result {
                analysisResult = result
            } else {
                analysisResult = nil
            }
        } else {
            // No active job - load the most recent completed analysis
            let sortedAnalyses = freshHighlight.analyses.sorted(by: { $0.createdAt > $1.createdAt })
            if let mostRecent = sortedAnalyses.first {
                currentAnalysisType = mostRecent.analysisType
                analysisResult = mostRecent.response
                isAnalyzing = false
            } else {
                // No analyses yet - clear result
                currentAnalysisType = nil
                analysisResult = nil
                isAnalyzing = false
            }
        }

        showingAnalysisPanel = true
    }

    // MARK: - Text Selection
    func handleTextSelection(_ text: String, range: NSRange) {
        let wasActive = hasActiveTextSelection
        selectedText = text
        selectionRange = range
        showingContextMenu = !text.isEmpty
        // Track active selection to defer marker updates
        hasActiveTextSelection = !text.isEmpty

        // If selection was just cleared (user tapped elsewhere), apply deferred updates
        if wasActive && !hasActiveTextSelection {
            applyDeferredMarkerUpdates()
        }
    }

    func clearSelection() {
        selectedText = ""
        selectionRange = nil
        hasActiveTextSelection = false
        // Apply any deferred marker updates now that selection is cleared
        applyDeferredMarkerUpdates()
        showingContextMenu = false
    }
}
